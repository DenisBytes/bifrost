package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.2 integration: contend a single Mutex across 4 OS threads. If the
// mutex were broken (or if the underlying sema lost a wakeup), the count would
// drift below N or the test would hang (caught by checkdead).

@(private = "file")
MTX_INT_N :: 5000

@(private = "file")
mtx_int: Mutex

@(private = "file")
mtx_int_counter: i64

@(private = "file")
mtx_int_worker :: proc(arg: rawptr) {
	mutex_lock(&mtx_int)
	// Non-atomic increment is fine HERE precisely because the mutex guarantees
	// exclusion; if anything is wrong with the mutex, this races and the final
	// total comes out short.
	mtx_int_counter += 1
	mutex_unlock(&mtx_int)
}

@(test)
test_integration_mutex_contention :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	mutex_init(&mtx_int)

	mtx_int_counter = 0
	for _ in 0 ..< MTX_INT_N {
		go_(mtx_int_worker)
	}
	run()

	testing.expectf(t, mtx_int_counter == MTX_INT_N, "count = %d, want %d", mtx_int_counter, MTX_INT_N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

// Two Mutexes, two pools of workers, each protecting its own counter — verifies
// no cross-contamination through the sema_table hash buckets.
@(private = "file")
mtx_a: Mutex

@(private = "file")
mtx_b: Mutex

@(private = "file")
mtx_a_count: i64

@(private = "file")
mtx_b_count: i64

@(private = "file")
mtx_a_worker :: proc(arg: rawptr) {
	mutex_lock(&mtx_a)
	mtx_a_count += 1
	mutex_unlock(&mtx_a)
}

@(private = "file")
mtx_b_worker :: proc(arg: rawptr) {
	mutex_lock(&mtx_b)
	mtx_b_count += 1
	mutex_unlock(&mtx_b)
}

@(test)
test_integration_two_mutexes :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	mutex_init(&mtx_a)
	mutex_init(&mtx_b)

	mtx_a_count = 0
	mtx_b_count = 0
	N :: 2000
	for _ in 0 ..< N {
		go_(mtx_a_worker)
		go_(mtx_b_worker)
	}
	run()

	// Workers leave the count visible via the mutex's release ordering, but a
	// final atomic load is the cleanest read since the test thread is uninvolved.
	testing.expectf(t, intrinsics.atomic_load(&mtx_a_count) == N, "a = %d, want %d", mtx_a_count, N)
	testing.expectf(t, intrinsics.atomic_load(&mtx_b_count) == N, "b = %d, want %d", mtx_b_count, N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
