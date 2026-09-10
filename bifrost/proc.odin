package bifrost

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

// Phase 5: a multi-M scheduler. `gomaxprocs` OS threads (m0 = the main thread,
// plus worker Ms) each pinned to one P run goroutines in parallel; idle Ms park
// on their own per-M note (tracked on sched.midle) and load is balanced by work
// stealing. Scheduling is
// still cooperative (no sysmon/preemption): a goroutine yields via gosched,
// parks via gopark, or finishes to release its M. Mirrors the structure of Go's
// scheduler (proc.go); deviations are documented at each site.
//
// Control-flow model (see asm_amd64.asm): a running goroutine reaches the
// scheduler by calling mcall(fn), which saves the goroutine's context and runs
// fn on its M's g0 stack. fn (gosched_m / park_m / goexit0) manipulates queues
// and calls schedule(), which picks the next goroutine and gogo's into it. The
// g0 stack is reset to a fixed base on every mcall, so it never accumulates
// frames across switches.

// HAVE_SYSMON reports whether a system-monitor thread exists to preempt
// long-running goroutines. It is false until Phase 10. While false, runqput
// must NOT use the runnext slot: runnext makes a ready'd goroutine share the
// current one's time slice, and without sysmon to break that slice a
// communicate-and-wait pair would starve everyone else. Go applies the same
// guard (proc.go runqput: `if !haveSysmon && next { next = false }`).
@(private)
HAVE_SYSMON :: false

// PARK_TIMEOUT bounds how long an idle M sleeps before re-polling for work.
//
// It is LOAD-BEARING for work-handoff liveness, not a mere latency tweak.
// bifrost deliberately omits Go's spinning-M protocol (the nmspinning "delicate
// dance"), so the wakeup is best-effort: a producer that publishes a goroutine
// onto its local P ring (runqput is lock-free) and then calls wakep can find no
// idle M to signal precisely because the consumer polled-empty but had not yet
// listed itself on sched.midle. That goroutine is then picked up only by a
// re-poll, which PARK_TIMEOUT bounds. checkdead relies on the same fact: it
// refuses to call a _Grunnable-while-all-idle state a deadlock because this
// timeout resolves it. (Shutdown does NOT depend on the timeout — stopm
// re-checks sched.shutdown under sched.lock.) Tunable, but raising it directly
// raises worst-case handoff latency under contention; the real fix for the
// window is spinning Ms in a later phase.
@(private)
PARK_TIMEOUT :: 200 * time.Microsecond

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// on_goroutine reports whether the caller is executing on a user goroutine of
// an initialized runtime — i.e. whether a blocking runtime call is legal here.
//
// It is false on three distinct misuses, each of which otherwise crashes with
// no diagnostic:
//  1. a thread bifrost never created — tls_m is @(thread_local), so getm() is
//     nil there and every entry point nil-derefs;
//  2. the thread that called run(), which is m0 running g0, not a goroutine;
//  3. any call before runtime_init.
@(private)
on_goroutine :: proc "contextless" () -> bool {
	mp := getm()
	gp := getg()
	return allp != nil && mp != nil && gp != nil && mp.g0 != nil && gp != mp.g0
}

// go_ spawns a new goroutine running fn(arg). It is bifrost's equivalent of
// Go's `go fn(arg)`. The goroutine becomes runnable immediately but does not
// run until the scheduler (run) is active and reaches it. Mirrors newproc
// (proc.go).
//
// CONTRACT: callable from the thread that ran runtime_init (before or during
// run) and from inside any goroutine. NOT callable from a thread bifrost did
// not create — see on_goroutine.
//
// ALLOCATOR: the new goroutine runs under runtime.default_context(), NOT the
// caller's context. Its `context.allocator` is therefore the malloc heap
// regardless of what the caller had installed, so memory a goroutine allocates
// must not be freed with a caller-side allocator (and vice versa). See
// goexit_entry.
go_ :: proc(fn: proc(arg: rawptr), arg: rawptr = nil) {
	// Unconditional checks, not asserts: -disable-assert strips asserts, and
	// each of these otherwise ends in a bare SIGSEGV. Go's newproc1 likewise
	// fatals rather than faulting.
	if allp == nil {
		panic("bifrost: call runtime_init before go_")
	}
	if getm() == nil {
		panic(
			"bifrost: go_ called from a thread the runtime does not own. bifrost APIs are " +
			"callable from the thread that ran runtime_init, or from inside a goroutine — " +
			"not from an arbitrary core:thread thread.",
		)
	}
	if fn == nil {
		panic("bifrost: go_ of nil proc value")
	}
	gp := newg(fn, arg)
	// Enqueue onto the current M's P (allp[0] for the main thread before run).
	runqput(getm().p, gp, true)
	wakep()
}

// run starts the scheduler on `gomaxprocs` OS threads and returns when every
// goroutine has finished. Call runtime_init first, then go_ to spawn work, then
// run. It spins up gomaxprocs-1 worker Ms (one per P beyond P0), runs m0's own
// schedule loop on P0, and on shutdown joins the workers before returning.
//
// run may be called repeatedly against a single runtime_init: each call creates
// a fresh worker-M generation and releases it before returning. Pair the final
// run with runtime_teardown to free the rest of the runtime.
run :: proc() {
	// Unconditional, not an assert: -disable-assert strips asserts and this
	// would then nil-deref allp inside scheduler_start instead of naming the
	// misuse. Same reasoning as go_ and mcall.
	if allp == nil {
		panic("bifrost: call runtime_init before run")
	}
	scheduler_start()

	// Nothing to run. This early return is load-bearing, not an optimisation:
	// run terminates only via begin_shutdown, which is reached only from goexit0
	// when sched.grunning transitions 1 -> 0. Entered with grunning already 0 no
	// goexit0 ever runs, sched.shutdown is never set, and every M spins in the
	// PARK_TIMEOUT stopm/findrunnable poll forever — a permanent hang burning
	// gomaxprocs threads, reachable from `runtime_init(n); run()` and from a job
	// loop whose batch happens to be empty.
	if intrinsics.atomic_load(&sched.grunning) == 0 {
		return
	}

	// Spin up one worker M per P beyond P0; each runs schedule() on its own
	// thread until shutdown.
	allms = make([]^M, int(gomaxprocs - 1), runtime_allocator)
	for i in 1 ..< int(gomaxprocs) {
		allms[i - 1] = newm(allp[i])
	}

	// m0 runs its own schedule loop on its g0 stack. The loop returns here (via
	// gogo(&m0.sched_return)) once shutdown is signalled.
	g0_bytes := stack_to_bytes(m0.g0_stack)
	setup_context(&g0.sched, cast(rawptr)schedule_bootstrap, g0_bytes)
	g0.sched.g = &g0 // parity with newg; bifrost's asm never reads gobuf.g today
	gosave_switch(&m0.sched_return, &g0.sched)

	// Shutdown: every worker's schedule loop has (or will) observe sched.shutdown
	// and exit its thread. Join them, then release the whole generation — run
	// reassigns allms on its next call, so anything left here would become
	// unreachable even to runtime_teardown, which walks only the current allms.
	for mp in allms {
		thread.destroy(mp.thread) // joins, then frees the Thread handle
	}
	free_worker_ms()
}

