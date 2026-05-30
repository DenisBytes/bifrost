package bifrost

import "base:intrinsics"
import "core:testing"
import "core:time"

// Phase 9 integration: many sleepers across 4 OS threads. Each is parked on a
// timer scheduled to its M's P; the scheduler fires them as their deadlines
// pass and goready's the goroutine. If checkdead's "pending timer = not dead"
// branch is wrong, this hangs and the test runner times out.

@(private = "file")
TI_N :: 100

@(private = "file")
ti_completed: i64

@(private = "file")
ti_sleep_worker :: proc(arg: rawptr) {
	time_sleep(20 * time.Millisecond)
	intrinsics.atomic_add(&ti_completed, 1)
}

@(test)
test_integration_time_sleep_many :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	ti_completed = 0
	for _ in 0 ..< TI_N {
		go_(ti_sleep_worker)
	}
	run()

	testing.expectf(t, ti_completed == TI_N, "completed = %d, want %d", ti_completed, TI_N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

// A mix of long and short sleeps: the short ones must complete first, proving
// the min-heap orders timers correctly across many concurrent sleepers. Flags
// are b32 read/written through intrinsics so the cross-thread ordering is
// well-defined (a plain bool here would be a data race even if it works in
// practice on x86_64).
@(private = "file")
ti_short_done_first: b32

@(private = "file")
ti_long_done: b32

@(private = "file")
ti_short_sleeper :: proc(arg: rawptr) {
	time_sleep(20 * time.Millisecond)
	// On a correct min-heap, all short sleepers finish well before the long one.
	if !intrinsics.atomic_load(&ti_long_done) {
		intrinsics.atomic_store(&ti_short_done_first, true)
	}
}

@(private = "file")
ti_long_sleeper :: proc(arg: rawptr) {
	time_sleep(200 * time.Millisecond)
	intrinsics.atomic_store(&ti_long_done, true)
}

@(test)
test_integration_time_sleep_ordering :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	intrinsics.atomic_store(&ti_short_done_first, false)
	intrinsics.atomic_store(&ti_long_done, false)
	go_(ti_long_sleeper) // started first but won't finish first
	for _ in 0 ..< 10 {
		go_(ti_short_sleeper)
	}
	run()

	testing.expect(t, bool(intrinsics.atomic_load(&ti_long_done)), "long sleeper did not complete")
	testing.expect(t, bool(intrinsics.atomic_load(&ti_short_done_first)), "short sleepers did not finish before the long one (heap ordering broken)")
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
