package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.4 unit tests for Once: once_do(o, fn) runs fn exactly once regardless
// of how many callers invoke it.

@(private = "file")
o: Once

@(private = "file")
once_run_count: i32

@(private = "file")
once_visible: bool

@(private = "file")
incr_once_run_count :: proc() {
	intrinsics.atomic_add(&once_run_count, 1)
	once_visible = true
}

@(private = "file")
once_worker :: proc(arg: rawptr) {
	once_do(&o, incr_once_run_count)
}

// Three callers, one execution.
@(test)
test_once_runs_exactly_once :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	once_init(&o)

	once_run_count = 0
	once_visible = false
	go_(once_worker)
	go_(once_worker)
	go_(once_worker)
	run()

	testing.expectf(t, intrinsics.atomic_load(&once_run_count) == 1, "ran %d times, want 1", once_run_count)
	testing.expect(t, once_visible, "fn's side effect must be visible after once_do returns")
}

// A second once_do on the same Once after the first completed must NOT re-run
// fn.
@(private = "file")
once_serial_worker :: proc(arg: rawptr) {
	once_do(&o, incr_once_run_count) // first call: runs
	once_do(&o, incr_once_run_count) // second call: skips
}

@(test)
test_once_repeated_calls_are_noops :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	once_init(&o)

	once_run_count = 0
	go_(once_serial_worker)
	run()

	testing.expectf(t, intrinsics.atomic_load(&once_run_count) == 1, "ran %d times, want 1", once_run_count)
}

// once_do returns only after fn has finished, so every caller — including those
// that did not run fn — must observe fn's side effect.
@(private = "file")
once_init_value: int

@(private = "file")
once_observed: [3]int

@(private = "file")
set_init_value :: proc() {
	once_init_value = 42
}

@(private = "file")
once_observer :: proc(arg: rawptr) {
	idx := int(uintptr(arg))
	once_do(&o, set_init_value) // first caller runs fn; the others wait/skip
	once_observed[idx] = once_init_value
}

@(test)
test_once_observers_see_side_effect :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	once_init(&o)

	once_init_value = 0
	once_observed = {}
	for i in 0 ..< 3 {
		go_(once_observer, rawptr(uintptr(i)))
	}
	run()

	for v, i in once_observed {
		testing.expectf(t, v == 42, "observer %d saw %d, want 42", i, v)
	}
}