// free_worker_ms releases the current worker-M generation: each M's g0 stack,
// its g0 G, the M itself, and the allms backing. A nil allms is a no-op, so it
// is safe to call before any run and twice in a row.
//
// The OS threads must already have been joined (thread.destroy) before this is
// called — it frees the stacks those threads were running on.
@(private)
free_worker_ms :: proc() {
	for mp in allms {
		stack_free(mp.g0_stack)
		free(mp.g0, runtime_allocator)
		free(mp, runtime_allocator)
	}
	if allms != nil {
		delete(allms, runtime_allocator)
		allms = nil
	}
}

// gosched yields the processor, allowing other goroutines to run, and resumes
// the caller later. Mirrors Go's Gosched (proc.go:393).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
gosched :: proc() {
	mcall(gosched_m)
}

// gopark puts the current goroutine into a waiting state and switches to the
// scheduler. After the status flips to _Gwaiting, park_m calls unlockf(gp,
// lock) on the scheduler stack (if unlockf != nil); if unlockf returns false
// the park is aborted and the goroutine resumes. The goroutine stays parked
// until some other goroutine calls goready on it. Mirrors gopark
// (proc.go:449).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
gopark :: proc(unlockf: proc "c" (gp: ^G, lock: rawptr) -> bool, lock: rawptr, reason: Wait_Reason) {
	gp := getg()
	mp := getm()
	gp.waitreason = reason
	// Stash the callback on THIS M, not a package global: another goroutine on a
	// different M may be parking at the same instant, and each must run its own
	// unlockf against its own lock. park_m (same M, on g0) reads these back.
	mp.waitunlockf = unlockf
	mp.waitlock = lock
	mcall(park_m)
}

// goready marks a parked (_Gwaiting) goroutine runnable again and enqueues it.
// Mirrors goready/ready (proc.go:485 / :1124).
goready :: proc(gp: ^G) {
	ready(gp)
}

// ---------------------------------------------------------------------------
// Goroutine creation and teardown
// ---------------------------------------------------------------------------

// newg returns a runnable goroutine that will run fn(arg). It reuses a dead G
// (with its stack) from the per-P free list when possible, otherwise allocates
// a new G and stack. Mirrors newproc1 (proc.go:5343).
@(private)
newg :: proc(fn: proc(arg: rawptr), arg: rawptr) -> ^G {
	pp := getm().p

	gp := gfget(pp) // per-P reuse: lock-free common path
	if gp == nil {
		// Grow path. Serialize under allgs_lock so concurrent newg from
		// different Ms is safe even if runtime_allocator is not thread-safe (the
		// test tracking allocator isn't), and so the allgs append is safe.
		sync.lock(&allgs_lock)
		gp = new(G, runtime_allocator)
		s, err := stack_alloc()
		if err != .None {
			sync.unlock(&allgs_lock)
			panic("newg: stack allocation failed")
		}
		gp.stack = s
		casgstatus(gp, .Idle, .Dead) // a zero G reads as _Gidle
		append(&allgs, gp)
		sync.unlock(&allgs_lock)
	}

	gp.start_fn = fn
	gp.start_arg = arg

	setup_context(&gp.sched, cast(rawptr)goexit_entry, stack_to_bytes(gp.stack))
	gp.sched.g = gp
	gp.goid = next_goid()

	// One more live goroutine. goexit0 decrements this; reaching 0 ends the run.
	intrinsics.atomic_add(&sched.grunning, 1)
	casgstatus(gp, .Dead, .Runnable)
	return gp
}

// goexit_entry is the first thing every goroutine runs (set as its initial
// context by newg). It establishes an Odin context, runs the user function,
// then exits. Entered via gogo, so it has no incoming context — hence "c" and
// the explicit context setup, mirroring how core:thread bootstraps a thread.
//
// ALLOCATOR NOTE: runtime.default_context() gives a malloc-backed heap allocator
// (thread-safe) and Odin's default temp allocator, which is @(thread_local) —
// so each OS thread has its own temp arena and concurrent goroutines on
// different Ms never share one. Two real limits remain, neither hit by current
// code paths: (1) a goroutine that temp-allocates, is stolen, and resumes on
// another M reads the first M's arena, since context is rebuilt per OS thread,
// not carried with the goroutine; (2) the temp arena is never reset, so it grows
// across a long run. A per-goroutine context saved/restored across the switch is
// deferred until a goroutine path actually uses the temp allocator (Phase 8+).
//
// DEVIATION: Go threads the equivalent of this trampoline through goexit as the
// new goroutine's return address (proc.go newproc1 + asm goexit); bifrost uses
// a plain Odin entry that reads start_fn/start_arg off the G.
@(private)
goexit_entry :: proc "c" () {
	context = runtime.default_context()
	gp := getg()
	fn := gp.start_fn
	arg := gp.start_arg
	fn(arg)
	goexit()
}

// goexit ends the current goroutine by switching to the scheduler stack and
// running goexit0 there. Mirrors goexit1 (proc.go:4481).
@(private)
goexit :: proc() {
	mcall(goexit0)
}

// goexit0 runs on g0: it marks the finished goroutine dead, returns it to the
// free list for reuse, and schedules the next one. Mirrors goexit0 / gdestroy
// (proc.go:4497 / :4509).
@(private)
goexit0 :: proc "c" (gp: ^G) {
	context = runtime.default_context()
	casgstatus(gp, .Running, .Dead)
	gp.start_fn = nil
	gp.start_arg = nil
	gp.param = nil
	gp.waitreason = .None
	dropg()
	gfput(getm().p, gp)

	// One fewer live goroutine; when the last one exits, end the whole run.
	// atomic_add returns the value BEFORE subtracting, so old == 1 means the
	// new count is 0.
	if intrinsics.atomic_add(&sched.grunning, -1) == 1 {
		begin_shutdown()
	}
	schedule()
}

// ---------------------------------------------------------------------------
// Scheduler core (runs on g0)
// ---------------------------------------------------------------------------

// scheduler_start allocates m0's g0 scheduling stack (once) and marks P0
// running. Called from every run(); m0's g0 stack is allocated only on the
// first call and reused thereafter (matches Go: the g0 stack lives for the M's
// lifetime, not per scheduler entry).
//
// SCOPE OF THAT CLAIM: it covers m0's g0 stack only. The WORKER Ms are created
// fresh by newm on every run(), each with its own g0 stack, so the no-leak
// property across repeated run() cycles is not this proc's doing — it is run()
// releasing the previous generation via free_worker_ms.
@(private)
scheduler_start :: proc() {
	if m0.g0_stack.lo == 0 {
		// A roomier stack for the scheduler than a normal goroutine: schedule
		// -> execute and the continuations run here.
		s, err := stack_alloc(STACK_MIN * 4)
		if err != .None {
			panic("scheduler_start: g0 stack allocation failed")
		}
		m0.g0_stack = s
		g0.stack = s
	}
	intrinsics.atomic_store_explicit(&sched.shutdown, false, .Release)
	// Bind the main M to P0 for the duration of the run (idempotent).
	acquirep(&m0, allp[0])
}

