package bifrost

import "base:runtime"
import "core:sync"
import "core:thread"

// RUNQ_SIZE is the capacity of a P's local run queue ring buffer. Matches
// Go's fixed 256 (runtime2.go: p.runq [256]guintptr).
RUNQ_SIZE :: 256

// SUDOG_CACHE bounds a P's local free-Sudog cache (see acquire_sudog). Matches
// Go's effective per-P sudogcache size (proc.go acquireSudog/releaseSudog).
SUDOG_CACHE :: 128

// Gobuf is a saved execution context: enough CPU register state to resume a
// goroutine where it left off. Mirrors Go's gobuf (runtime2.go:303).
//
// Field order is load-bearing: the context-switch assembly in asm_amd64.asm
// reads and writes these by byte offset. On x86_64 every field is 8 bytes:
//
//	sp   @ 0   stack pointer (points at the saved callee-saved-register frame)
//	pc   @ 8   resume address (informational; the real one travels on the stack)
//	g    @ 16  the G this buf belongs to
//	ctxt @ 24  closure context register (unused for now)
//	lr   @ 32  link register (ARM64 only; kept for shape parity, unused on amd64)
//	bp   @ 40  frame base pointer (informational)
//
// Only `sp` is essential to resume: gogo restores it and pops the callee-saved
// registers (rbx, rbp, r12-r15) that gosave_switch pushed onto the goroutine's
// own stack, then `ret`s to the resume address sitting above them. See
// asm_amd64.asm for the frame layout and why bifrost saves more than Go does.
//
// DEVIATION: current Go's gobuf has no `ret` field (it was removed); the
// stale CLAUDE.md index listed one. bifrost matches current Go.
Gobuf :: struct {
	sp:   uintptr,
	pc:   uintptr,
	g:    ^G,
	ctxt: rawptr,
	lr:   uintptr,
	bp:   uintptr,
}

// Stack describes a goroutine's execution stack. The bounds are exactly
// [lo, hi) with no implicit data on either side. Mirrors Go's stack
// (runtime2.go:460).
Stack :: struct {
	lo: uintptr,
	hi: uintptr,
}

// G_List is a singly linked LIFO stack of goroutines threaded through
// G.schedlink. Used for per-P free lists. Mirrors Go's gList.
G_List :: struct {
	head: ^G,
	n:    i32,
}

// G_Queue is a singly linked FIFO queue of goroutines threaded through
// G.schedlink, with O(1) push-back and pop-front. Used for the global run
// queue. Mirrors Go's gQueue.
G_Queue :: struct {
	head: ^G,
	tail: ^G,
	n:    i32,
}

// G is a goroutine: a stack, a saved register context, and the scheduling
// metadata the runtime needs to suspend and resume it. Mirrors Go's g
// (runtime2.go:471), reduced to the minimal viable subset; GC, profiling,
// cgo, defer/panic and syscall fields are intentionally omitted.
G :: struct {
	// stack is the memory this goroutine runs on: [stack.lo, stack.hi).
	stack: Stack,
	// sched is the saved context. A suspended G is resumed by gogo(&g.sched).
	sched: Gobuf,
	// atomicstatus is the G_Status, transitioned only via casgstatus.
	atomicstatus: G_Status,
	// goid is a unique id assigned at creation (debugging / dumps).
	goid: u64,
	// m is the M currently running this G, or nil.
	m: ^M,
	// schedlink links this G into a G_List/G_Queue (run queues, free lists).
	// DEVIATION: Go uses guintptr to dodge write barriers; bifrost has no GC,
	// so a plain pointer is correct and clearer.
	schedlink: ^G,
	// waitreason explains a _Gwaiting state for deadlock dumps.
	waitreason: Wait_Reason,
	// param is a scratch pointer used to hand a value to a goroutine as it is
	// resumed: a channel op wakes a blocked goroutine and sets param to the
	// completed Sudog. Plain send/recv ignore it (they read their own sudog);
	// select reads it to learn which case fired. Mirrors g.param.
	param: rawptr,
	// waiting is the head of the Sudog list this goroutine is blocked on while in
	// a select (one Sudog per case, linked by Sudog.waitlink, in lock order); nil
	// otherwise. Mirrors g.waiting.
	waiting: ^Sudog,
	// select_done is the select wake-race flag (atomic): when a select is parked
	// on several channels, the first waker to CAS this 0->1 wins the right to
	// resume the goroutine; others skip its sudog. Mirrors g.selectDone.
	select_done: u32,
	// start_fn / start_arg hold the goroutine's entry function and its single
	// argument, read by the goexit_entry trampoline on first run.
	// DEVIATION: Go encodes the start function and arguments on the new
	// goroutine's stack via gostartcallfn (proc.go newproc1); bifrost stores
	// them on the G and uses an Odin trampoline instead — simpler given Odin
	// has no equivalent stack-arg machinery.
	start_fn:  proc(arg: rawptr),
	start_arg: rawptr,
	// temp_allocator is this goroutine's OWN temporary-allocation arena,
	// installed into its context by goexit_entry.
	//
	// It must be per-G, not per-thread. Odin's Context is a VALUE, and
	// runtime.default_context() resolves `temp_allocator.data` eagerly to
	// `&global_default_temp_allocator_data` — which is @thread_local
	// (base/runtime/core.odin:904, core_builtin.odin:63). goexit_entry captures
	// the context once, into a frame on the goroutine's own stack, so without
	// this the arena pointer is frozen to whichever M first ran the goroutine
	// and travels with it to every other M. runtime.Arena has no
	// synchronization (its bump is a plain `block.used += size`), so two
	// migrated goroutines sharing one M's arena silently hand out overlapping
	// memory: measured at 1067 corrupted fmt.tprintf results out of 19,200 at
	// gomaxprocs=8.
	//
	// Go has no equivalent hazard: it has no ambient temp allocator, and its
	// per-P mcache is re-resolved through g.m.p on every allocation rather than
	// captured in a value.
	//
	// A zero value is usable: Default_Temp_Allocator wraps a runtime.Arena that
	// allocates its first block on demand. goexit0 frees the blocks back on
	// goroutine exit so a reused G does not accumulate, and runtime_teardown
	// destroys it.
	temp_allocator: runtime.Default_Temp_Allocator,
}

