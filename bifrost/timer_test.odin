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

@(test)
test_timer_deadline_saturates :: proc(t: ^testing.T) {
	// A near-max Duration overflowed i64 and produced a deadline in the PAST, so
	// the timer fired immediately instead of sleeping. timer_deadline saturates.
	now := mono_now_ns()
	d := timer_deadline(max(time.Duration))
	testing.expectf(t, d > now, "deadline %d must be in the future, not wrapped past now=%d", d, now)
	testing.expectf(t, d == max(i64), "deadline = %d, want max(i64) on saturation", d)

	// Ordinary durations must be unaffected.
	short := timer_deadline(time.Millisecond)
	testing.expectf(t, short > now, "1ms deadline %d must exceed now=%d", short, now)
	testing.expect(t, short < max(i64), "1ms deadline must not saturate")
}

@(test)
test_timer_ntimers_tracks_heap_length :: proc(t: ^testing.T) {
	// timer_run_expired early-outs on this counter without taking timers_lock or
	// reading the clock, so it must never disagree with len(pp.timers).
	runtime_init(1)
	defer runtime_teardown()
	pp := allp[0]
	testing.expectf(t, pp.ntimers == 0, "fresh P: ntimers = %d, want 0", pp.ntimers)

	far := mono_now_ns() + i64(time.Hour)
	for i in 0 ..< 5 {
		timer_push(pp, Timer{deadline = far + i64(i), f = time_sleep_wake, arg = nil})
		testing.expectf(
			t,
			int(pp.ntimers) == len(pp.timers),
			"after push %d: ntimers = %d, len = %d",
			i,
			pp.ntimers,
			len(pp.timers),
		)
	}
	testing.expectf(t, pp.ntimers == 5, "ntimers = %d, want 5", pp.ntimers)

	// Nothing is due, so this must early-out and leave the heap intact.
	timer_run_expired(pp)
	testing.expectf(t, pp.ntimers == 5, "ntimers = %d after a no-op sweep, want 5", pp.ntimers)

	// Drop them so teardown's leak diagnostic stays quiet.
	clear(&pp.timers)
	intrinsics.atomic_store(&pp.ntimers, i32(0))
}