// newm creates a worker M pinned to pp: it allocates the M, its g0 and g0 stack,
// binds the P, and starts an OS thread running m_thread_entry. Mirrors newm
// (proc.go:2866), simplified — bifrost's Ms are pre-created one per P, not on
// demand. The thread runs with a fresh default context.
@(private)
newm :: proc(pp: ^P) -> ^M {
	mp := new(M, runtime_allocator)
	g0p := new(G, runtime_allocator)
	s, err := stack_alloc(STACK_MIN * 4)
	if err != .None {
		panic("newm: g0 stack allocation failed")
	}
	mp.g0 = g0p
	mp.g0_stack = s
	g0p.stack = s
	g0p.m = mp
	g0p.atomicstatus = .Running
	mp.id = i64(pp.id)
	acquirep(mp, pp)
	mp.thread = thread.create_and_start_with_data(rawptr(mp), m_thread_entry, runtime.default_context())
	// A nil handle means the OS refused the thread (e.g. RLIMIT). bifrost pins
	// one M per P up front, so a missing worker would silently break the
	// gomaxprocs==live-Ms invariant checkdead relies on, then crash later on
	// thread.destroy(nil). Fail loudly here instead, like the stack_alloc panic.
	if mp.thread == nil {
		panic("newm: OS thread creation failed")
	}
	return mp
}

// m_thread_entry is a worker M's OS-thread procedure. It installs this thread's
// tls_m/tls_g, then switches onto the M's g0 stack to run the schedule loop. It
// returns (ending the thread) only when the schedule loop gogo's back to
// m.sched_return on shutdown. Mirrors mstart0/mstart1 (proc.go:1866/:1908).
@(private)
m_thread_entry :: proc(data: rawptr) {
	mp := cast(^M)data
	setm(mp)
	setg(mp.g0)
	setup_context(&mp.g0.sched, cast(rawptr)mstart_run, stack_to_bytes(mp.g0_stack))
	mp.g0.sched.g = mp.g0
	gosave_switch(&mp.sched_return, &mp.g0.sched)
	// Returned here on shutdown: the thread proc ends and the M becomes joinable.
}

// mstart_run is a worker M's first frame on its g0 stack (the worker analogue of
// schedule_bootstrap). Entered via gosave_switch, so it is "c" and establishes a
// context before entering the scheduler.
@(private)
mstart_run :: proc "c" () {
	context = runtime.default_context()
	setg(getm().g0)
	schedule()
}

// acquirep associates P pp with M mp and marks it running, the analogue of
// installing a P before executing goroutine code. Mirrors acquirep (proc.go).
@(private)
acquirep :: proc(mp: ^M, pp: ^P) {
	mp.p = pp
	pp.m = mp
	pp.status = .Running
}

// releasep detaches the current P from mp, returning it idle. Mirrors releasep
// (proc.go).
@(private)
releasep :: proc(mp: ^M) -> ^P {
	pp := mp.p
	mp.p = nil
	if pp != nil {
		pp.m = nil
		pp.status = .Idle
	}
	return pp
}

// schedule_bootstrap is the first thing that runs on g0 when run() hands over
// control. Entered via gosave_switch (no incoming context), so it is "c" and
// sets up a context before calling into the scheduler.
@(private)
schedule_bootstrap :: proc "c" () {
	context = runtime.default_context()
	setg(&g0)
	schedule()
}

// schedule runs this M's scheduling loop body: pick the next runnable goroutine
// and execute it. findrunnable only returns nil once shutdown is signalled, at
// which point this M exits its loop by gogo'ing to its sched_return (run() for
// m0, the thread proc for workers). Mirrors schedule (proc.go:4141).
@(private)
schedule :: proc() {
	gp := findrunnable()
	if gp == nil {
		gogo(&getm().sched_return) // shutdown: leave this M
		return // unreachable: gogo does not return, but the compiler can't know
	}
	execute(gp)
}

// begin_shutdown signals every M to stop and wakes them all. Called once, when
// the last live goroutine exits (grunning hits 0). Any M not yet parked observes
// sched.shutdown directly in findrunnable; an M that parks just after we drain
// the list is caught by its PARK_TIMEOUT re-poll.
@(private)
begin_shutdown :: proc() {
	intrinsics.atomic_store_explicit(&sched.shutdown, true, .Release)
	sync.lock(&sched.lock)
	for {
		mp := mget()
		if mp == nil {
			break
		}
		sync.sema_post(&mp.park)
	}
	sync.unlock(&sched.lock)
}

// wakep wakes one idle M after work is made available, by popping it off the
// idle list and posting its private note. Posting only a genuinely-parked M
// (never a blind post) is what keeps each note near-binary and avoids the
// stale-permit busy-spin a single shared semaphore would cause. (A timeout/post
// race can still leave at most one stray permit on a note; it is consumed as one
// benign spurious wakeup on that M's next park — see M.park.) Correctness does
// not hinge on wakep — a parked M also re-polls on PARK_TIMEOUT — but it cuts
// scheduling latency.
@(private)
wakep :: proc() {
	// Post INSIDE the critical section. Posting after the unlock lets several
	// wakers each pop a different M and then be descheduled before their post
	// lands, so the number of outstanding permits is bounded by the thread
	// count, not by one. Holding sched.lock across the post makes "at most one
	// outstanding post per listing" a genuine invariant, because an M cannot
	// re-list itself without taking this same lock. The post is a bare futex
	// wake, so the critical section stays short.
	sync.lock(&sched.lock)
	mp := mget()
	if mp != nil {
		sync.sema_post(&mp.park)
	}
	sync.unlock(&sched.lock)
}

// mput pushes mp onto the idle-M LIFO and runs the deadlock check. Caller must
// hold sched.lock. Mirrors Go's mput (proc.go:7230), which likewise calls
// checkdead under the lock.
@(private)
mput :: proc(mp: ^M) {
	mp.idle_link = sched.midle
	sched.midle = mp
	sched.nmidle += 1
	checkdead()
}

// mget pops one idle M off the LIFO, or nil. Caller must hold sched.lock.
// Mirrors Go's mget (proc.go:7243).
@(private)
mget :: proc() -> ^M {
	mp := sched.midle
	if mp != nil {
		sched.midle = mp.idle_link
		mp.idle_link = nil
		sched.nmidle -= 1
	}
	return mp
}

// mget_specific removes mp from the idle list if present (no-op otherwise), so an
// M that woke on its PARK_TIMEOUT can delist itself. Caller must hold sched.lock.
// Mirrors Go's mgetSpecific (proc.go:7260).
//
// DEVIATION: Go's mgetSpecific is O(1) — its idle list is an intrusive
// doubly-linked list and membership is a prev/next == 0 test. bifrost's midle is
// a singly-linked LIFO, so this walks the list (bounded by gomaxprocs, tiny).
// nmidle is decremented only on an actual unlink, so a no-op (already popped by a
// waker) leaves the count correct.
@(private)
mget_specific :: proc(mp: ^M) {
	prev: ^M
	for cur := sched.midle; cur != nil; cur = cur.idle_link {
		if cur == mp {
			if prev == nil {
				sched.midle = cur.idle_link
			} else {
				prev.idle_link = cur.idle_link
			}
			mp.idle_link = nil
			sched.nmidle -= 1
			return
		}
		prev = cur
	}
}

