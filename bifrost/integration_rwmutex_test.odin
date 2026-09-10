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

// rw_int_writer_active is set for the duration of every writer's critical
// section. Readers assert it is clear and the writer asserts no reader is
// present, which is the READER/WRITER exclusion property — distinct from the
// writer/writer exclusion the non-atomic counter already proves. Without these,
// an RWMutex that let a writer run alongside readers would still produce the
// right counter and ship green.
@(private = "file")
rw_int_writer_active: i32

@(private = "file")
rw_int_violations: i32

@(private = "file")
rw_int_writer :: proc(arg: rawptr) {
	rwmutex_lock(&rw_int)
	if intrinsics.atomic_add(&rw_int_writer_active, 1) + 1 != 1 {
		intrinsics.atomic_add(&rw_int_violations, 1) // another writer is inside
	}
	if intrinsics.atomic_load(&rw_int_active_readers) != 0 {
		intrinsics.atomic_add(&rw_int_violations, 1) // a reader is inside
	}
	rw_int_value += 1 // non-atomic on purpose: write exclusion must hold
	// Yield under the write lock so any reader that wrongly got in has a real
	// chance to observe rw_int_writer_active and record the violation.
	for _ in 0 ..< 2 {
		gosched()
	}
	if intrinsics.atomic_load(&rw_int_active_readers) != 0 {
		intrinsics.atomic_add(&rw_int_violations, 1)
	}
	intrinsics.atomic_add(&rw_int_writer_active, -1)
	rwmutex_unlock(&rw_int)
}

@(private = "file")
rw_int_reader :: proc(arg: rawptr) {
	rwmutex_rlock(&rw_int)
	if intrinsics.atomic_load(&rw_int_writer_active) != 0 {
		intrinsics.atomic_add(&rw_int_violations, 1) // a writer holds the lock
	}
	cur := intrinsics.atomic_add(&rw_int_active_readers, 1) + 1
	// Track the peak — without forcing a yield, the scheduler can sometimes
	// serialize readers and produce max=1, which proves nothing.
	for {
		max := intrinsics.atomic_load(&rw_int_max_concurrent_readers)
		if cur <= max {
			break
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(&rw_int_max_concurrent_readers, max, cur); ok {
			break
		}
	}
	// Yield while holding the read lock so a peer reader has a real chance to
	// enter the critical section concurrently. The peer must not block —
	// that's exactly the reader-concurrency property under test.
	for _ in 0 ..< 4 {
		gosched()
	}
	_ = intrinsics.atomic_load(&rw_int_value) // touch the shared state
	if intrinsics.atomic_load(&rw_int_writer_active) != 0 {
		intrinsics.atomic_add(&rw_int_violations, 1)
	}
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
	rw_int_writer_active = 0
	rw_int_violations = 0
	for _ in 0 ..< RW_INT_WRITERS {
		go_(rw_int_writer)
	}
	for _ in 0 ..< RW_INT_READERS {
		go_(rw_int_reader)
	}
	run()

	// Writer exclusion proof: every writer's non-atomic +1 must have committed.
	testing.expectf(t, rw_int_value == RW_INT_WRITERS, "value = %d, want %d", rw_int_value, RW_INT_WRITERS)
	// Reader/writer exclusion proof: no reader ever observed a writer inside, and
	// no writer ever observed a reader or another writer inside.
	testing.expectf(
		t,
		rw_int_violations == 0,
		"%d reader/writer exclusion violations: a writer ran concurrently with a reader",
		rw_int_violations,
	)
	// Reader concurrency proof: at some point >1 reader held the lock together.
	testing.expectf(t, rw_int_max_concurrent_readers > 1, "max concurrent readers = %d, want > 1", rw_int_max_concurrent_readers)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
