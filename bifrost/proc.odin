package bifrost

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:sync"

// Phase 4: a single-M, single-P cooperative scheduler. One OS thread (m0) runs
// goroutines on its P (allp[0]); goroutines yield voluntarily via gosched, park
// via gopark, and are resumed via goready. Mirrors the structure of Go's
// scheduler (proc.go) reduced to one M and one P, with no work stealing,
// netpoll, sysmon, or preemption yet (those arrive in later phases).
//
// Control-flow model (see asm_amd64.asm): a running goroutine reaches the
// scheduler by calling mcall(fn), which saves the goroutine's context and runs
// fn on g0's stack. fn (gosched_m / park_m / goexit0) manipulates queues and
// calls schedule(), which picks the next goroutine and gogo's into it. The
// scheduler stack (g0) is reset to a fixed base on every mcall, so it never
// accumulates frames across switches.

// HAVE_SYSMON reports whether a system-monitor thread exists to preempt
// long-running goroutines. It is false until Phase 10. While false, runqput
// must NOT use the runnext slot: runnext makes a ready'd goroutine share the
// current one's time slice, and without sysmon to break that slice a
// communicate-and-wait pair would starve everyone else. Go applies the same
// guard (proc.go runqput: `if !haveSysmon && next { next = false }`).
@(private)
HAVE_SYSMON :: false

// g0_stack is the scheduling stack for m0.g0 (the stack schedule/execute and
// the mcall continuations run on). Allocated by scheduler_start.
@(private)
g0_stack: Stack

// sched_return saves the OS thread's context at the point it entered the
// scheduler (run); the scheduler gogo's here when no goroutines remain.
@(private)
sched_return: Gobuf

// Pending park unlock callback + argument, consulted by park_m.
// DEVIATION: Go stores these on the m (m.waitunlockf / m.waitlock); bifrost is
// single-M, so package globals suffice until Phase 5 moves them onto M.
@(private)
park_unlockf: proc "c" (gp: ^G, lock: rawptr) -> bool

@(private)
park_lock: rawptr

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// go_ spawns a new goroutine running fn(arg). It is bifrost's equivalent of
// Go's `go fn(arg)`. The goroutine becomes runnable immediately but does not
// run until the scheduler (run) is active and reaches it. Mirrors newproc
// (proc.go).
go_ :: proc(fn: proc(arg: rawptr), arg: rawptr = nil) {
	assert(allp != nil, "bifrost: call runtime_init before go_")
	gp := newg(fn, arg)
	// Enqueue onto the current M's P (allp[0] for the main thread before run).
	runqput(getm().p, gp, true)
}

// run starts the scheduler on the calling OS thread and returns when every
// goroutine has finished. Call runtime_init first, then go_ to spawn work,
// then run. Equivalent to the role Go's main thread plays after the runtime
// boots.
run :: proc() {
	assert(allp != nil, "bifrost: call runtime_init before run")
	scheduler_start()

	// Save the OS thread context and jump onto g0 to run schedule(). The
	// scheduler returns here (via gogo(&sched_return)) once no goroutines
	// remain runnable.
	g0_bytes := (cast([^]u8)g0_stack.lo)[:int(g0_stack.hi - g0_stack.lo)]
	setup_context(&g0.sched, cast(rawptr)schedule_bootstrap, g0_bytes)
	g0.sched.g = &g0 // parity with newg; bifrost's asm never reads gobuf.g today
	gosave_switch(&sched_return, &g0.sched)
}

// gosched yields the processor, allowing other goroutines to run, and resumes
// the caller later. Mirrors Go's Gosched (proc.go:393).
gosched :: proc() {
	mcall(gosched_m)
}