// checkdead reports a genuine deadlock: every M parked while live goroutines
// remain, all of them _Gwaiting with no one left to wake them. Caller must hold
// sched.lock; called from mput when an M parks. Mirrors Go's checkdead
// (proc.go:6397).
//
// LOCK ORDER: this takes allgs_lock while already holding sched.lock, so the
// ordering is sched.lock -> allgs_lock. Nothing may take them in the reverse
// order (newg/live_goroutines take allgs_lock alone and never grab sched.lock
// under it); see the lock field doc comments in runtime2.odin.
//
// DEVIATION: Go also throws on finding a _Grunnable g while every M is idle
// (a lost wakeup). bifrost does NOT — its PARK_TIMEOUT re-poll recovers a
// runnable-but-unscheduled g, so that state is benign here, not fatal. Only the
// all-_Gwaiting case (which no re-poll can resolve) is a true deadlock.
//
// CAVEAT (revisit in Phase 9/11): this is sound only while the sole way a
// _Gwaiting g becomes runnable is goready from a goroutine running on a non-idle
// M (so any in-flight wakeup keeps gomaxprocs-nmidle > 0 and short-circuits the
// scan before it can fire). Async readiers — timer expiry (Phase 9) and netpoll
// (Phase 11) — can ready a g while every M is idle, so they must re-examine this
// "all idle => deadlock" inference before they land.
@(private)
checkdead :: proc() {
	// bifrost runs a fixed pool of exactly gomaxprocs Ms (m0 + workers), so
	// "running Ms" is gomaxprocs - nmidle. While any M still runs, it (or a
	// steal) will reach the work; not dead.
	if gomaxprocs - sched.nmidle > 0 {
		return
	}

	// A pending timer on ANY P means at least one waiter is sleeping toward a
	// known deadline — not a deadlock. The next PARK_TIMEOUT re-poll on the
	// owning M will fire it and resume its goroutine. Lock order is sched.lock
	// (held by caller) -> pp.timers_lock; nothing else takes them reversed.
	//
	// KNOWN LIMITATION: this suppresses the deadlock panic for the FULL duration
	// of the longest pending timer. A genuine deadlock (e.g. a goroutine stuck
	// on a channel with no peer) on a program that has a long sleeper elsewhere
	// will hang silently until that sleeper's timer fires, only then is the
	// deadlock detected. A future improvement is to scan waitreasons: if any
	// waiting goroutine has a non-Time_Sleep reason while we're suppressing,
	// emit a diagnostic naming it; the simple rule is hard to make precise
	// because rendezvous patterns (sleeper sends to a parked receiver) are
	// legitimate. For now, document and proceed.
	for pp in allp {
		sync.lock(&pp.timers_lock)
		has_timer := len(pp.timers) > 0
		sync.unlock(&pp.timers_lock)
		if has_timer {
			return
		}
	}

	sync.lock(&allgs_lock)
	defer sync.unlock(&allgs_lock)

	waiting := 0
	for gp in allgs {
		#partial switch g_status(gp) {
		case .Runnable, .Running:
			return // recoverable: a PARK_TIMEOUT re-poll will run it
		case .Waiting:
			waiting += 1
		}
	}
	if waiting > 0 {
		fmt.eprintfln("bifrost: all goroutines are asleep - deadlock!")
		for gp in allgs {
			if g_status(gp) == .Waiting {
				fmt.eprintfln("  goroutine %d: waiting (%v)", gp.goid, gp.waitreason)
			}
		}
		// Terminate the way Go's throw does, rather than panicking.
		//
		// This runs with sched.lock held by our caller (stopm) and allgs_lock
		// held by our own defer, and an Odin panic is fatal but does NOT unwind,
		// so neither lock would ever be released. In a standalone binary the
		// resulting SIGILL kills the process and nobody notices — but a host that
		// installs a SIGILL handler and survives it, which `odin test` does, then
		// has every other M block forever on sched.lock. That turned a genuine
		// deadlock at gomaxprocs >= 2 into an unbounded hang of the project's own
		// test suite instead of a reported failure.
		os.exit(2)
	}
	// waiting == 0: no non-dead goroutines remain (run is finishing). Not a
	// deadlock — shutdown is in flight.
}

// execute runs gp: bind it to the M, flip _Grunnable -> _Grunning, and gogo
// into it. Never returns. Mirrors execute (proc.go:3337).
@(private)
execute :: proc(gp: ^G) {
	mp := getm()
	mp.curg = gp
	gp.m = mp
	casgstatus(gp, .Runnable, .Running)
	setg(gp)
	gogo(&gp.sched)
}

// findrunnable returns the next goroutine to run, or nil only when shutdown has
// been signalled. Each pass: poll the global queue every 61st tick for fairness,
// fire any expired timers on this P (their callbacks typically goready a
// sleeping goroutine onto the local runq), then check the local run queue, the
// global queue, and steal; if everything is empty it parks the M (stopm) and
// retries. Mirrors findRunnable (proc.go:3395) + checkTimers (proc.go); work
// stealing is the bifrost steal_work().
@(private)
findrunnable :: proc() -> ^G {
	mp := getm()
	for {
		// Check the global run queue once in a while to ensure fairness.
		// Otherwise two goroutines can completely occupy the local run queue by
		// constantly respawning each other. Mirrors findRunnable's
		// `pp.schedtick%61 == 0 && !sched.runq.empty()` check (proc.go), whose
		// comment names this exact hazard.
		//
		// Load-bearing at gomaxprocs == 1, where no other M ever drains the
		// global queue: gosched_m puts every yielding goroutine on the GLOBAL
		// queue while go_/ready enqueue to the LOCAL ring, so without this poll
		// one self-respawning producer starves a gosched() waiter forever
		// (measured: 200,000 respawns, i.e. never, before this was added).
		mp.p.schedtick += 1
		if mp.p.schedtick % 61 == 0 {
			if gp := globrunqget(); gp != nil {
				return gp
			}
		}
		// Fire timers that have expired on our P; callbacks may goready
		// goroutines onto our local runq, which the next runqget will pick up.
		timer_run_expired(mp.p)
		if gp := runqget(mp.p); gp != nil {
			return gp
		}
		if gp := globrunqget(); gp != nil {
			return gp
		}
		if gp := steal_work(mp); gp != nil {
			return gp
		}
		if intrinsics.atomic_load_explicit(&sched.shutdown, .Acquire) {
			return nil
		}
		stopm()
		if intrinsics.atomic_load_explicit(&sched.shutdown, .Acquire) {
			return nil
		}
	}
}

// steal_work tries to take half of another P's local run queue into mp's P,
// returning one stolen goroutine (or nil). It scans the Ps from a random start
// for a few rounds. Mirrors stealWork (proc.go:3834), simplified (no netpoll,
// no spinning accounting). mp's own queue is empty here (findrunnable checked).
@(private)
steal_work :: proc(mp: ^M) -> ^G {
	if gomaxprocs <= 1 {
		return nil
	}
	pp := mp.p
	for _ in 0 ..< 4 {
		start := fastrand() % u32(gomaxprocs)
		for i in 0 ..< gomaxprocs {
			victim := allp[int((start + u32(i)) % u32(gomaxprocs))]
			if victim == pp {
				continue
			}
			if gp := runqsteal(pp, victim, false); gp != nil {
				return gp
			}
		}
	}
	return nil
}

