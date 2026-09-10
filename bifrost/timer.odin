package bifrost

import "base:intrinsics"
import "core:mem"
import "core:sync"
import "core:time"

// Phase 9: Timers and time_sleep. A Timer carries a monotonic deadline and a
// callback; time_sleep parks the current goroutine and pushes a Timer that will
// goready it when the deadline passes. Each P holds a min-heap of timers
// (P.timers, P.timers_lock); the scheduler checks the running P's heap in
// findrunnable and fires every expired entry. Mirrors the per-P timer model of
// time.go and proc.go (checkTimers); deviations are noted below.
//
// DEVIATIONS from Go's runtime/time.go:
//   - No cross-P timer stealing: a Timer fires only on the P it was pushed
//     onto. If the M running that P is busy in a long-running goroutine (no
//     yields), the timer is delayed — preemption is Phase 10.
//   - No persistent timer state: every time_sleep creates a one-shot Timer.
//     periodic timers (Go's `period` field) are not yet supported.
//   - No timerproc / netpoller integration; firing happens in the scheduler.
//   - Firing latency floor is PARK_TIMEOUT (200µs): on an otherwise idle
//     runtime an M re-polls timers only when its park sema times out. Go's
//     stopm computes time-until-next-timer and parks for exactly that long
//     (proc.go pollUntil / checkTimers); bifrost uses the simpler polling
//     approach. Sleeps shorter than PARK_TIMEOUT still meet the "≥ d" contract
//     but typically observe ~PARK_TIMEOUT latency.

// Timer is a one-shot scheduled callback. `deadline` is the firing time in
// monotonic nanoseconds (compared against mono_now_ns); `f(arg)` runs on the
// firing M while it holds no timer lock. Field renamed from Go's `when`
// because `when` is an Odin reserved word (compile-time conditional).
Timer :: struct {
	deadline: i64,
	f:        proc(arg: rawptr),
	arg:      rawptr,
}

// mono_now_ns returns nanoseconds from the kernel's monotonic-raw clock
// (`CLOCK_MONOTONIC_RAW` on Linux, via core:time tick_now). Only differences are
// meaningful; the zero is not an externally defined epoch. Per-thread coherent
// on the supported platform.
@(private)
mono_now_ns :: proc "contextless" () -> i64 {
	return i64(time.tick_diff(time.Tick{}, time.tick_now()))
}

// timer_deadline converts a duration into an absolute monotonic deadline,
// saturating instead of wrapping. Without the clamp a near-max Duration
// overflows i64 and produces a deadline in the PAST, so the timer fires
// immediately rather than sleeping. Mirrors Go's `when` overflow clamp
// (time.go:351-352).
@(private)
timer_deadline :: proc "contextless" (d: time.Duration) -> i64 {
	now := mono_now_ns()
	deadline := now + i64(d)
	if deadline < now {
		return max(i64)
	}
	return deadline
}

// timer_sift_up restores the min-heap invariant after appending at the end.
@(private)
timer_sift_up :: proc(h: []Timer, start: int) {
	i := start
	for i > 0 {
		parent := (i - 1) / 2
		if h[i].deadline < h[parent].deadline {
			h[i], h[parent] = h[parent], h[i]
			i = parent
		} else {
			return
		}
	}
}

// timer_sift_down restores the min-heap invariant after replacing the root.
@(private)
timer_sift_down :: proc(h: []Timer, start: int) {
	n := len(h)
	i := start
	for {
		left := 2 * i + 1
		if left >= n {
			return
		}
		best := i
		if h[left].deadline < h[best].deadline {
			best = left
		}
		right := left + 1
		if right < n && h[right].deadline < h[best].deadline {
			best = right
		}
		if best == i {
			return
		}
		h[i], h[best] = h[best], h[i]
		i = best
	}
}

// timer_push pushes a Timer onto pp's heap. ALLOCATOR: pp.timers latches the
// goroutine's context.allocator on first append; goexit_entry installs the
// malloc-backed default context, which is thread-safe — needed because multiple
// Ms concurrently push onto their respective P's heaps. Panics on append
// failure (OOM), mirroring newg's stack_alloc panic — silent failure here
// would leave the goroutine forever parked with no timer to wake it.
@(private)
timer_push :: proc(pp: ^P, t: Timer) {
	sync.lock(&pp.timers_lock)
	defer sync.unlock(&pp.timers_lock)
	_, err := append(&pp.timers, t)
	if err != nil {
		panic("timer_push: timer heap allocation failed")
	}
	timer_sift_up(pp.timers[:], len(pp.timers) - 1)
	intrinsics.atomic_store(&pp.ntimers, i32(len(pp.timers)))
}

