package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.6 unit tests for Cond. cond_wait atomically releases its associated
// Mutex and parks; cond_signal wakes one waiter; cond_broadcast wakes all.
// Tests use the canonical predicate idiom (`while !predicate { wait }`) so
// they're robust to spurious wakeups and to signal-before-wait races.

@(private = "file")
c: Cond

@(private = "file")
cm: Mutex

@(private = "file")
cond_predicate: bool

@(private = "file")
cond_woke: i32

@(private = "file")
cond_waiter :: proc(arg: rawptr) {
	mutex_lock(&cm)
	for !cond_predicate {
		cond_wait(&c, &cm)
	}
	intrinsics.atomic_add(&cond_woke, 1)
	mutex_unlock(&cm)
}

@(private = "file")
cond_signaler :: proc(arg: rawptr) {
	mutex_lock(&cm)
	cond_predicate = true
	cond_signal(&c)
	mutex_unlock(&cm)
}

@(test)
test_cond_signal_wakes_one_waiter :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = false
	cond_woke = 0
	go_(cond_waiter) // parks on cond
	go_(cond_signaler) // sets predicate, signals
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 1, "woke = %d, want 1", cond_woke)
}

// A single broadcast wakes EVERY parked waiter.
@(private = "file")
cond_broadcaster :: proc(arg: rawptr) {
	mutex_lock(&cm)
	cond_predicate = true
	cond_broadcast(&c)
	mutex_unlock(&cm)
}

@(test)
test_cond_broadcast_wakes_all :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = false
	cond_woke = 0
	for _ in 0 ..< 5 {
		go_(cond_waiter) // five parked waiters
	}
	go_(cond_broadcaster) // one broadcast wakes them all
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 5, "woke = %d, want 5", cond_woke)
}

// If the predicate is already true at wait time, the waiter returns without
// parking — proves the while-predicate idiom is safe even when the signal
// "preceded" the wait.
@(private = "file")
cond_waiter_predicate_true :: proc(arg: rawptr) {
	mutex_lock(&cm)
	for !cond_predicate {
		cond_wait(&c, &cm)
	}
	intrinsics.atomic_add(&cond_woke, 1)
	mutex_unlock(&cm)
}

@(test)
test_cond_wait_skips_when_predicate_already_true :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = true // already true: waiter must NOT park
	cond_woke = 0
	go_(cond_waiter_predicate_true)
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 1, "woke = %d, want 1 (no signaler needed)", cond_woke)
}