// steal_rng is a per-thread xorshift state for choosing a random steal victim.
@(private)
@(thread_local)
steal_rng: u32

// fastrand returns a cheap per-thread pseudo-random u32 (xorshift), seeded lazily
// from the cycle counter. Used only to spread steal attempts across Ps.
@(private)
fastrand :: proc "contextless" () -> u32 {
	x := steal_rng
	if x == 0 {
		x = u32(intrinsics.read_cycle_counter()) | 1
	}
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	steal_rng = x
	return x
}

// stopm parks this M until wakep posts its private note or PARK_TIMEOUT elapses,
// then returns so findrunnable can re-poll. It lists itself on sched.midle
// (under sched.lock) before sleeping; mput runs checkdead, so if this M going
// idle means every M is idle with goroutines still alive, a genuine all-waiting
// deadlock is reported here. Mirrors stopm/mPark (proc.go:2998).
@(private)
stopm :: proc() {
	mp := getm()

	sync.lock(&sched.lock)
	// Re-check shutdown under the very lock begin_shutdown drains the idle list
	// with. This makes shutdown liveness independent of PARK_TIMEOUT: either we
	// list ourselves before begin_shutdown's drain (so it posts our note), or we
	// observe shutdown here and never park. Without this check a worker that read
	// shutdown==false in findrunnable, then parked just after the drain, would
	// only exit via the timeout re-poll.
	if intrinsics.atomic_load_explicit(&sched.shutdown, .Acquire) {
		sync.unlock(&sched.lock)
		return
	}
	mput(mp) // list self + run checkdead, both under the lock
	sync.unlock(&sched.lock)

	// The bool result (true=posted, false=timed out) is intentionally ignored:
	// stopm re-polls findrunnable regardless of why it woke, so the re-poll, not
	// this signal, is the source of truth.
	sync.sema_wait_with_timeout(&mp.park, PARK_TIMEOUT)

	// Delist self. If a waker already popped us (wakep/begin_shutdown), this is a
	// no-op; if we woke on the timeout we remove ourselves. Either way stopm
	// returns with this M off the idle list.
	sync.lock(&sched.lock)
	mget_specific(mp)
	sync.unlock(&sched.lock)
}

// mcall saves the current goroutine and runs fn(gp) on the scheduler stack.
// fn must not return; it ends by gogo-ing into a goroutine or to sched_return.
// Mirrors Go's mcall (asm) + its callers. The Odin wrapper computes the
// operands; the stack switch itself is mcall_switch (asm_amd64.asm).
@(private)
mcall :: proc(fn: proc "c" (gp: ^G)) {
	// Go's mcall refuses to run when the current g is already g0 (asm_amd64.s:
	// `CMPQ SI, R14 / JNE goodm / JMP runtime·badmcall`, throwing "runtime:
	// mcall called on m->g0 stack" via badmcall in proc.go). bifrost needs the
	// same guard for a sharper reason: on the thread that calls run(), getg()
	// IS g0, so &gp.sched and g0p.sched would be the same buffer — and before
	// run() has installed a bootstrap frame, g0.sched.sp is still 0 (runtime_init
	// zeroes g0), so mcall_switch would execute `mov rsp, 0` followed by `call`.
	// That is an immediate SIGSEGV with no output, reachable from an ordinary
	// chan_recv on the main thread.
	//
	// This is one choke point for every blocking public API: gosched, gopark and
	// goexit all funnel through here, and everything else (channels, select,
	// sema and therefore Mutex/RWMutex/WaitGroup/Once/Cond, time_sleep) funnels
	// through those. Unconditional panic, not assert: -disable-assert would
	// strip an assert and restore the silent segfault.
	if !on_goroutine() {
		panic(
			"bifrost: blocking runtime call outside a goroutine. chan_send, chan_recv, " +
			"select_, mutex_lock, rwmutex_lock, waitgroup_wait, cond_wait, sema_acquire, " +
			"time_sleep and gosched may only be called from inside a goroutine started with " +
			"go_, while run() is active — not from the thread that calls run(), and not from " +
			"a thread bifrost did not create.",
		)
	}
	gp := getg()
	g0p := gp.m.g0
	setg(g0p)
	mcall_switch(&gp.sched, cast(rawptr)fn, gp, g0p.sched.sp)
	// Resumed: execute() set tls_g back to gp before gogo'ing here.
}

// gosched_m is the gosched continuation on g0: requeue the yielding goroutine
// (globally, for fairness) and pick the next. Mirrors gosched_m / goschedImpl
// (proc.go:4355 / :4313).
@(private)
gosched_m :: proc "c" (gp: ^G) {
	context = runtime.default_context()
	casgstatus(gp, .Running, .Runnable)
	dropg()
	globrunqput(gp)
	wakep() // another M may grab the yielded goroutine
	schedule()
}

// dropg severs the current goroutine from its M, clearing both directions of
// the link (gp.m and m.curg). Mirrors dropg (proc.go:4246); keeping both sides
// in sync matters once goroutines can migrate between Ms in Phase 5.
@(private)
dropg :: proc() {
	mp := getm()
	if gp := mp.curg; gp != nil {
		gp.m = nil
	}
	mp.curg = nil
}

// park_m is the gopark continuation on g0: flip _Grunning -> _Gwaiting, run the
// unlock callback, and either resume (if it vetoes the park) or schedule away.
// Mirrors park_m (proc.go:4259).
@(private)
park_m :: proc "c" (gp: ^G) {
	context = runtime.default_context()
	mp := getm()
	casgstatus(gp, .Running, .Waiting)
	dropg()

	if mp.waitunlockf != nil {
		unlockf := mp.waitunlockf
		lock := mp.waitlock
		mp.waitunlockf = nil
		mp.waitlock = nil
		ok := unlockf(gp, lock)
		if !ok {
			// The unlock callback aborted the park: resume gp immediately.
			casgstatus(gp, .Waiting, .Runnable)
			execute(gp)
		}
	}
	schedule()
}

// ready marks a _Gwaiting goroutine runnable and enqueues it locally. Mirrors
// ready (proc.go:1124).
@(private)
ready :: proc(gp: ^G) {
	if g_status(gp) != .Waiting {
		panic("ready: goroutine is not waiting")
	}
	casgstatus(gp, .Waiting, .Runnable)
	runqput(getm().p, gp, true)
	wakep() // an idle M may pick up the readied goroutine
}

// stack_to_bytes views a Stack's [lo, hi) region as a byte slice, for passing to
// setup_context.
@(private)
stack_to_bytes :: proc "contextless" (s: Stack) -> []u8 {
	return (cast([^]u8)s.lo)[:int(s.hi - s.lo)]
}

