package bifrost

import "base:intrinsics"

// Phase 8.5: RWMutex. Many readers OR one writer, the canonical readers-writer
// lock. Faithful port of sync.RWMutex (src/sync/rwmutex.go) using two semas and
// a write-side Mutex.
//
// Key invariant: reader_count is the number of active readers when no writer is
// pending, OR it has been atomically decremented by RW_MAX_READERS when a
// writer is pending. So a negative reader_count immediately tells an arriving
// reader "a writer is in flight, park on reader_sem". Departing readers in the
// writer-pending state count down reader_wait; the last one wakes the writer
// on writer_sem.
//
// DEVIATION from sync.RWMutex: bifrost has no -race or reentrant-RLock
// detection. Caller contracts (one RUnlock per RLock; no recursive RLock from
// the same goroutine while a writer is queued) match Go's documentation.

@(private)
RW_MAX_READERS :: i32(1 << 30)

RWMutex :: struct {
	// w excludes other writers; a writer holds w for the duration of Lock/Unlock.
	w: Mutex,
	// reader_sem: pending readers park here while a writer holds the lock.
	reader_sem: u32,
	// writer_sem: the writer parks here until reader_wait reaches 0.
	writer_sem: u32,
	// reader_count: active readers (negative when a writer is pending — readers
	// arriving in that state park).
	reader_count: i32,
	// reader_wait: number of departing readers the writer is still waiting for.
	reader_wait: i32,
}

rwmutex_init :: proc(rw: ^RWMutex) {
	mutex_init(&rw.w)
	rw.reader_sem = 0
	rw.writer_sem = 0
	rw.reader_count = 0
	rw.reader_wait = 0
}

// rwmutex_rlock acquires a read lock. Multiple readers may hold the lock
// simultaneously; if a writer holds (or is queued for) the lock the call
// blocks until the writer releases. Mirrors (*RWMutex).RLock (rwmutex.go:67).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
rwmutex_rlock :: proc(rw: ^RWMutex) {
	// intrinsics.atomic_add returns OLD; new = old + 1. New < 0 (writer pending).
	if intrinsics.atomic_add(&rw.reader_count, i32(1)) + 1 < 0 {
		sema_acquire(&rw.reader_sem)
	}
}

// rwmutex_runlock releases one reader hold. Mirrors (*RWMutex).RUnlock
// (rwmutex.go:114).
rwmutex_runlock :: proc(rw: ^RWMutex) {
	if r := intrinsics.atomic_add(&rw.reader_count, i32(-1)) - 1; r < 0 {
		rwmutex_runlock_slow(rw, r)
	}
}

// Slow path: a writer is pending. Detect double-RUnlock, then decrement
// reader_wait; the last departing reader wakes the writer. Mirrors
// (*RWMutex).rUnlockSlow (rwmutex.go:129).
@(private)
rwmutex_runlock_slow :: proc(rw: ^RWMutex, r: i32) {
	// r is the NEW reader_count after our -1. r + 1 == 0 means readers count
	// went from 0 to -1 (we RUnlocked when we never held it); the other branch
	// catches "writer is queued and we are an extra RUnlock past the cohort".
	if r + 1 == 0 || r + 1 == -RW_MAX_READERS {
		panic("rwmutex_runlock: RUnlock of unlocked RWMutex")
	}
	// atomic_add returns OLD; new = old - 1. New == 0 means we were the last
	// pending departing reader the writer is waiting for.
	if intrinsics.atomic_add(&rw.reader_wait, i32(-1)) - 1 == 0 {
		sema_release(&rw.writer_sem)
	}
}

// rwmutex_lock acquires the write lock, blocking until all readers have left
// and any other writer has released. Mirrors (*RWMutex).Lock (rwmutex.go:144).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
rwmutex_lock :: proc(rw: ^RWMutex) {
	// Exclude other writers first.
	mutex_lock(&rw.w)
	// Signal pending writer to readers by negating reader_count: readers seeing
	// reader_count < 0 will park on reader_sem in rlock.
	// atomic_add returns OLD; that IS the current reader count (= number of
	// readers we must wait for).
	r := intrinsics.atomic_add(&rw.reader_count, -RW_MAX_READERS)
	if r != 0 && intrinsics.atomic_add(&rw.reader_wait, r) + r != 0 {
		sema_acquire(&rw.writer_sem)
	}
}

// rwmutex_unlock releases the write lock and wakes any pending readers.
// Mirrors (*RWMutex).Unlock (rwmutex.go:201).
rwmutex_unlock :: proc(rw: ^RWMutex) {
	// Restore reader_count to non-negative.
	r := intrinsics.atomic_add(&rw.reader_count, RW_MAX_READERS) + RW_MAX_READERS
	if r >= RW_MAX_READERS {
		panic("rwmutex_unlock: Unlock of unlocked RWMutex")
	}
	// Wake any pending readers that arrived while we held the lock.
	for _ in 0 ..< r {
		sema_release(&rw.reader_sem)
	}
	// Allow the next writer.
	mutex_unlock(&rw.w)
}