// gopark puts the current goroutine into a waiting state and switches to the
// scheduler. After the status flips to _Gwaiting, park_m calls unlockf(gp,
// lock) on the scheduler stack (if unlockf != nil); if unlockf returns false
// the park is aborted and the goroutine resumes. The goroutine stays parked
// until some other goroutine calls goready on it. Mirrors gopark
// (proc.go:449).
gopark :: proc(unlockf: proc "c" (gp: ^G, lock: rawptr) -> bool, lock: rawptr, reason: Wait_Reason) {
	gp := getg()
	gp.waitreason = reason
	park_unlockf = unlockf
	park_lock = lock
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

	gp := gfget(pp)
	if gp == nil {
		gp = new(G)
		s, err := stack_alloc()
		if err != .None {
			panic("newg: stack allocation failed")
		}
		gp.stack = s
		casgstatus(gp, .Idle, .Dead) // a zero G reads as _Gidle
		append(&allgs, gp)
	}

	gp.start_fn = fn
	gp.start_arg = arg

	stack_bytes := (cast([^]u8)gp.stack.lo)[:int(gp.stack.hi - gp.stack.lo)]
	setup_context(&gp.sched, cast(rawptr)goexit_entry, stack_bytes)
	gp.sched.g = gp
	gp.goid = next_goid()

	casgstatus(gp, .Dead, .Runnable)
	return gp
}

// goexit_entry is the first thing every goroutine runs (set as its initial
// context by newg). It establishes an Odin context, runs the user function,
// then exits. Entered via gogo, so it has no incoming context — hence "c" and
// the explicit context setup, mirroring how core:thread bootstraps a thread.
//
// PHASE-5 CAVEAT: runtime.default_context() hands every goroutine the SAME
// process-global temp allocator and heap allocator. That is safe under the
// single-M cooperative scheduler (no two goroutines run at once), but the
// global temp allocator is not thread-safe — Phase 5 (multi-M) must give each
// goroutine its own context/temp allocator and restore it on resume.
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
	schedule()
}

// ---------------------------------------------------------------------------
// Scheduler core (runs on g0)
// ---------------------------------------------------------------------------

// scheduler_start allocates the g0 scheduling stack (once) and marks P0
// running. Called from every run(); the g0 stack is allocated only on the
// first call and reused thereafter, so repeated run()/idle cycles within one
// runtime_init don't leak mmap regions (matches Go: the g0 stack lives for the
// M's lifetime, not per scheduler entry).
@(private)
scheduler_start :: proc() {
	if g0_stack.lo == 0 {
		// A roomier stack for the scheduler than a normal goroutine: schedule
		// -> execute and the continuations run here.
		s, err := stack_alloc(STACK_MIN * 4)
		if err != .None {
			panic("scheduler_start: g0 stack allocation failed")
		}
		g0_stack = s
		g0.stack = s
	}
	// Bind the main M to P0 for the duration of the run (idempotent).
	acquirep(&m0, allp[0])
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
	tls_g = &g0
	schedule()
}

// schedule picks the next runnable goroutine and executes it. If none is
// runnable, it either reports a deadlock (some goroutine is parked with nobody
// to wake it) or returns control to the OS thread that called run(). Mirrors
// schedule (proc.go:4141) without findRunnable's stealing/blocking.
@(private)
schedule :: proc() {
	gp := findrunnable()
	if gp == nil {
		check_dead() // panics on deadlock / lost wakeup; returns only if all dead
		gogo(&sched_return) // no work left: return to run()'s caller
		return // unreachable: gogo does not return, but the compiler can't know
	}
	execute(gp)
}

