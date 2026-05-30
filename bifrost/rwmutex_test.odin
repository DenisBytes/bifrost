package bifrost

import "core:testing"

// Phase 8.5 unit tests for RWMutex. Mutual exclusion under contention is the
// interesting behavior, but those interleavings need multi-M and live in the
// integration tests; here we just confirm the single-goroutine state-machine
// is sane.

@(private = "file")
rw: RWMutex

@(private = "file")
rw_counter: int

// One goroutine takes the read lock, does work, releases.
@(private = "file")
rw_reader_worker :: proc(arg: rawptr) {
	rwmutex_rlock(&rw)
	rw_counter += 1
	rwmutex_runlock(&rw)
}

@(test)
test_rwmutex_basic_rlock_runlock :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	rwmutex_init(&rw)

	rw_counter = 0
	go_(rw_reader_worker)
	run()

	testing.expectf(t, rw_counter == 1, "counter = %d, want 1", rw_counter)
}

// Same with the write lock.
@(private = "file")
rw_writer_worker :: proc(arg: rawptr) {
	rwmutex_lock(&rw)
	rw_counter += 1
	rwmutex_unlock(&rw)
}

@(test)
test_rwmutex_basic_lock_unlock :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	rwmutex_init(&rw)

	rw_counter = 0
	go_(rw_writer_worker)
	run()

	testing.expectf(t, rw_counter == 1, "counter = %d, want 1", rw_counter)
}

// Two readers concurrently (on one M): both must acquire the read lock without
// either blocking the other. Each yields with the read lock held, proving they
// hold it at the same time.
@(private = "file")
rw_both_held: bool

@(private = "file")
rw_reader_a :: proc(arg: rawptr) {
	rwmutex_rlock(&rw)
	rw_counter += 1 // mark A is in
	gosched()
	// If B also incremented while we were yielded, both held the lock together.
	if rw_counter == 2 {
		rw_both_held = true
	}
	rwmutex_runlock(&rw)
}

@(private = "file")
rw_reader_b :: proc(arg: rawptr) {
	rwmutex_rlock(&rw) // must NOT block on A's RLock
	rw_counter += 1
	rwmutex_runlock(&rw)
}

@(test)
test_rwmutex_multiple_readers_concurrent :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	rwmutex_init(&rw)

	rw_counter = 0
	rw_both_held = false
	go_(rw_reader_a) // RLocks, yields with lock held
	go_(rw_reader_b) // must RLock (not block), increment, then release
	run()

	testing.expect(t, rw_both_held, "two RLocks did not overlap (writer-exclusion semantics wrong)")
}
