package bifrost

import "core:testing"

// Phase 8.3 unit tests for WaitGroup. waitgroup_add increments a counter,
// waitgroup_done decrements it, waitgroup_wait blocks until the counter hits 0.

@(private = "file")
wg: WaitGroup

@(private = "file")
wg_count: int

@(private = "file")
wg_woke: bool

@(private = "file")
wg_workers_woke: int

// A waiter on a zero-counter WaitGroup must return immediately, with no parking.
@(private = "file")
wg_zero_waiter :: proc(arg: rawptr) {
	waitgroup_wait(&wg)
	wg_woke = true
}

@(test)
test_waitgroup_wait_on_zero :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	wg = {}

	wg_woke = false
	go_(wg_zero_waiter)
	run()

	testing.expect(t, wg_woke, "wait on counter==0 should return immediately")
}

// Classic Add(N) / N×Done / one Wait. The waiter only completes after every
// worker has called Done.
@(private = "file")
wg_worker :: proc(arg: rawptr) {
	wg_count += 1
	waitgroup_done(&wg)
}

@(test)
test_waitgroup_basic_add_done_wait :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	wg = {}

	wg_count = 0
	wg_woke = false
	waitgroup_add(&wg, 3)
	for _ in 0 ..< 3 {
		go_(wg_worker)
	}
	go_(wg_zero_waiter) // blocks until counter hits 0
	run()

	testing.expectf(t, wg_count == 3, "workers ran %d times, want 3", wg_count)
	testing.expect(t, wg_woke, "waiter did not complete after all workers Done'd")
}

// One Done must wake EVERY parked waiter on that transition (counter 1 -> 0).
@(private = "file")
wg_counting_waiter :: proc(arg: rawptr) {
	waitgroup_wait(&wg)
	wg_workers_woke += 1
}

@(private = "file")
wg_single_done_worker :: proc(arg: rawptr) {
	waitgroup_done(&wg)
}

@(test)
test_waitgroup_wakes_all_waiters :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	wg = {}

	wg_workers_woke = 0
	waitgroup_add(&wg, 1)
	for _ in 0 ..< 5 {
		go_(wg_counting_waiter) // all park on Wait
	}
	go_(wg_single_done_worker) // brings counter 1->0; must wake all 5
	run()

	testing.expectf(t, wg_workers_woke == 5, "woke %d waiters, want 5", wg_workers_woke)
}