// timer_run_expired fires every Timer on pp's heap whose deadline has passed,
// in order. Each callback runs WITHOUT the lock so it may safely re-enter the
// scheduler (goready, etc.). Called from findrunnable.
@(private)
timer_run_expired :: proc(pp: ^P) {
	// findrunnable calls this on every scheduler pass, so check the count first.
	// mono_now_ns is a real clock_gettime syscall and timers_lock is an atomic
	// besides; a program that never creates a timer must pay neither. Measured
	// before this early-out: ~49% of a channel ping-pong's wall time was
	// clock_gettime on an empty heap.
	//
	// This load races only with timer_push from the M that owns pp (the P<->M
	// binding is fixed for the P's lifetime), so a stale zero is impossible and
	// a stale non-zero costs one extra empty pass.
	if intrinsics.atomic_load(&pp.ntimers) == 0 {
		return
	}
	now := mono_now_ns()
	for {
		sync.lock(&pp.timers_lock)
		if len(pp.timers) == 0 || pp.timers[0].deadline > now {
			sync.unlock(&pp.timers_lock)
			return
		}
		t := pp.timers[0]
		last := pop(&pp.timers)
		if len(pp.timers) > 0 {
			pp.timers[0] = last
			timer_sift_down(pp.timers[:], 0)
		}
		intrinsics.atomic_store(&pp.ntimers, i32(len(pp.timers)))
		sync.unlock(&pp.timers_lock)
		t.f(t.arg)
	}
}

// time_sleep blocks the current goroutine until at least d has elapsed.
// Mirrors timeSleep (runtime/time.go).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
time_sleep :: proc(d: time.Duration) {
	if d <= 0 {
		return
	}
	if allp == nil {
		panic("bifrost: call runtime_init before time_sleep")
	}
	gp := getg()
	pp := getm().p
	deadline := timer_deadline(d)
	timer_push(pp, Timer{deadline = deadline, f = time_sleep_wake, arg = rawptr(gp)})
	gopark(nil, nil, .Time_Sleep)
}

// time_sleep_wake is the timer callback that resumes a sleeping goroutine.
@(private)
time_sleep_wake :: proc(arg: rawptr) {
	gp := cast(^G)arg
	goready(gp)
}

// time_after returns a Chan(i64) of capacity 1 that will receive the monotonic
// tick at firing time after d has elapsed. The canonical use is the select +
// timeout idiom — it closes out Phase 7:
//
//   after_ch := time_after(50 * time.Millisecond)
//   ops := []Select_Op{
//       {c = my_chan.c, elem = &val, dir = .Recv},
//       {c = after_ch.c, elem = &tick, dir = .Recv},
//   }
//   chosen, _ := select_(ops[:], true)
//
// Mirrors time.After (src/time/sleep.go), reduced to one-shot.
//
// CONTRACT: the caller MUST treat the returned Chan as receive-only. Sending
// into it fills the cap-1 buffer ahead of the timer; the legitimate fire then
// hits the "buffer unexpectedly full" panic. Receive (in a select or directly)
// and discard the value if you don't need it.
//
// LIFETIME: the returned channel is heap-allocated and is NOT owned by the
// runtime. Always cancel before freeing:
//
//   ch := time_after(50 * time.Millisecond)
//   defer chan_destroy(ch)
//   defer time_after_stop(ch)   // LIFO: runs FIRST, so cancel precedes free
//   chosen, _ := select_(ops[:], true)
//
// Cancelling first is required whenever the timeout was not the case that
// fired. A queued Timer holds the raw ^Hchan, so destroying the channel while
// the timer is still pending leaves the callback writing into freed memory —
// and because the allocator recycles the block immediately (in practice into
// the next time_after's channel) the stale fire lands a tick in a LIVE channel:
// a wrong result with no crash and no diagnostic.
time_after :: proc(d: time.Duration) -> Chan(i64) {
	if allp == nil {
		panic("bifrost: call runtime_init before time_after")
	}
	ch := chan_make(i64, 1)
	pp := getm().p
	deadline := timer_deadline(d)
	timer_push(pp, Timer{deadline = deadline, f = time_after_fire, arg = rawptr(ch.c)})
	return ch
}

