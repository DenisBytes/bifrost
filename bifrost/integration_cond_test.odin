package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.6 integration: N workers wait on a Cond; one goroutine flips the
// predicate and broadcasts. Every worker must wake exactly once. Runs across
// 4 OS threads so the wait/unlock/sema_acquire ordering and the broadcast's
// "release sema N times" exercise cross-thread visibility.

@(private = "file")
COND_INT_N :: 1000

@(private = "file")
ci_c: Cond

@(private = "file")
ci_m: Mutex

@(private = "file")
ci_predicate: bool

@(private = "file")
ci_woke: i32

@(private = "file")
ci_waiter :: proc(arg: rawptr) {
	mutex_lock(&ci_m)
	for !ci_predicate {
		cond_wait(&ci_c, &ci_m)
	}
	mutex_unlock(&ci_m)
	intrinsics.atomic_add(&ci_woke, 1)
}

@(private = "file")
ci_broadcaster :: proc(arg: rawptr) {
	mutex_lock(&ci_m)
	ci_predicate = true
	cond_broadcast(&ci_c)
	mutex_unlock(&ci_m)
}

@(test)
test_integration_cond_broadcast_many :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	cond_init(&ci_c)
	mutex_init(&ci_m)

	ci_predicate = false
	ci_woke = 0
	for _ in 0 ..< COND_INT_N {
		go_(ci_waiter)
	}
	go_(ci_broadcaster)
	run()

	testing.expectf(t, ci_woke == COND_INT_N, "woke = %d, want %d", ci_woke, COND_INT_N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

// Producer-consumer with cond_signal: producers signal one consumer at a time.
@(private = "file")
PC_TOTAL :: 500

@(private = "file")
pc_c: Cond

@(private = "file")
pc_m: Mutex

@(private = "file")
pc_queue: int

@(private = "file")
pc_consumed: i64

@(private = "file")
pc_done_producers: i32

@(private = "file")
pc_producer :: proc(arg: rawptr) {
	mutex_lock(&pc_m)
	pc_queue += 1
	cond_signal(&pc_c)
	mutex_unlock(&pc_m)
}

@(private = "file")
pc_consumer :: proc(arg: rawptr) {
	mutex_lock(&pc_m)
	for pc_queue == 0 {
		cond_wait(&pc_c, &pc_m)
	}
	pc_queue -= 1
	mutex_unlock(&pc_m)
	intrinsics.atomic_add(&pc_consumed, 1)
}

@(test)
test_integration_cond_producer_consumer :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	cond_init(&pc_c)
	mutex_init(&pc_m)

	pc_queue = 0
	pc_consumed = 0
	pc_done_producers = 0
	for _ in 0 ..< PC_TOTAL {
		go_(pc_consumer) // many will park on the cond
	}
	for _ in 0 ..< PC_TOTAL {
		go_(pc_producer) // each enqueues one item and signals
	}
	run()

	testing.expectf(t, pc_consumed == PC_TOTAL, "consumed = %d, want %d", pc_consumed, PC_TOTAL)
	testing.expectf(t, pc_queue == 0, "queue = %d, want 0 (balanced)", pc_queue)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
