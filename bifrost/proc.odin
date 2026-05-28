package bifrost

import "base:intrinsics"
import "base:runtime"

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
	gp := newg(fn, arg)
	// Single-P: enqueue onto P0's local run queue.
	runqput(allp[0], gp, true)
}

// run starts the scheduler on the calling OS thread and returns when every
// goroutine has finished. Call runtime_init first, then go_ to spawn work,
// then run. Equivalent to the role Go's main thread plays after the runtime
// boots.
run :: proc() {
	scheduler_start()

	// Save the OS thread context and jump onto g0 to run schedule(). The
	// scheduler returns here (via gogo(&sched_return)) once no goroutines
	// remain runnable.
	g0_bytes := (cast([^]u8)g0_stack.lo)[:int(g0_stack.hi - g0_stack.lo)]
	setup_context(&g0.sched, cast(rawptr)schedule_bootstrap, g0_bytes)
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
	gp := current_g
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
	pp := allp[0]

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
// DEVIATION: Go threads the equivalent of this trampoline through goexit as the
// new goroutine's return address (proc.go newproc1 + asm goexit); bifrost uses
// a plain Odin entry that reads start_fn/start_arg off the G.
@(private)
goexit_entry :: proc "c" () {
	context = runtime.default_context()
	gp := current_g
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
	gp.m = nil
	m0.curg = nil // dropg
	gfput(allp[0], gp)
	schedule()
}

// ---------------------------------------------------------------------------
// Scheduler core (runs on g0)
// ---------------------------------------------------------------------------

// scheduler_start allocates the g0 scheduling stack and marks P0 running. Call
// once, from run.
@(private)
scheduler_start :: proc() {
	// A roomier stack for the scheduler than a normal goroutine: schedule ->
	// execute and the continuations run here.
	s, err := stack_alloc(STACK_MIN * 4)
	if err != .None {
		panic("scheduler_start: g0 stack allocation failed")
	}
	g0_stack = s
	g0.stack = s
	allp[0].status = .Running
}

// schedule_bootstrap is the first thing that runs on g0 when run() hands over
// control. Entered via gosave_switch (no incoming context), so it is "c" and
// sets up a context before calling into the scheduler.
@(private)
schedule_bootstrap :: proc "c" () {
	context = runtime.default_context()
	current_g = &g0
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
		if live_goroutines() > 0 {
			panic("all goroutines are asleep - deadlock!")
		}
		gogo(&sched_return) // no work left: return to run()'s caller
	}
	execute(gp)
}

// execute runs gp: bind it to the M, flip _Grunnable -> _Grunning, and gogo
// into it. Never returns. Mirrors execute (proc.go:3337).
@(private)
execute :: proc(gp: ^G) {
	m0.curg = gp
	gp.m = &m0
	casgstatus(gp, .Runnable, .Running)
	current_g = gp
	gogo(&gp.sched)
}

