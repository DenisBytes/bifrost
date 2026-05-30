package bifrost

import "base:intrinsics"
import "core:testing"
import "core:time"

// Phase 9 unit tests for time_sleep. The hard part is that the scheduler must
// poll its timer heap while idle and fire the callback that wakes the sleeping
// goroutine; if anything is wrong the goroutine never wakes and the test
// deadlocks (caught by checkdead).

@(private = "file")
ts_done: bool

@(private = "file")
ts_completed_count: i32

@(private = "file")
ts_worker_50ms :: proc(arg: rawptr) {
	time_sleep(50 * time.Millisecond)
	ts_done = true
}

@(test)
test_time_sleep_basic :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	ts_done = false
	go_(ts_worker_50ms)
	run()

	testing.expect(t, ts_done, "sleeping goroutine did not resume after time_sleep")
}

// The sleep MUST take at least the requested duration. The contract is
// "blocks for ≥ d", so the floor is the requested duration — slack would mask
// a regression that returned early.
@(test)
test_time_sleep_observes_duration :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	ts_done = false
	start := time.tick_now()
	go_(ts_worker_50ms)
	run()
	elapsed := time.tick_since(start)

	testing.expectf(t, elapsed >= 50 * time.Millisecond, "elapsed = %v, want >= 50ms", elapsed)
}

// Many sleepers all complete: tests the per-P heap with multiple entries.
@(private = "file")
ts_worker_short :: proc(arg: rawptr) {
	time_sleep(20 * time.Millisecond)
	intrinsics.atomic_add(&ts_completed_count, 1)
}

@(test)
test_time_sleep_multiple_short_sleepers :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	ts_completed_count = 0
	for _ in 0 ..< 10 {
		go_(ts_worker_short)
	}
	run()

	testing.expectf(t, intrinsics.atomic_load(&ts_completed_count) == 10, "completed = %d, want 10", ts_completed_count)
}