// live_goroutines counts goroutines that are not dead. Safe to call only when no
// M is scheduling (e.g. after run() has returned); tests use it to confirm a
// clean finish.
@(private)
live_goroutines :: proc() -> int {
	sync.lock(&allgs_lock)
	defer sync.unlock(&allgs_lock)
	n := 0
	for gp in allgs {
		if g_status(gp) != .Dead {
			n += 1
		}
	}
	return n
}

// next_goid returns a fresh, monotonically increasing goroutine id. The first
// id is 1 (Go's main goroutine is 1 too): intrinsics.atomic_add is fetch-then-
// add (it returns the value BEFORE adding — base/intrinsics "fetch then
// operator"), so the first call returns 0 and +1 yields 1. Mirrors goidgen
// usage in newproc1.
@(private)
next_goid :: proc() -> u64 {
	return intrinsics.atomic_add(&sched.goidgen, 1) + 1
}

// ---------------------------------------------------------------------------
// Run queues
// ---------------------------------------------------------------------------

// The per-P local run queue is a lock-free ring (Go's design): the owner P
// pushes (runqput) and pops (runqget); any P may steal half via runqgrab. The
// owner writes runqtail with store-release; consumers load runqhead/runqtail
// with acquire and commit a consume by CAS'ing runqhead. runnext stays disabled
// while !HAVE_SYSMON (see runqput), so its CAS paths are present but inert.

// runqput enqueues gp on P's run queue. Mirrors runqput (proc.go:7508).
@(private)
runqput :: proc(pp: ^P, gp: ^G, next: bool) {
	gp := gp
	next := next
	when !HAVE_SYSMON {
		next = false // runnext needs sysmon to avoid starvation (Go's guard)
	}

	if next {
		for {
			old := intrinsics.atomic_load_explicit(&pp.runnext, .Acquire)
			_, ok := intrinsics.atomic_compare_exchange_strong_explicit(
				&pp.runnext, old, gp, .Acq_Rel, .Acquire,
			)
			if ok {
				if old == nil {
					return
				}
				gp = old // kick the old runnext into the regular queue
				break
			}
		}
	}

	for {
		h := intrinsics.atomic_load_explicit(&pp.runqhead, .Acquire) // sync with consumers
		t := pp.runqtail
		if t - h < RUNQ_SIZE {
			pp.runq[int(t % RUNQ_SIZE)] = gp
			intrinsics.atomic_store_explicit(&pp.runqtail, t + 1, .Release) // publish
			return
		}
		if runqputslow(pp, gp, h, t) {
			return
		}
		// the queue was full but a steal may have freed space; retry
	}
}

// runqputslow moves half of P's full local run queue, plus gp, to the global
// queue. Returns false if a concurrent steal advanced runqhead (caller retries).
// Mirrors runqputslow (proc.go:7554).
@(private)
runqputslow :: proc(pp: ^P, gp: ^G, h, t: u32) -> bool {
	n := (t - h) / 2
	assert(n == RUNQ_SIZE / 2, "runqputslow: local run queue is not full")

	// Collect pointers first; the Gs still belong to the ring until the CAS
	// below commits the consume, so we must not touch their schedlink yet.
	batch: [RUNQ_SIZE / 2 + 1]^G
	for i in 0 ..< n {
		batch[i] = pp.runq[int((h + i) % RUNQ_SIZE)]
	}
	if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
		&pp.runqhead, h, h + n, .Acq_Rel, .Acquire,
	); !ok {
		return false
	}

	batch[n] = gp
	for i in 0 ..< n {
		batch[i].schedlink = batch[i + 1]
	}
	batch[n].schedlink = nil
	globrunqputbatch(batch[0], batch[n], i32(n + 1))
	return true
}

// runqget pops the next goroutine from P's local run queue (runnext first, then
// the ring). Called by the owner P. Mirrors runqget (proc.go:7628).
@(private)
runqget :: proc(pp: ^P) -> ^G {
	if next := intrinsics.atomic_load_explicit(&pp.runnext, .Acquire); next != nil {
		// Only the owner sets runnext to non-nil, so a lost CAS means a stealer
		// took it; no retry needed.
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
			&pp.runnext, next, nil, .Acq_Rel, .Acquire,
		); ok {
			return next
		}
	}
	for {
		h := intrinsics.atomic_load_explicit(&pp.runqhead, .Acquire)
		t := pp.runqtail
		if t == h {
			return nil
		}
		gp := pp.runq[int(h % RUNQ_SIZE)]
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
			&pp.runqhead, h, h + 1, .Acq_Rel, .Acquire,
		); ok {
			return gp
		}
	}
}

// runqgrab steals up to half of pp's queue into dst[dst_head..], returning the
// count grabbed. Mirrors runqgrab (proc.go:7692). steal_runnext is unused while
// !HAVE_SYSMON (runnext is always nil) but kept for fidelity.
@(private)
runqgrab :: proc(pp: ^P, dst: ^[RUNQ_SIZE]^G, dst_head: u32, steal_runnext: bool) -> u32 {
	for {
		h := intrinsics.atomic_load_explicit(&pp.runqhead, .Acquire)
		t := intrinsics.atomic_load_explicit(&pp.runqtail, .Acquire)
		n := t - h
		n = n - n / 2
		if n == 0 {
			if steal_runnext {
				if next := intrinsics.atomic_load_explicit(&pp.runnext, .Acquire); next != nil {
					if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
						&pp.runnext, next, nil, .Acq_Rel, .Acquire,
					); !ok {
						continue
					}
					dst[dst_head % RUNQ_SIZE] = next
					return 1
				}
			}
			return 0
		}
		if n > RUNQ_SIZE / 2 { // inconsistent h/t snapshot; retry
			continue
		}
		for i in 0 ..< n {
			dst[int((dst_head + i) % RUNQ_SIZE)] = pp.runq[int((h + i) % RUNQ_SIZE)]
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
			&pp.runqhead, h, h + n, .Acq_Rel, .Acquire,
		); ok {
			return n
		}
	}
}

// runqsteal steals half of victim's queue into pp's queue and returns one of the
// stolen goroutines (or nil). Mirrors runqsteal (proc.go:7760).
@(private)
runqsteal :: proc(pp: ^P, victim: ^P, steal_runnext: bool) -> ^G {
	t := pp.runqtail
	n := runqgrab(victim, &pp.runq, t, steal_runnext)
	if n == 0 {
		return nil
	}
	n -= 1
	gp := pp.runq[int((t + n) % RUNQ_SIZE)]
	if n == 0 {
		return gp
	}
	h := intrinsics.atomic_load_explicit(&pp.runqhead, .Acquire)
	// Unconditional guard (not assert, which -disable-assert strips in release):
	// a violated bound would silently wrap the ring and overwrite live Gs.
	// Mirrors Go's always-on `throw` here.
	if t - h + n >= RUNQ_SIZE {
		panic("runqsteal: runq overflow")
	}
	intrinsics.atomic_store_explicit(&pp.runqtail, t + n, .Release)
	return gp
}

// globrunqput appends one goroutine to the global run queue (under sched.lock).
// Mirrors globrunqput (proc.go:7279).
@(private)
globrunqput :: proc(gp: ^G) {
	gp.schedlink = nil
	globrunqputbatch(gp, gp, 1)
}

