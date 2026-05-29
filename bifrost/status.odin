package bifrost

import "base:intrinsics"
import "core:fmt"

// G_Status is the lifecycle state of a goroutine, stored in G.atomicstatus.
//
// The integer values match Go's _Gidle/_Grunnable/... constants
// (runtime2.go:35-77) so the state machine reads identically against the Go
// source. The values are intentionally non-contiguous: Go reserves 3 for
// _Gsyscall and 5 for the unused _Gmoribund slot, which bifrost does not use
// yet. Backed by u32 to match Go's atomic.Uint32 and to allow atomic CAS.
G_Status :: enum u32 {
	Idle     = 0, // _Grunnable just allocated, not yet initialized.
	Runnable = 1, // _Grunnable on a run queue, not executing.
	Running  = 2, // _Grunning executing user code; owns its stack.
	Waiting  = 4, // _Gwaiting blocked in the runtime (3 == _Gsyscall, later).
	Dead     = 6, // _Gdead unused; on a gFree list (5 == unused moribund slot).
}

// P_Status is the state of a logical processor, stored in P.status. Values
// match Go's _Pidle/_Prunning/... (runtime2.go:122-).
P_Status :: enum u32 {
	Idle    = 0, // _Pidle not running user code or the scheduler.
	Running = 1, // _Prunning owned by an M, running user code.
	Syscall = 2, // _Psyscall not running, M is in a syscall.
	Gcstop  = 3, // _Pgcstop halted for the world stop.
	Dead    = 4, // _Pdead no longer used (gomaxprocs shrank).
}

// Wait_Reason explains why a goroutine is _Gwaiting; stored in G.waitreason
// and surfaced in deadlock dumps. Go keeps a large waitReason table
// (runtime2.go); bifrost grows this enum as parking sites are added, so for
// now it carries only the reasons used through Phase 6.3.
Wait_Reason :: enum {
	None             = 0, // not waiting / reason unset.
	Chan_Send,            // blocked sending on a channel (waitReasonChanSend).
	Chan_Receive,         // blocked receiving on a channel (waitReasonChanReceive).
	Chan_Send_Nil,        // send on a nil channel: blocks forever (waitReasonChanSendNilChan).
	Chan_Receive_Nil,     // receive on a nil channel: blocks forever (waitReasonChanReceiveNilChan).
}

// casgstatus atomically transitions gp.atomicstatus from old to new.
//
// Go's casgstatus (proc.go) spins to tolerate the GC's _Gscan bit and throws on
// impossible transitions. bifrost has no GC and no _Gscan bit, so there is no
// transient bit to spin past: a status transition is owned by exactly one M at a
// time (the M running the g, or the M that dequeued it). A failed CAS therefore
// means a real logic or run-queue-invariant violation — e.g. two Ms dequeued the
// same g — so we panic (fail fast), mirroring Go's throw rather than spinning.
casgstatus :: proc(gp: ^G, old, new: G_Status) {
	if old == new {
		fmt.panicf("casgstatus: old == new (%v)", old)
	}
	_, ok := intrinsics.atomic_compare_exchange_strong(&gp.atomicstatus, old, new)
	if !ok {
		have := intrinsics.atomic_load(&gp.atomicstatus)
		fmt.panicf("casgstatus: bad transition %v -> %v (have %v)", old, new, have)
	}
}

// g_status atomically loads gp.atomicstatus. Mirrors `readgstatus`
// (proc.go).
g_status :: proc(gp: ^G) -> G_Status {
	return intrinsics.atomic_load(&gp.atomicstatus)
}
