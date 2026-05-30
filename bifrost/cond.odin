package bifrost

import "base:intrinsics"

// Phase 8.6: Cond — a condition variable associated with a Mutex. cond_wait
// atomically releases the mutex and parks; cond_signal wakes one waiter;
// cond_broadcast wakes every current waiter.
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
// inside wait and re-acquired before return. cond_signal / cond_broadcast may
// be called with or without the mutex held (typically with), but signal-then-
// wait races are tolerated only because the predicate check above filters them
// — a "missed" signal is harmless because the next predicate check sees the
// already-true state and the waiter skips the park.
//
// DEVIATIONS from sync.Cond: bifrost has no copy-protection (Go panics if the
// Cond is copied after first use) and no Wait timeouts. The contract above is
// the same.

Cond :: struct {
	sema:    u32,
	waiters: i32, // atomic; positive while goroutines are parked on sema
}

cond_init :: proc(c: ^Cond) {
	c.sema = 0
	c.waiters = 0
}

// cond_wait atomically releases m and parks until cond_signal / cond_broadcast
// wakes us, then re-acquires m. Caller MUST hold m on entry.
//
// The waiters++ MUST happen-before mutex_unlock(m), so a signaler that observes
// the mutex released also sees the incremented waiter count and will sema_post.
// Odin's default-seq-cst atomics + the mutex's release/acquire give us that
// ordering without an explicit fence.
cond_wait :: proc(c: ^Cond, m: ^Mutex) {
	intrinsics.atomic_add(&c.waiters, i32(1))
	mutex_unlock(m)
	sema_acquire(&c.sema)
	mutex_lock(m)
}

// cond_signal wakes one current waiter (if any). Best-effort: a signal issued
// while no waiter has reached the atomic_add is a no-op (the predicate idiom
// makes this safe).
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
// (capturing the count) and posts that many permits.
cond_broadcast :: proc(c: ^Cond) {
	n := intrinsics.atomic_exchange(&c.waiters, i32(0))
	for _ in 0 ..< n {
		sema_release(&c.sema)
	}
}