// globrunqputbatch appends a pre-linked chain [head..tail] of n goroutines to
// the global run queue under sched.lock. Mirrors globrunqputbatch (proc.go:7302).
//
// DEVIATION: Go requires the caller to already hold sched.lock; bifrost's
// global-queue ops are self-locking for simplicity (no nested lock sites).
@(private)
globrunqputbatch :: proc(head, tail: ^G, n: i32) {
	if head == nil {
		return
	}
	sync.lock(&sched.lock)
	defer sync.unlock(&sched.lock)
	if sched.runq.tail == nil {
		sched.runq.head = head
	} else {
		sched.runq.tail.schedlink = head
	}
	sched.runq.tail = tail
	sched.runq.n += n
}

// globrunqget pops one goroutine from the global run queue (under sched.lock).
// Mirrors globrunqget (proc.go:7311). When the deterministic fuzzer is active
// (runtime_set_fuzz_seed), the pick is a pseudo-random index in the queue
// rather than the FIFO head — this is the perturbation surface that the fuzzer
// uses to explore non-FIFO interleavings under a reproducible seed. NOTE: this
// silently breaks gosched_m's "global runq is FIFO for fairness" invariant
// (a yielding G placed at the tail can be picked next). That's the intent of
// the fuzzer (explore unfair orderings to surface bugs), but tests sensitive
// to gosched_m fairness must not run in fuzz mode.
@(private)
globrunqget :: proc() -> ^G {
	sync.lock(&sched.lock)
	defer sync.unlock(&sched.lock)
	gp := sched.runq.head
	if gp == nil {
		return nil
	}
	if sched.runq.n > 1 {
		r := fuzz_next()
		if r != 0 {
			// Walk to a random index and unlink it.
			idx := int(r % u64(sched.runq.n))
			prev: ^G
			curr := gp
			for i := 0; i < idx; i += 1 {
				prev = curr
				curr = curr.schedlink
			}
			if prev == nil {
				sched.runq.head = curr.schedlink
			} else {
				prev.schedlink = curr.schedlink
			}
			if sched.runq.tail == curr {
				sched.runq.tail = prev
			}
			sched.runq.n -= 1
			curr.schedlink = nil
			return curr
		}
	}
	// Normal FIFO path.
	sched.runq.head = gp.schedlink
	if sched.runq.head == nil {
		sched.runq.tail = nil
	}
	sched.runq.n -= 1
	gp.schedlink = nil
	return gp
}

// ---------------------------------------------------------------------------
// Dead-G free list (per P)
// ---------------------------------------------------------------------------

// GFREE_LOCAL_MAX bounds a P's local free-G list before it spills to the
// central list; GFREE_BATCH is how many Gs move at a time. Matches Go's 64/32
// (proc.go gfput/gfget).
@(private)
GFREE_LOCAL_MAX :: 64
@(private)
GFREE_BATCH :: 32

// gfput returns a dead goroutine (with its stack) to P's free list for reuse.
// When the local list grows past GFREE_LOCAL_MAX it spills GFREE_BATCH Gs to
// the central sched.gfree so other Ps can reuse them. Mirrors gfput (proc.go),
// including the cap and the batch size.
//
// The central list is what makes reuse work at all above one P: a goroutine
// usually dies on a different P than the one that created it, so a purely
// per-P list strands dead Gs on the wrong P and the creating P allocates a
// fresh stack every time.
@(private)
gfput :: proc(pp: ^P, gp: ^G) {
	gp.schedlink = pp.gfree.head
	pp.gfree.head = gp
	pp.gfree.n += 1

	if pp.gfree.n <= GFREE_LOCAL_MAX {
		return
	}
	// Detach a batch from the head of the local list, then splice it onto the
	// central list under gfreelock.
	first := pp.gfree.head
	last := first
	moved := i32(1)
	for moved < GFREE_BATCH && last.schedlink != nil {
		last = last.schedlink
		moved += 1
	}
	pp.gfree.head = last.schedlink
	pp.gfree.n -= moved
	last.schedlink = nil

	sync.lock(&sched.gfreelock)
	last.schedlink = sched.gfree.head
	sched.gfree.head = first
	sched.gfree.n += moved
	sync.unlock(&sched.gfreelock)
}

// gfget takes a dead goroutine off P's free list, refilling that list from the
// central sched.gfree when it is empty. Returns nil only when both are empty.
// Mirrors gfget (proc.go).
@(private)
gfget :: proc(pp: ^P) -> ^G {
	if pp.gfree.head == nil {
		sync.lock(&sched.gfreelock)
		for pp.gfree.n < GFREE_BATCH && sched.gfree.head != nil {
			gp := sched.gfree.head
			sched.gfree.head = gp.schedlink
			sched.gfree.n -= 1
			gp.schedlink = pp.gfree.head
			pp.gfree.head = gp
			pp.gfree.n += 1
		}
		sync.unlock(&sched.gfreelock)
	}
	gp := pp.gfree.head
	if gp == nil {
		return nil
	}
	pp.gfree.head = gp.schedlink
	pp.gfree.n -= 1
	gp.schedlink = nil
	return gp
}

// ---------------------------------------------------------------------------
// Sudog pool (per-P cache + central freelist)
// ---------------------------------------------------------------------------

// acquire_sudog returns a clean Sudog, taken from the running P's local cache.
// When that cache is empty it refills a batch from the central list under
// sudoglock, allocating a fresh Sudog only if the central list is also empty.
// Mirrors acquireSudog (proc.go:492).
//
// DEVIATION: Go brackets new(sudog) with acquirem/releasem so the GC cannot run
// mid-allocation. bifrost has no GC, and scheduling is cooperative (no
// preemption point inside this proc), so the running goroutine cannot migrate
// Ps here — getm().p is stable without pinning.
@(private)
acquire_sudog :: proc() -> ^Sudog {
	pp := getm().p
	if pp.sudogcache_n == 0 {
		sync.lock(&sched.sudoglock)
		for pp.sudogcache_n < SUDOG_CACHE / 2 && sched.sudogcache != nil {
			s := sched.sudogcache
			sched.sudogcache = s.next
			s.next = nil
			pp.sudogcache[pp.sudogcache_n] = s
			pp.sudogcache_n += 1
		}
		// Central list empty too: allocate. Kept under sudoglock so concurrent
		// acquire_sudog from different Ms is safe even when runtime_allocator is
		// not thread-safe (the test tracking allocator isn't) — mirrors newg's
		// allocation under allgs_lock. DEVIATION from Go, which allocates outside
		// the lock because mallocgc is thread-safe and uses acquirem for GC.
		if pp.sudogcache_n == 0 {
			pp.sudogcache[0] = new(Sudog, runtime_allocator)
			pp.sudogcache_n = 1
		}
		sync.unlock(&sched.sudoglock)
	}
	pp.sudogcache_n -= 1
	s := pp.sudogcache[pp.sudogcache_n]
	pp.sudogcache[pp.sudogcache_n] = nil
	// Symmetric with release_sudog: a cached sudog must be fully detached. If any
	// of these fire, an upstream waiter (chan / select / sema) failed to clear a
	// field before release — catch it at the next acquire rather than letting it
	// silently corrupt the new op.
	if s.elem != nil {
		panic("acquire_sudog: cached sudog has non-nil elem")
	}
	if s.waitlink != nil {
		panic("acquire_sudog: cached sudog has non-nil waitlink")
	}
	if s.next != nil || s.prev != nil {
		panic("acquire_sudog: cached sudog still linked in a waitq")
	}
	if s.c != nil {
		panic("acquire_sudog: cached sudog has non-nil c")
	}
	if s.isSelect {
		panic("acquire_sudog: cached sudog has isSelect set")
	}
	// release_sudog does not clear success, so a recycled sudog still carries the
	// previous op's result. Reset it here to a clean false: every wake path must
	// set success=true on a successful handoff, so a path that forgets (e.g. a
	// future close that misses a waiter) fails loud-and-safe — a spurious "closed"
	// — instead of silently reporting a stale success with a wrong value.
	s.success = false
	// Same reasoning for the Cond notify-list ticket: release_sudog does not
	// clear it, so reset it here rather than trusting the previous owner.
	s.ticket = 0
	return s
}

