package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.4 integration: hammer one Once from 4 OS threads. If the slow-path
// mutex/done-flag interplay is wrong, the run counter would exceed 1.

@(private = "file")
ONCE_INT_N :: 2000

@(private = "file")
o_int: Once

@(private = "file")
once_int_run_count: i32

@(private = "file")
once_int_observed_zero: i32

@(private = "file")
once_int_value: i32

@(private = "file")
once_int_init_fn :: proc() {
	// Intentionally observable: a second invocation would either set it again
	// (still 42 — invisible) OR a partial racing init would observe pre-init
	// state. once_int_run_count is the real verdict.
	once_int_value = 42
	intrinsics.atomic_add(&once_int_run_count, 1)
}

@(private = "file")
once_int_worker :: proc(arg: rawptr) {
	once_do(&o_int, once_int_init_fn)
	// Every caller, winner or skipper, must observe the fully-initialized value.
	if intrinsics.atomic_load(&once_int_value) != 42 {
		intrinsics.atomic_add(&once_int_observed_zero, 1)
	}
}

@(test)
test_integration_once_contention :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	once_init(&o_int)

	once_int_run_count = 0
	once_int_observed_zero = 0
	once_int_value = 0
	for _ in 0 ..< ONCE_INT_N {
		go_(once_int_worker)
	}
	run()

	testing.expectf(t, once_int_run_count == 1, "fn ran %d times, want 1", once_int_run_count)
	testing.expectf(t, once_int_observed_zero == 0, "%d workers saw the pre-init value (race in once_do)", once_int_observed_zero)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
