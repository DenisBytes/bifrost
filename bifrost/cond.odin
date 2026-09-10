package bifrost

import "base:intrinsics"

// Phase 8.6: Cond — a condition variable associated with a Mutex. cond_wait
// atomically releases the mutex and parks; cond_signal wakes one waiter;
// cond_broadcast wakes every current waiter. Mirrors sync.Cond (src/sync/cond.go).
//
// USAGE CONTRACT (the predicate idiom, identical to sync.Cond):
//   m.lock()
//   for !predicate {
//       cond_wait(c, m)
//   }
//   ... act on the predicate ...
//   m.unlock()
//
// The caller MUST hold the mutex when calling cond_wait; the mutex is released
// inside wait and re-acquired before return. The PREDICATE must always be
// mutated while holding the same mutex used by waiters — that is what closes
// the signal-before-wait race: a late waiter that arrives after the predicate
// flip will see the new value during its under-mutex check and skip the park.
//
// cond_signal / cond_broadcast may be called with or without the mutex held;
// the safety hinges on the *predicate* update being under the mutex, not on
// the call site of the signal. When signal is called without the mutex,
// predicate visibility to the woken waiter relies on the seq-cst nature of
// bifrost's atomic ops + the sema_release / sema_acquire release-acquire pair
// (the current implementation). Relaxing those would break signal-without-mutex.
//
// DEVIATIONS from sync.Cond:
//   - Wake ordering is NOT strict FIFO. Go's sync.Cond is built on the runtime's
//     notifyList (runtime/sema.go:544), which hands out tickets so the oldest
//     waiter wakes first. bifrost's Cond uses a counting u32 sema; a newcomer
//     to sema_acquire can race past a parked older waiter and consume the
//     permit. Functionally correct under the predicate idiom (the older waiter
//     is woken by the next signal/broadcast), but unfair. Replacing this with
//     a tickets queue is a follow-up.
//   - No copy-protection (Go panics if Cond is copied after first use) and no
//     Wait timeouts. The usage contract above is the same as Go's.

Cond :: struct {
	sema:    u32,
	waiters: i32, // atomic; positive while goroutines are parked on sema
}

cond_init :: proc(c: ^Cond) {
	c.sema = 0
	c.waiters = 0
}

// cond_wait atomically releases m and parks until cond_signal / cond_broadcast
// wakes us, then re-acquires m. Caller MUST hold m on entry. Mirrors (*Cond).Wait
// (cond.go:67).
//
// The waiters++ MUST happen-before mutex_unlock(m), so a signaler that observes
// the mutex released also sees the incremented waiter count and will sema_post.
// Odin's default-seq-cst atomics + the mutex's release/acquire give us that
// ordering without an explicit fence.
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
cond_wait :: proc(c: ^Cond, m: ^Mutex) {
	intrinsics.atomic_add(&c.waiters, i32(1))
	mutex_unlock(m)
	sema_acquire(&c.sema)
	mutex_lock(m)
}

// cond_signal wakes one current waiter (if any). Best-effort: a signal issued
// while no waiter has reached the atomic_add is a no-op (the predicate idiom
// makes this safe). Mirrors (*Cond).Signal (cond.go:82).
cond_signal :: proc(c: ^Cond) {
	for {
		w := intrinsics.atomic_load(&c.waiters)
		if w == 0 {
			return
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(&c.waiters, w, w - 1); ok {
			sema_release(&c.sema)
			return
		}
		// CAS lost: a concurrent signal/broadcast updated waiters; retry.
	}
}

// cond_broadcast wakes every current waiter. Atomically swaps waiters to 0
// (capturing the count) and posts that many permits. Mirrors (*Cond).Broadcast
// (cond.go:93).
cond_broadcast :: proc(c: ^Cond) {
	n := intrinsics.atomic_exchange(&c.waiters, i32(0))
	for _ in 0 ..< n {
		sema_release(&c.sema)
	}
}
