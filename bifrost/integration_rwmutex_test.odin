package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.5 integration: contend an RWMutex with a mix of readers and writers
// on 4 OS threads. If writer-exclusion were broken the protected counter would
// race; if reader concurrency were broken the test would still pass but be
// useless. Tracking max-concurrent-readers proves both.

@(private = "file")
RW_INT_WRITERS :: 200

@(private = "file")
RW_INT_READERS :: 2000

@(private = "file")
rw_int: RWMutex

@(private = "file")
rw_int_value: i64

@(private = "file")
rw_int_active_readers: i32

@(private = "file")
rw_int_max_concurrent_readers: i32

@(private = "file")
rw_int_writer :: proc(arg: rawptr) {
	rwmutex_lock(&rw_int)
	rw_int_value += 1 // non-atomic on purpose: write exclusion must hold
	rwmutex_unlock(&rw_int)
}

@(private = "file")
rw_int_reader :: proc(arg: rawptr) {
	rwmutex_rlock(&rw_int)
	cur := intrinsics.atomic_add(&rw_int_active_readers, 1) + 1
	// Track the peak — multi-M should produce > 1 most of the time.
	for {
		max := intrinsics.atomic_load(&rw_int_max_concurrent_readers)
		if cur <= max {
			break
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(&rw_int_max_concurrent_readers, max, cur); ok {
			break
		}
	}
	_ = intrinsics.atomic_load(&rw_int_value) // touch the shared state
	intrinsics.atomic_add(&rw_int_active_readers, -1)
	rwmutex_runlock(&rw_int)
}

@(test)
test_integration_rwmutex_mixed :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	rwmutex_init(&rw_int)

	rw_int_value = 0
	rw_int_active_readers = 0
	rw_int_max_concurrent_readers = 0
	for _ in 0 ..< RW_INT_WRITERS {
		go_(rw_int_writer)
	}
	for _ in 0 ..< RW_INT_READERS {
		go_(rw_int_reader)
	}
	run()

	// Writer exclusion proof: every writer's non-atomic +1 must have committed.
	testing.expectf(t, rw_int_value == RW_INT_WRITERS, "value = %d, want %d", rw_int_value, RW_INT_WRITERS)
	// Reader concurrency proof: at some point >1 reader held the lock together.
	testing.expectf(t, rw_int_max_concurrent_readers > 1, "max concurrent readers = %d, want > 1", rw_int_max_concurrent_readers)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
