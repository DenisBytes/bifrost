package bifrost

import "core:testing"

// Phase 8.2 unit tests for Mutex. mutex_lock blocks until the holder calls
// mutex_unlock; built on sema. These drive the scheduler.

@(private = "file")
mtx: Mutex

@(private = "file")
mtx_counter: int

@(private = "file")
mtx_first_held: bool

@(private = "file")
mtx_second_observed_first: bool

@(private = "file")
mtx_simple_worker :: proc(arg: rawptr) {
	mutex_lock(&mtx)
	mtx_counter += 1
	mutex_unlock(&mtx)
}

@(test)
test_mutex_basic_lock_unlock :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	mutex_init(&mtx)

	mtx_counter = 0
	go_(mtx_simple_worker)
	run()

	testing.expectf(t, mtx_counter == 1, "counter = %d, want 1", mtx_counter)
}

// One goroutine locks, yields with the lock held, unlocks; a second goroutine
// blocks on the lock during the yield and must observe the first goroutine's
// state change before its own critical section runs.
@(private = "file")
mtx_first_holder :: proc(arg: rawptr) {
	mutex_lock(&mtx)
	mtx_first_held = true
	gosched() // yield while holding the lock
	mutex_unlock(&mtx)
}

@(private = "file")
mtx_second_waiter :: proc(arg: rawptr) {
	mutex_lock(&mtx)
	mtx_second_observed_first = mtx_first_held
	mutex_unlock(&mtx)
}

@(test)
test_mutex_blocks_until_released :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	mutex_init(&mtx)

	mtx_first_held = false
	mtx_second_observed_first = false
	go_(mtx_first_holder) // runs first, locks, yields with lock held
	go_(mtx_second_waiter) // tries to lock, parks until first releases
	run()

	testing.expect(t, mtx_first_held, "first holder did not run")
	testing.expect(t, mtx_second_observed_first, "second waiter ran before first released the lock")
}

// Many serialized lock/unlock cycles on a single goroutine: the counter must be
// the exact loop count (covers init, repeated acquire/release on uncontended
// fast path).
@(private = "file")
mtx_loop_worker :: proc(arg: rawptr) {
	for _ in 0 ..< 100 {
		mutex_lock(&mtx)
		mtx_counter += 1
		mutex_unlock(&mtx)
	}
}

@(test)
test_mutex_uncontended_loop :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	mutex_init(&mtx)

	mtx_counter = 0
	go_(mtx_loop_worker)
	run()

	testing.expectf(t, mtx_counter == 100, "counter = %d, want 100", mtx_counter)
}