// release_sudog returns s to the running P's local cache after asserting it is
// fully detached. A full local cache spills half to the central list under
// sudoglock first. Mirrors releaseSudog (proc.go:530); the checks mirror Go's
// throws so a sudog still linked into a queue or carrying state is caught at the
// point of the bug rather than corrupting the next op that reuses it.
@(private)
release_sudog :: proc(s: ^Sudog) {
	if s.elem != nil {
		panic("release_sudog: sudog with non-nil elem")
	}
	if s.isSelect {
		panic("release_sudog: sudog with isSelect set")
	}
	if s.next != nil || s.prev != nil {
		panic("release_sudog: sudog still linked in a waitq")
	}
	if s.waitlink != nil {
		panic("release_sudog: sudog still on a g.waiting list")
	}
	if s.c != nil {
		panic("release_sudog: sudog with non-nil c")
	}

	pp := getm().p
	if pp.sudogcache_n == SUDOG_CACHE {
		// Transfer half of the local cache to the central list.
		first: ^Sudog
		last: ^Sudog
		for pp.sudogcache_n > SUDOG_CACHE / 2 {
			pp.sudogcache_n -= 1
			p := pp.sudogcache[pp.sudogcache_n]
			pp.sudogcache[pp.sudogcache_n] = nil
			if first == nil {
				first = p
			} else {
				last.next = p
			}
			last = p
		}
		sync.lock(&sched.sudoglock)
		last.next = sched.sudogcache
		sched.sudogcache = first
		sync.unlock(&sched.sudoglock)
	}
	pp.sudogcache[pp.sudogcache_n] = s
	pp.sudogcache_n += 1
}

// sudog_pool_free frees every Sudog held in the per-P caches and the central
// list. Called from runtime_teardown before the Ps and sched are torn down. A
// clean run returns every acquired Sudog before finishing, so this frees all of
// them; a Sudog still attached to a parked goroutine at teardown would be a
// goroutine leak (caught separately by live_goroutines).
@(private)
sudog_pool_free :: proc() {
	for pp in allp {
		for i in 0 ..< int(pp.sudogcache_n) {
			free(pp.sudogcache[i], runtime_allocator)
			pp.sudogcache[i] = nil
		}
		pp.sudogcache_n = 0
	}
	for s := sched.sudogcache; s != nil; {
		next := s.next
		free(s, runtime_allocator)
		s = next
	}
	sched.sudogcache = nil
}

// ---------------------------------------------------------------------------
// Teardown (minimal; a fuller per-test harness arrives in Phase 13.2)
// ---------------------------------------------------------------------------

// runtime_teardown frees everything runtime_init and run allocated and resets
// the global runtime state. Safe to call even if some pieces were never
// allocated, and safe to call twice.
//
// This is part of the PUBLIC API on purpose. bifrost has no GC, so without it a
// process can never reclaim goroutine stacks (96 KiB of address space each),
// the G/M/P structures, the allgs/allms/allp backing, the pooled Sudogs or the
// per-P timer heaps. Call it once the final run() has returned; runtime_init
// may then be called again for a fresh runtime.
runtime_teardown :: proc() {
	// Drain check FIRST, while Gs and Sudogs are still live so the diagnostic can
	// name the stranded goroutine. A leaked sema_acquire would otherwise leave a
	// Sudog in some bucket's head/tail — sudog_pool_free walks per-P caches +
	// central list, NOT sema_table — and the later `sema_table = {}` would
	// orphan it silently. Panic loudly with addr/goid so the bug points at the
	// unreleased acquirer, not at a phantom allocator leak.
	for &root, i in sema_table {
		for s := root.head; s != nil; s = s.waitlink {
			goid: u64
			reason := Wait_Reason.None
			if s.g != nil {
				goid = s.g.goid
				reason = s.g.waitreason
			}
			fmt.eprintfln(
				"  sema leak: bucket=%d addr=%p goid=%d reason=%v",
				i,
				s.elem,
				goid,
				reason,
			)
		}
		if root.head != nil || root.tail != nil || root.nwait != 0 {
			panic("runtime_teardown: sema_table not drained (leaked sema_acquire)")
		}
	}
	sema_table = {}

	// Worker Ms: their OS threads were joined by run(), which normally also
	// released the generation. This is the belt-and-braces path for a runtime
	// that was init'd but never run.
	free_worker_ms()

	// Free each P's timer heap BEFORE freeing Gs / channels. Timer.arg's
	// concrete type is determined by Timer.f, so we dispatch on f to print a
	// useful diagnostic for each known kind. Unknown kinds fall back to raw
	// pointers (rather than guessing — guessing was the C2 bug the prior
	// review caught).
	for pp in allp {
		for t in pp.timers {
			switch t.f {
			case time_sleep_wake:
				gp := cast(^G)t.arg
				goid: u64
				if gp != nil {
					goid = gp.goid
				}
				fmt.eprintfln("  timer leak (sleep): pp=%d deadline=%d goid=%d", pp.id, t.deadline, goid)
			case time_after_fire:
				c := cast(^Hchan)t.arg
				fmt.eprintfln("  timer leak (after): pp=%d deadline=%d chan=%p", pp.id, t.deadline, c)
			case:
				fmt.eprintfln("  timer leak (unknown): pp=%d deadline=%d f=%p arg=%p", pp.id, t.deadline, rawptr(t.f), t.arg)
			}
		}
		delete(pp.timers)
		intrinsics.atomic_store(&pp.ntimers, i32(0))
	}

	for gp in allgs {
		stack_free(gp.stack)
		free(gp, runtime_allocator)
	}
	delete(allgs)
	allgs = nil

	stack_free(m0.g0_stack)

	// Free pooled Sudogs (per-P caches + central list) before the Ps and sched
	// that hold them are reset.
	sudog_pool_free()

	for pp in allp {
		free(pp, runtime_allocator)
	}
	delete(allp, runtime_allocator)
	allp = nil

	sched = {}
	m0 = {}
	g0 = {}
	setg(nil)
	setm(nil)
	// Fuzzer state is a process-level global; reset it so a test that enables
	// fuzz mode cannot silently leak that into the next test.
	intrinsics.atomic_store(&fuzz_seed_state, u64(0))
}
