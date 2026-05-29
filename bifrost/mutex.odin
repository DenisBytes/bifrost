package bifrost

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
// shows it.

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
mutex_lock :: proc(m: ^Mutex) {
	sema_acquire(&m.sema)
}

// mutex_unlock releases the lock, waking one waiter if any. Behavior is
// undefined if m is not held by the caller — same contract as
// sync.Mutex.Unlock (Go panics on this misuse; bifrost relies on sema's
// counting semantics, so a double-unlock would silently allow two holders).
mutex_unlock :: proc(m: ^Mutex) {
	sema_release(&m.sema)
}