// Sudog ("pseudo-g") stands in for a goroutine parked on a wait queue, such as a
// channel's send or receive queue. It is a separate struct, not links inside G,
// because the relationship is N:M: a goroutine in a select waits on several
// channels at once (many Sudogs per G), and a channel has many waiters (many
// Sudogs per queue). Mirrors Go's sudog (runtime2.go:404), reduced to the fields
// bifrost uses through Phase 6; the semaphore/treap fields (ticket, parent,
// waittail, waiters) and the timing fields are deferred to sema (Phase 8).
Sudog :: struct {
	// g is the parked goroutine this Sudog represents.
	g: ^G,
	// next/prev doubly link the Sudog into a Waitq. next also threads free Sudogs
	// through the central pool list (sched.sudogcache).
	next: ^Sudog,
	prev: ^Sudog,
	// waitlink threads this Sudog onto its goroutine's G.waiting list (the set of
	// channels a single select is blocked on), in lock order. Distinct from
	// next/prev, which thread it onto one channel's Waitq. Mirrors sudog.waitlink.
	waitlink: ^Sudog,
	// elem points at the data element for the channel op: the value to send, or
	// where to receive into. It may point into the parked goroutine's own stack —
	// the synchronous "direct send" handoff copies through it. Mirrors sudog.elem.
	elem: rawptr,
	// isSelect marks a Sudog enqueued by a select (Phase 7); the dequeue wake-race
	// resolution keys off it. Always false until then.
	isSelect: bool,
	// success records how the goroutine was woken: true if a value was
	// communicated over c, false if c was closed. Read by the goroutine after it
	// resumes. Mirrors sudog.success.
	success: bool,
	// c is the channel this Sudog is blocked on. Mirrors sudog.c.
	c: ^Hchan,
	// ticket is the notify-list ticket for a goroutine parked in a Cond. A
	// waiter is woken only when the list's notify cursor reaches ITS ticket, so
	// a goroutine that arrives later can never consume a notification aimed at
	// an earlier waiter. Mirrors sudog.ticket (runtime2.go:415) as used by
	// notifyListWait / notifyListNotifyOne (sema.go:585 / :665). Unused by the
	// channel and semaphore paths.
	ticket: u32,
}

