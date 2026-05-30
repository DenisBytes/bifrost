package bifrost

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
}

// timer_run_expired fires every Timer on pp's heap whose deadline has passed,
// in order. Each callback runs WITHOUT the lock so it may safely re-enter the
// scheduler (goready, etc.). Called from findrunnable.
@(private)
timer_run_expired :: proc(pp: ^P) {
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
		sync.unlock(&pp.timers_lock)
		t.f(t.arg)
	}
}

// time_sleep blocks the current goroutine until at least d has elapsed.
// Mirrors timeSleep (runtime/time.go).
time_sleep :: proc(d: time.Duration) {
	if d <= 0 {
		return
	}
	gp := getg()
	pp := getm().p
	deadline := mono_now_ns() + i64(d)
	timer_push(pp, Timer{deadline = deadline, f = time_sleep_wake, arg = rawptr(gp)})
	gopark(nil, nil, .Time_Sleep)
}

// time_sleep_wake is the timer callback that resumes a sleeping goroutine.
@(private)
time_sleep_wake :: proc(arg: rawptr) {
	gp := cast(^G)arg
	goready(gp)
}