// findrunnable returns the next goroutine to run: local run queue first, then
// the global queue. Single-M, so no work stealing or netpoll. Mirrors the
// fast path of findRunnable (proc.go).
@(private)
findrunnable :: proc() -> ^G {
	if gp := runqget(m0.p); gp != nil {
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
	gp := current_g
	g0p := gp.m.g0
	current_g = g0p
	mcall_switch(&gp.sched, cast(rawptr)fn, gp, g0p.sched.sp)
	// Resumed: execute() set current_g back to gp before gogo'ing here.
}

// gosched_m is the gosched continuation on g0: requeue the yielding goroutine
// (globally, for fairness) and pick the next. Mirrors gosched_m / goschedImpl
// (proc.go:4355 / :4313).
@(private)
gosched_m :: proc "c" (gp: ^G) {
	context = runtime.default_context()
	casgstatus(gp, .Running, .Runnable)
	m0.curg = nil // dropg
	globrunqput(gp)
	schedule()
}

// park_m is the gopark continuation on g0: flip _Grunning -> _Gwaiting, run the
// unlock callback, and either resume (if it vetoes the park) or schedule away.
// Mirrors park_m (proc.go:4259).
@(private)
park_m :: proc "c" (gp: ^G) {
	context = runtime.default_context()
	casgstatus(gp, .Running, .Waiting)
	m0.curg = nil // dropg

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
	runqput(m0.p, gp, true)
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

// next_goid returns a fresh, monotonically increasing goroutine id (the main
// goroutine in Go is 1, so bifrost's first is 1 too). Mirrors goidgen usage in
// newproc1.
@(private)
next_goid :: proc() -> u64 {
	return intrinsics.atomic_add(&sched.goidgen, 1) + 1
}

// ---------------------------------------------------------------------------
// Run queues
// ---------------------------------------------------------------------------

// runqput enqueues gp on P's run queue. With sysmon absent (HAVE_SYSMON ==
// false) the `next` (runnext) fast path is disabled to avoid starvation; the
// runnext logic is kept, gated, so Phase 10 can enable it. Mirrors runqput
// (proc.go:7508).
//
// DEVIATION: single-M, so plain loads/stores replace Go's atomic
// load-acquire/store-release ring operations; Phase 5 reintroduces atomics for
// the multi-M lock-free queue.
@(private)
runqput :: proc(pp: ^P, gp: ^G, next: bool) {
	gp := gp
	next := next
	when !HAVE_SYSMON {
		next = false
	}

	if next {
		old := pp.runnext
		pp.runnext = gp
		if old == nil {
			return
		}
		gp = old // kick the old runnext into the regular queue
	}

	h := pp.runqhead
	t := pp.runqtail
	if t - h < RUNQ_SIZE {
		pp.runq[int(t % RUNQ_SIZE)] = gp
		pp.runqtail = t + 1
		return
	}
	runqputslow(pp, gp, h, t)
}

// runqputslow moves half of P's full local run queue, plus gp, to the global
// queue, keeping the local queue from monopolising runnable work. Mirrors
// runqputslow (proc.go:7554).
@(private)
runqputslow :: proc(pp: ^P, gp: ^G, h, t: u32) {
	n := (t - h) / 2

	head: ^G
	tail: ^G
	for i in 0 ..< n {
		gi := pp.runq[int((h + i) % RUNQ_SIZE)]
		if head == nil {
			head = gi
		} else {
			tail.schedlink = gi
		}
		tail = gi
	}
	// Append gp to the batch.
	if head == nil {
		head = gp
	} else {
		tail.schedlink = gp
	}
	tail = gp
	tail.schedlink = nil

	pp.runqhead = h + n
	globrunqputbatch(head, tail, i32(n + 1))
}

// runqget pops the next goroutine from P's local run queue (runnext first, then
// the ring). Mirrors runqget (proc.go:7628).
@(private)
runqget :: proc(pp: ^P) -> ^G {
	if pp.runnext != nil {
		gp := pp.runnext
		pp.runnext = nil
		return gp
	}
	h := pp.runqhead
	t := pp.runqtail
	if t == h {
		return nil
	}
	gp := pp.runq[int(h % RUNQ_SIZE)]
	pp.runqhead = h + 1
	return gp
}

// globrunqput appends one goroutine to the global run queue. Mirrors
// globrunqput (proc.go:7279). (No lock yet: single-M. Phase 5 adds sched.lock.)
@(private)
globrunqput :: proc(gp: ^G) {
	gp.schedlink = nil
	globrunqputbatch(gp, gp, 1)
}

// globrunqputbatch appends a pre-linked chain [head..tail] of n goroutines to
// the global run queue. Mirrors globrunqputbatch (proc.go:7302).
@(private)
globrunqputbatch :: proc(head, tail: ^G, n: i32) {
	if head == nil {
		return
	}
	if sched.runq.tail == nil {
		sched.runq.head = head
	} else {
		sched.runq.tail.schedlink = head
	}
	sched.runq.tail = tail
	sched.runq.n += n
}

// globrunqget pops one goroutine from the global run queue. Mirrors
// globrunqget (proc.go:7311).
@(private)
globrunqget :: proc() -> ^G {
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
	current_g = nil
	park_unlockf = nil
	park_lock = nil
}