// M is an OS thread of execution. Mirrors Go's m (runtime2.go:616), reduced
// subset.
//
// The "current g/m" that Go stores in m.tls live in the package's
// @(thread_local) tls_g/tls_m instead (see getg/getm).
M :: struct {
	// g0 is the scheduling goroutine: it owns a dedicated stack on which the
	// scheduler itself (schedule, gopark, etc.) runs, separate from any user
	// goroutine's stack.
	g0: ^G,
	// g0_stack is the mmap'd stack backing g0 (freed at teardown).
	g0_stack: Stack,
	// curg is the user goroutine this M is currently running, or nil.
	curg: ^G,
	// waitunlockf / waitlock hold the pending park unlock callback and its
	// argument while a goroutine running on THIS M is parking: gopark sets them,
	// park_m consults them on g0. Mirrors Go's m.waitunlockf / m.waitlock
	// (runtime2.go). They live on the M (not package globals) because each M can
	// have a goroutine parking concurrently with goroutines on other Ms.
	waitunlockf: proc "c" (gp: ^G, lock: rawptr) -> bool,
	waitlock:    rawptr,
	// p is the P this M is bound to. In bifrost each M is pinned to one P for
	// its lifetime (DEVIATION: Go hands Ps between Ms; bifrost balances by work
	// stealing instead).
	p: ^P,
	// id is a unique M id (== its P's id). m0 (the main thread) is 0.
	id: i64,
	// sched_return is where this M's schedule loop returns to on shutdown:
	// run() for m0, m_thread_entry (ending the thread) for workers.
	sched_return: Gobuf,
	// park is this M's private wakeup note: an idle M sleeps on it in stopm and a
	// producer posts it (after popping the M off sched.midle) to wake exactly this
	// M. Mirrors Go's per-m `note` (m.park). Using a per-M note instead of one
	// shared semaphore means wakeups target a specific sleeper, so permits do not
	// pile up the way a blind shared post would. It is a counting Sema used as a
	// near-binary note: the only way a permit lingers is the timeout/post race in
	// stopm (the wait times out just as a waker posts), leaving at most one stray
	// permit, which the M's next park consumes as a harmless spurious wake.
	//
	// The "at most one" bound holds because wakep and begin_shutdown both post
	// while still holding sched.lock, so an M cannot be re-listed (and therefore
	// re-posted) between mget and the post. Posting after dropping the lock —
	// which is what wakep used to do — instead bounded outstanding permits by the
	// number of concurrent wakers, i.e. by the thread count.
	//
	// m0=={} / fresh worker Ms reset it each run, so nothing accumulates across
	// runs.
	// DEVIATION: Go's `note` has an explicit noteclear reset; bifrost relies on
	// the next wait consuming the stray permit instead.
	park: sync.Sema,
	// idle_link threads this M onto sched.midle (the LIFO idle-M stack) while it
	// is parked. nil when running. Mirrors Go's m.schedlink usage in mput/mget.
	idle_link: ^M,
	// thread is the OS thread handle for a worker M (nil for m0), used to join.
	thread: ^thread.Thread,
	// alllink threads this M onto the global allm list.
	alllink: ^M,
}

// P is a logical processor: it holds a local run queue and the resources an M
// needs to run goroutine code. gomaxprocs == len(allp). Mirrors Go's p
// (runtime2.go:774), reduced subset.
P :: struct {
	// id indexes into allp.
	id: i32,
	// status is the P_Status (Idle/Running/...).
	status: P_Status,
	// m is the M this P is bound to, or nil when idle.
	m: ^M,
	// runqhead/runqtail bound the lock-free local run queue ring.
	runqhead: u32,
	runqtail: u32,
	// runq is the local run queue ring buffer of runnable Gs.
	runq: [RUNQ_SIZE]^G,
	// runnext, if set, is a G to run before anything in runq: it inherits the
	// current G's time slice so communicate-and-wait pairs schedule as a unit.
	// Mirrors Go's runnext slot exactly (runtime2.go:808).
	runnext: ^G,
	// schedtick counts scheduling decisions made on this P. findrunnable polls
	// the global run queue every 61st tick so that a self-sustaining local
	// producer cannot monopolise the P. Mirrors Go's p.schedtick and the
	// `pp.schedtick%61 == 0` fairness check in findRunnable (proc.go). Written
	// only by the M that owns this P, so a plain u32 needs no atomic.
	schedtick: u32,
	// gfree is a cache of dead Gs (with stacks) available for reuse.
	gfree: G_List,
	// sudogcache is this P's local cache of free Sudogs; sudogcache_n is how many
	// of the SUDOG_CACHE slots are live. acquire_sudog/release_sudog hit this
	// first and only touch the central list (sched.sudogcache) in batches. A P is
	// owned by exactly one M at a time, so this needs no lock (same as Go's
	// p.sudogcache).
	sudogcache:   [SUDOG_CACHE]^Sudog,
	sudogcache_n: i32,
	// timers is a min-heap (by `deadline` — renamed from Go's `when` because
	// that's an Odin keyword) of pending timers scheduled on this P. time_sleep
	// pushes onto the running M's P's heap, and the scheduler fires expired
	// timers in findrunnable. timers_lock guards it; cross-P firing/stealing
	// is a follow-up.
	timers:      [dynamic]Timer,
	timers_lock: sync.Mutex,
	// ntimers is len(timers), maintained atomically so timer_run_expired can
	// early-out on a plain load — findrunnable calls it on every scheduler pass,
	// and both mono_now_ns (a clock_gettime syscall) and timers_lock are far too
	// expensive to pay when the heap is empty. Mirrors the role of Go's
	// timers.len / timers.minWhen (time.go), which findRunnable likewise consults
	// before doing any timer work.
	ntimers: i32,
}