// check_dead inspects every goroutine when the run queues have drained, to tell
// apart three terminal situations. A goroutine left _Grunnable/_Grunning while
// the scheduler is idle is a lost-wakeup invariant violation (a bug). If the
// only survivors are _Gwaiting, the program is genuinely deadlocked — report
// each parked goroutine's id and wait reason. If everything is dead, return so
// the caller hands control back to the OS thread. Mirrors Go's checkdead
// (proc.go).
@(private)
check_dead :: proc() {
	runnable := 0
	waiting := 0
	for gp in allgs {
		#partial switch g_status(gp) {
		case .Runnable, .Running:
			runnable += 1
		case .Waiting:
			waiting += 1
		}
	}
	if runnable > 0 {
		fmt.panicf("checkdead: %d runnable goroutine(s) but the scheduler is idle (lost wakeup)", runnable)
	}
	if waiting > 0 {
		for gp in allgs {
			if g_status(gp) == .Waiting {
				fmt.eprintfln("  goroutine %d: waiting (%v)", gp.goid, gp.waitreason)
			}
		}
		panic("all goroutines are asleep - deadlock!")
	}
}

// execute runs gp: bind it to the M, flip _Grunnable -> _Grunning, and gogo
// into it. Never returns. Mirrors execute (proc.go:3337).
@(private)
execute :: proc(gp: ^G) {
	mp := getm()
	mp.curg = gp
	gp.m = mp
	casgstatus(gp, .Runnable, .Running)
	tls_g = gp
	gogo(&gp.sched)
}

// findrunnable returns the next goroutine to run: local run queue first, then
// the global queue. Single-M, so no work stealing or netpoll. Mirrors the
// fast path of findRunnable (proc.go).
@(private)
findrunnable :: proc() -> ^G {
	if gp := runqget(getm().p); gp != nil {
		return gp
	}
	return globrunqget()
}

// mcall saves the current goroutine and runs fn(gp) on the scheduler stack.
// fn must not return; it ends by gogo-ing into a goroutine or to sched_return.
// Mirrors Go's mcall (asm) + its callers. The Odin wrapper computes the
// operands; the stack switch itself is mcall_switch (asm_amd64.asm).
@(private)
mcall :: proc(fn: proc "c" (gp: ^G)) {
	gp := getg()
	g0p := gp.m.g0
	tls_g = g0p
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
	casgstatus(gp, .Running, .Waiting)
	dropg()

	if park_unlockf != nil {
		ok := park_unlockf(gp, park_lock)
		park_unlockf = nil
		park_lock = nil
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
}

// live_goroutines counts goroutines that are not dead; used to distinguish "all
// work finished" from "deadlock" when the run queues drain.
@(private)
live_goroutines :: proc() -> int {
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
	assert(t - h + n < RUNQ_SIZE, "runqsteal: runq overflow")
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
// Mirrors globrunqget (proc.go:7311).
@(private)
globrunqget :: proc() -> ^G {
	sync.lock(&sched.lock)
	defer sync.unlock(&sched.lock)
	gp := sched.runq.head
	if gp == nil {
		return nil
	}
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

// gfput returns a dead goroutine (with its stack) to P's free list for reuse.
// Mirrors gfput (proc.go).
@(private)
gfput :: proc(pp: ^P, gp: ^G) {
	gp.schedlink = pp.gfree.head
	pp.gfree.head = gp
	pp.gfree.n += 1
}

// gfget takes a dead goroutine off P's free list, or returns nil. Mirrors
// gfget (proc.go).
@(private)
gfget :: proc(pp: ^P) -> ^G {
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
// Teardown (minimal; a fuller per-test harness arrives in Phase 13.2)
// ---------------------------------------------------------------------------

// runtime_teardown frees everything runtime_init / run allocated and resets the
// global runtime state, so tests can boot a fresh runtime. Safe to call even if
// some pieces were never allocated.
@(private)
runtime_teardown :: proc() {
	for gp in allgs {
		stack_free(gp.stack)
		free(gp)
	}
	delete(allgs)
	allgs = nil

	stack_free(g0_stack)
	g0_stack = {}

	for pp in allp {
		free(pp)
	}
	delete(allp)
	allp = nil

	sched = {}
	m0 = {}
	g0 = {}
	tls_g = nil
	tls_m = nil
	park_unlockf = nil
	park_lock = nil
}