// time_after_stop cancels a pending timer created by time_after, returning true
// if it was still queued (so it will never fire) and false if it had already
// fired or was already stopped. Safe to call more than once, and safe on a
// channel whose timer has fired.
//
// This is what makes the select-with-timeout idiom leak-free: without it, every
// iteration in which the data case wins leaves a live Timer holding the raw
// ^Hchan, which the caller can then neither free (use-after-free) nor abandon
// (an unbounded leak of roughly 152 bytes per call). Mirrors (*Timer).Stop
// (src/time/sleep.go) in role, though bifrost's timer has no reset path.
//
// It scans every P's heap rather than only the creating P's: the goroutine that
// called time_after may since have been stolen to another P, and the Timer stays
// on the P it was pushed onto. gomaxprocs is small and cancellation is not a hot
// path, so the linear scan is cheaper than tracking ownership.
time_after_stop :: proc(ch: Chan(i64)) -> bool {
	if allp == nil || ch.c == nil {
		return false
	}
	target := rawptr(ch.c)
	for pp in allp {
		sync.lock(&pp.timers_lock)
		for i in 0 ..< len(pp.timers) {
			if pp.timers[i].f != time_after_fire || pp.timers[i].arg != target {
				continue
			}
			// Swap the last element into the hole and restore the heap. Sifting
			// down alone is not enough: the replacement may be SMALLER than the
			// removed entry's parent, in which case it must move up instead.
			last := len(pp.timers) - 1
			pp.timers[i] = pp.timers[last]
			pop(&pp.timers)
			if i < len(pp.timers) {
				timer_sift_down(pp.timers[:], i)
				timer_sift_up(pp.timers[:], i)
			}
			intrinsics.atomic_store(&pp.ntimers, i32(len(pp.timers)))
			sync.unlock(&pp.timers_lock)
			return true
		}
		sync.unlock(&pp.timers_lock)
	}
	return false
}

// timers_drain drops every pending timer on every P without firing any of them.
// Called by run() at shutdown.
//
// Dropping rather than firing is correct: run() returns only once grunning has
// hit 0, so no goroutine remains for a time_sleep timer to wake, and a
// time_after timer's channel belongs to the caller, who is no longer inside
// run(). Leaving them queued is what is NOT safe — the entries hold raw
// pointers (a ^G, or a ^Hchan the caller is about to free), and a LATER run()
// would fire them into freed memory. That was reproduced as a
// heap-use-after-free under valgrind.
@(private)
timers_drain :: proc() {
	for pp in allp {
		sync.lock(&pp.timers_lock)
		clear(&pp.timers)
		intrinsics.atomic_store(&pp.ntimers, i32(0))
		sync.unlock(&pp.timers_lock)
	}
}

// time_after_fire is the timer callback used by time_after. It does a
// non-parking send onto the channel — direct handoff to a parked select
// receiver if one is waiting, else a buffer write. Runs on g0, so it MUST
// inline the send logic: chansend on a closed channel would panic (not the
// desired drop semantics for a one-shot fire) and on the parking path would
// gopark → mcall from g0, which is illegal. The cap=1 invariant is checked
// against c.elem_size — a future caller reusing this fn with a different
// elem_size would corrupt the buffer.
@(private)
time_after_fire :: proc(arg: rawptr) {
	c := cast(^Hchan)arg
	assert(c.elem_size == size_of(i64), "time_after_fire: unexpected elem_size")
	tick := mono_now_ns()
	sync.lock(&c.lock)
	if c.closed != 0 {
		sync.unlock(&c.lock)
		return
	}
	if sg := waitq_dequeue(&c.recvq); sg != nil {
		// A select waiter is parked here: hand the value directly to it and
		// wake it. wake_ready sets sg.g.param so selectgo identifies this case.
		// chan lock is released BEFORE wake_ready because goready takes
		// scheduler locks; nesting would invert chan/sched order (mirrors
		// chan.odin's send / recv).
		chan_send_elem(c, sg, rawptr(&tick))
		sync.unlock(&c.lock)
		wake_ready(sg)
		return
	}
	if c.qcount < c.dataqsiz {
		// No waiter, buffer has room: stash the tick for a future receiver.
		mem.copy(chan_buf_slot(c, c.sendx), rawptr(&tick), int(c.elem_size))
		c.sendx += 1
		if c.sendx == c.dataqsiz {
			c.sendx = 0
		}
		c.qcount += 1
		sync.unlock(&c.lock)
		return
	}
	// Buffer full with no waiter is unreachable under correct time_after usage
	// (cap=1, only this fn ever writes). The only reachable trigger is a
	// caller that sent into the returned Chan themselves — see time_after's
	// receive-only CONTRACT. Fail loudly so the misuse is named, not silently
	// dropped (a silent drop would make the missed timeout look like a deeper
	// scheduler bug).
	sync.unlock(&c.lock)
	panic(
		"time_after_fire: chan buffer unexpectedly full. Either the caller sent into " +
		"the channel returned by time_after (it is receive-only), or this Hchan is not " +
		"the one the timer was created for — i.e. the original was chan_destroy'd while " +
		"its timer was still pending and the block has been recycled. Cancel with " +
		"time_after_stop before destroying.",
	)
}