// Schedt is the global scheduler state shared by all Ms. Mirrors Go's schedt
// (runtime2.go:932), reduced subset.
Schedt :: struct {
	// goidgen is the monotonically increasing goroutine id counter, bumped
	// atomically by newg. Mirrors goidgen atomic.Uint64.
	goidgen: u64,
	// lock guards the global runq AND the idle-M list (midle/nmidle).
	// LOCK ORDER: sched.lock may be held while taking allgs_lock (checkdead does
	// this); never the reverse. Hold sched.lock first if both are needed.
	lock: sync.Mutex,
	// runq is the global run queue, a fallback/overflow for the per-P runqs.
	runq: G_Queue,
	// midle is a LIFO stack of idle (parked) Ms, linked through M.idle_link; an M
	// pushes itself here in stopm and a waker pops one to signal. nmidle is its
	// length. Both are guarded by `lock`. Mirrors Go's sched.midle / sched.nmidle.
	midle:  ^M,
	nmidle: i32,
	// grunning is the number of live (non-dead) goroutines, bumped atomically by
	// newg and goexit0. When it reaches 0 the run is complete (begin_shutdown).
	grunning: i32,
	// shutdown, once set (atomic), tells every M's findrunnable to return nil so
	// the schedule loop exits.
	shutdown: bool,
	// gfree is the central free-G list: dead Gs (with their stacks) spilled from
	// the per-P caches so that any P can reuse them. gfreelock guards it.
	// Mirrors Go's sched.gFree / sched.gFlock (proc.go gfput/gfget).
	//
	// Without it a G that dies on a different P than created it is stranded: the
	// creating P's local list stays empty, newg falls to the allocate path, and a
	// program with fixed concurrency still mmaps a fresh 32 KiB stack per
	// goroutine CREATION until it exhausts vm.max_map_count. A dedicated lock
	// (not sched.lock) keeps G churn from contending with run-queue and idle-M
	// operations.
	gfree:     G_List,
	gfreelock: sync.Mutex,
	// sudogcache is the central free-Sudog list (LIFO via Sudog.next), a backstop
	// shared by all Ps and refilled/spilled in batches; sudoglock guards it.
	// Mirrors Go's sched.sudogcache / sched.sudoglock. A dedicated lock (not
	// sched.lock) keeps sudog churn from contending with run-queue / idle-M ops.
	sudogcache: ^Sudog,
	sudoglock:  sync.Mutex,
}

// Package-global runtime state. Mirrors Go's runtime globals (proc.go /
// runtime2.go): allgs, allm, allp, sched, gomaxprocs, m0, g0.
@(private)
allgs: [dynamic]^G

@(private)
allm: ^M

@(private)
allp: []^P

// allms holds the worker Ms created by run() (one per P beyond P0), for joining
// and freeing. m0 is not in this slice.
@(private)
allms: []^M

@(private)
sched: Schedt

@(private)
gomaxprocs: i32

// runtime_allocator is the single allocator used for all runtime-owned objects
// (G, P, M, the allp/allms/allgs backing). Captured at runtime_init from the
// caller's context, so allocations made from any M's thread and the frees at
// teardown all go through one allocator.
//
// It need NOT be thread-safe: every use is serialized by runtime_alloc_lock.
// That serialization is deliberate — runtime_init takes an arbitrary
// `allocator` parameter, so callers may reasonably pass an arena or a bump
// allocator, and the allocation sites are spread across newg, newm,
// acquire_sudog, run and runtime_teardown, which previously ran under two
// DIFFERENT locks (allgs_lock and sched.sudoglock) and, in newm's case, under
// none at all. Three disjoint critical sections meant three Ms could be inside
// the allocator at once, while the comments at those sites each claimed their
// own lock made it safe.
@(private)
runtime_allocator: runtime.Allocator

// runtime_alloc_lock serializes every use of runtime_allocator.
//
// LOCK ORDER: innermost. It may be taken while holding allgs_lock (newg) or
// sched.sudoglock (acquire_sudog); nothing may be taken while holding it.
@(private)
runtime_alloc_lock: sync.Mutex

