package bifrost

import "core:sync"

// RUNQ_SIZE is the capacity of a P's local run queue ring buffer. Matches
// Go's fixed 256 (runtime2.go: p.runq [256]guintptr).
RUNQ_SIZE :: 256

// Gobuf is a saved execution context: enough CPU register state to resume a
// goroutine where it left off. Mirrors Go's gobuf (runtime2.go:303).
//
// Field order is load-bearing: the context-switch assembly in asm_amd64.asm
// reads and writes these by byte offset. On x86_64 every field is 8 bytes:
//
//	sp   @ 0   stack pointer
//	pc   @ 8   program counter (resume address)
//	g    @ 16  the G this buf belongs to
//	ctxt @ 24  closure context register (unused for now)
//	lr   @ 32  link register (ARM64 only; kept for shape parity, unused on amd64)
//	bp   @ 40  frame base pointer
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
	// resumed (e.g. the completed sudog of a channel op). Mirrors g.param.
	param: rawptr,
}

// M is an OS thread of execution. Mirrors Go's m (runtime2.go:616), reduced
// to the fields the single-M scheduler needs.
//
// DEVIATION: Go's m also carries tls[] (the thread-local slot that makes
// getg() work) and a `park` note for blocking idle threads. bifrost is
// single-M through Phase 4 and tracks the current goroutine via the global
// current_g, so those fields arrive in Phase 5 (multi-M) instead.
M :: struct {
	// g0 is the scheduling goroutine: it owns a dedicated stack on which the
	// scheduler itself (schedule, gopark, etc.) runs, separate from any user
	// goroutine's stack.
	g0: ^G,
	// curg is the user goroutine this M is currently running, or nil.
	curg: ^G,
	// p is the P this M is bound to while running goroutine code, or nil.
	p: ^P,
	// nextp is the P to bind before the next execute (Phase 5 handoff).
	nextp: ^P,
	// id is a unique M id; m0 (the main thread) is 0.
	id: i64,
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
	// gfree is a cache of dead Gs (with stacks) available for reuse.
	gfree: G_List,
}

// Schedt is the global scheduler state shared by all Ms. Mirrors Go's schedt
// (runtime2.go:932), reduced subset.
Schedt :: struct {
	// goidgen is the monotonically increasing goroutine id counter, bumped
	// atomically by newg. Mirrors goidgen atomic.Uint64.
	goidgen: u64,
	// lock guards the global runq and idle lists.
	lock: sync.Mutex,
	// runq is the global run queue, a fallback/overflow for the per-P runqs.
	runq: G_Queue,
	// midle is the list of idle Ms waiting for work; npidle/nmidle count them.
	// Idle lists are exercised starting in Phase 5 (multi-M).
	midle:  ^M,
	nmidle: i32,
	// pidle is the list of idle Ps.
	pidle:  ^P,
	npidle: i32,
}

// Package-global runtime state. Mirrors Go's runtime globals (proc.go /
// runtime2.go): allgs, allm, allp, sched, gomaxprocs, m0, g0.
@(private)
allgs: [dynamic]^G

@(private)
allm: ^M

@(private)
allp: []^P

@(private)
sched: Schedt

@(private)
gomaxprocs: i32

// m0 is the M for the main OS thread; g0 is its scheduling goroutine.
@(private)
m0: M

@(private)
g0: G

// current_g is the goroutine currently executing on the (single) M.
//
// DEVIATION: Go resolves the current g from a thread-local slot inside the
// context-switch assembly (getg()). bifrost is single-M through Phase 4, so it
// tracks the running goroutine in this global, updated by the scheduler around
// each switch. Phase 5 replaces this with a real per-thread value.
@(private)
current_g: ^G

// runtime_init initializes the global scheduler state for `procs` logical
// processors and wires up m0/g0. It allocates allp and zeroes sched; it does
// NOT start any OS threads. Mirrors the allp/sched setup portion of Go's
// schedinit (proc.go:835) + procresize.
runtime_init :: proc(procs: i32, allocator := context.allocator) {
	assert(procs >= 1, "runtime_init: gomaxprocs must be >= 1")

	gomaxprocs = procs
	sched = {}

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
	current_g = &g0
}

// getg returns the goroutine currently executing on this M.
//
// DEVIATION: Go's getg() is a compiler intrinsic reading thread-local storage;
// bifrost returns the global current_g (single-M; see its doc comment).
getg :: proc "contextless" () -> ^G {
	return current_g
}
