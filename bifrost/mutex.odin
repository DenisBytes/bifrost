package bifrost

import "base:intrinsics"

// Phase 8.2: Mutex on top of the runtime semaphore. mutex_lock blocks until the
// holder calls mutex_unlock; the uncontended path is one cansemacquire CAS on
// lock and one xadd on unlock.
//
// DEVIATION from Go's sync.Mutex: Go's is zero-value-usable (state=0 means
// unlocked) by encoding the lock bit + waiter count in a single u32 and using
// a fast-path CAS with a slow-path sema; bifrost's Mutex is the simple binary
// semaphore wrapper and must be initialized via mutex_init before use. No
// spinning, no starvation mode, no anti-fairness regime — fairness follows the
// sema's FIFO. Adequate for the sync API surface; tune later if measurement
// shows it. CONTRACT: mutex_init must run before any lock/unlock and must NOT
// be called on a held or already-initialized Mutex — there is no extra flag to
// distinguish "uninitialized 0" from "held 0", so re-init on a held Mutex is
// silent UB.

// Mutex is a binary semaphore: the embedded counter is 1 when the lock is free
// and 0 when held. Initialize with mutex_init before any lock/unlock.
Mutex :: struct {
	sema: u32,
}

// mutex_init prepares m for use: one permit available, lock is free.
mutex_init :: proc(m: ^Mutex) {
	m.sema = 1
}

// mutex_lock acquires the lock, blocking until it is available.
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
mutex_lock :: proc(m: ^Mutex) {
	sema_acquire(&m.sema)
}

// mutex_unlock releases the lock, waking one waiter if any. Panics on
// double-unlock or unlock-of-never-locked: only the holder calls unlock, so the
// sema must be 0 on entry. Mirrors sync.Mutex.Unlock (mutex.go:223), which
// throws "sync: unlock of unlocked mutex" for the same misuse.
mutex_unlock :: proc(m: ^Mutex) {
	if intrinsics.atomic_load(&m.sema) != 0 {
		panic("mutex_unlock: mutex is not held (double-unlock or never locked)")
	}
	sema_release(&m.sema)
}