// allgs_lock guards appends to and scans of allgs, which are now performed from
// multiple Ms (newg, deadlock reporting, teardown). LOCK ORDER: it is the inner
// lock — code already holding sched.lock may take it (checkdead), but code
// holding allgs_lock must NOT take sched.lock.
@(private)
allgs_lock: sync.Mutex

// m0 is the M for the main OS thread; g0 is its scheduling goroutine.
@(private)
m0: M

@(private)
g0: G

// tls_g / tls_m are the goroutine and the M currently executing on THIS OS
// thread. They use real thread-local storage so getg()/getm() resolve
// per-thread, which is what makes multi-M scheduling possible. Go reads g from
// a TLS slot inside its context-switch assembly; bifrost keeps the equivalent
// here, updated by the scheduler (execute/mcall/mstart) around each switch.
@(private)
@(thread_local)
tls_g: ^G

@(private)
@(thread_local)
tls_m: ^M

// runtime_init initializes the global scheduler state for `procs` logical
// processors and wires up m0/g0. It allocates allp and zeroes sched; it does
// NOT start any OS threads. Mirrors the allp/sched setup portion of Go's
// schedinit (proc.go:835) + procresize.
//
// ALLOCATOR: `allocator` is captured as runtime_allocator and used for every
// runtime-owned object for the life of the runtime. It does NOT need to be
// thread-safe — bifrost serializes every use behind runtime_alloc_lock — so an
// arena or bump allocator is a valid choice. It must, however, outlive the
// runtime, and runtime_teardown must be called before it is reset or destroyed.
//
// Note this allocator is NOT what goroutines allocate from: a goroutine runs
// under runtime.default_context(), so its `context.allocator` is the malloc
// heap. See go_.
runtime_init :: proc(procs: i32, allocator := context.allocator) {
	assert(procs >= 1, "runtime_init: gomaxprocs must be >= 1")

	gomaxprocs = procs
	runtime_allocator = allocator
	sched = {}
	allgs_lock = {}
	runtime_alloc_lock = {}
	allgs = make([dynamic]^G, 0, 0, allocator)

	allp = make([]^P, int(procs), allocator)
	for i in 0 ..< int(procs) {
		pp := new(P, allocator)
		pp.id = i32(i)
		pp.status = .Idle
		allp[i] = pp
	}

	// Wire up the main thread's M and its scheduling goroutine.
	m0 = {}
	g0 = {}
	m0.id = 0
	m0.g0 = &g0
	g0.m = &m0
	g0.atomicstatus = .Running
	allm = &m0

	// This OS thread is m0, currently "running" g0 (the scheduler).
	setm(&m0)
	setg(&g0)

	// Bind m0 to P0 so go_ can enqueue onto the local run queue before run()
	// starts the scheduler. The P stays .Idle until run() marks it .Running;
	// status does not affect runqput.
	m0.p = allp[0]
	allp[0].m = &m0
}

// getg returns the goroutine currently executing on this OS thread. Mirrors
// Go's getg() (a compiler intrinsic reading thread-local storage).
//
// OPTIMIZATION BARRIER (load-bearing — do not remove the attribute): this proc
// and its three siblings below are the ONLY code permitted to touch
// tls_g/tls_m, and each is @(optimization_mode = "none") so the compiler cannot
// hoist the thread-pointer read out of it and cache it in a callee-saved
// register.
//
// Go does not need this because its compiler dedicates a register to g and
// reloads it after every preemption point. bifrost cannot: its context switch
// (asm_amd64.asm) restores callee-saved registers from the SUSPENDED
// GOROUTINE'S OWN STACK, while the ELF TLS ABI entitles LLVM to treat the
// thread pointer as invariant for a function activation and hoist `mov %fs:0x0`
// into exactly those registers. A cached base then follows the goroutine onto
// whatever M resumes it and addresses the wrong thread's TLS block — which
// miscompiled the multi-M scheduler at every optimization level above
// -o:minimal (examples/parallel segfaulted 10/10 at -o:speed).
@(optimization_mode = "none")
getg :: proc "contextless" () -> ^G {
	return tls_g
}

// getm returns the M (OS thread abstraction) currently executing. Equivalent
// to Go's getg().m. See getg for why this is an optimization barrier.
@(optimization_mode = "none")
getm :: proc "contextless" () -> ^M {
	return tls_m
}

// setg / setm are the ONLY writers of tls_g / tls_m. Routing every write
// through an opaque proc is what stops the compiler proving the TLS base is
// loop- or call-invariant across a context switch. See getg.
@(private)
@(optimization_mode = "none")
setg :: proc "contextless" (gp: ^G) {
	tls_g = gp
}

@(private)
@(optimization_mode = "none")
setm :: proc "contextless" (mp: ^M) {
	tls_m = mp
}
