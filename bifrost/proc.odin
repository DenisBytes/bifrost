package bifrost

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
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

// go_ spawns a new goroutine running fn(arg). It is bifrost's equivalent of
// Go's `go fn(arg)`. The goroutine becomes runnable immediately but does not
// run until the scheduler (run) is active and reaches it. Mirrors newproc
// (proc.go).
go_ :: proc(fn: proc(arg: rawptr), arg: rawptr = nil) {
	assert(allp != nil, "bifrost: call runtime_init before go_")
	gp := newg(fn, arg)
	// Enqueue onto the current M's P (allp[0] for the main thread before run).
	runqput(getm().p, gp, true)
	wakep()
}

// run starts the scheduler on `gomaxprocs` OS threads and returns when every
// goroutine has finished. Call runtime_init first, then go_ to spawn work, then
// run. It spins up gomaxprocs-1 worker Ms (one per P beyond P0), runs m0's own
// schedule loop on P0, and on shutdown joins the workers before returning.
run :: proc() {
	assert(allp != nil, "bifrost: call runtime_init before run")
	scheduler_start()

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
	// and exit its thread. Join + free them.
	for mp in allms {
		thread.destroy(mp.thread) // joins, then frees the Thread handle
	}
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

// scheduler_start allocates the g0 scheduling stack (once) and marks P0
// running. Called from every run(); the g0 stack is allocated only on the
// first call and reused thereafter, so repeated run()/idle cycles within one
// runtime_init don't leak mmap regions (matches Go: the g0 stack lives for the
// M's lifetime, not per scheduler entry).
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
	tls_m = mp
	tls_g = mp.g0
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
	tls_g = getm().g0
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
	tls_g = &g0
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
	sync.lock(&sched.lock)
	mp := mget()
	sync.unlock(&sched.lock)
	if mp != nil {
		sync.sema_post(&mp.park)
	}
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
		for gp in allgs {
			if g_status(gp) == .Waiting {
				fmt.eprintfln("  goroutine %d: waiting (%v)", gp.goid, gp.waitreason)
			}
		}
		panic("all goroutines are asleep - deadlock!")
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
	tls_g = gp
	gogo(&gp.sched)
}

// findrunnable returns the next goroutine to run, or nil only when shutdown has
// been signalled. It checks the local run queue, then the global queue; if both
// are empty it parks the M (stopm) and retries. Mirrors the structure of
// findRunnable (proc.go:3395) minus netpoll; work stealing is added in
// stealWork-equivalent steal_work() (Inc 4).
@(private)
findrunnable :: proc() -> ^G {
	mp := getm()
	for {
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
	// Worker Ms: their OS threads were already joined + destroyed by run(); free
	// each M's g0 stack, g0, and the M itself.
	for mp in allms {
		stack_free(mp.g0_stack)
		free(mp.g0, runtime_allocator)
		free(mp, runtime_allocator)
	}
	delete(allms, runtime_allocator)
	allms = nil

	for gp in allgs {
		stack_free(gp.stack)
		free(gp, runtime_allocator)
	}
	delete(allgs)
	allgs = nil

	stack_free(m0.g0_stack)

	for pp in allp {
		free(pp, runtime_allocator)
	}
	delete(allp, runtime_allocator)
	allp = nil

	sched = {}
	m0 = {}
	g0 = {}
	tls_g = nil
	tls_m = nil
}
