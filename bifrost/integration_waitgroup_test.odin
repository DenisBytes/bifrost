package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.3 integration: a 4-thread fan-in. Many workers Done; one waiter
// Waits and must observe the final count once all workers have completed.

@(private = "file")
WG_INT_N :: 5000

@(private = "file")
wg_int: WaitGroup

@(private = "file")
wg_int_counter: i64

@(private = "file")
wg_int_waiter_saw_all: bool

@(private = "file")
wg_int_worker :: proc(arg: rawptr) {
	intrinsics.atomic_add(&wg_int_counter, 1)
	waitgroup_done(&wg_int)
}

@(private = "file")
wg_int_waiter :: proc(arg: rawptr) {
	waitgroup_wait(&wg_int)
	// The sema's release/acquire ordering must publish every worker's
	// increment by the time wait returns; an exact final count proves both
	// the WaitGroup's completion semantics and the cross-thread visibility.
	wg_int_waiter_saw_all = intrinsics.atomic_load(&wg_int_counter) == WG_INT_N
}

@(test)
test_integration_waitgroup_fan_in :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	wg_int = {}

	wg_int_counter = 0
	wg_int_waiter_saw_all = false
	waitgroup_add(&wg_int, WG_INT_N)
	for _ in 0 ..< WG_INT_N {
		go_(wg_int_worker)
	}
	go_(wg_int_waiter)
	run()

	testing.expectf(t, wg_int_counter == WG_INT_N, "counter = %d, want %d", wg_int_counter, WG_INT_N)
	testing.expect(t, wg_int_waiter_saw_all, "waiter returned before all workers Done'd")
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

// Multiple waiters parked on the same transition: every one must be woken when
// the counter hits 0.
@(private = "file")
WG_MULTI_WAITERS :: 64

@(private = "file")
wg_multi: WaitGroup

@(private = "file")
wg_multi_woke: i64

@(private = "file")
wg_multi_waiter :: proc(arg: rawptr) {
	waitgroup_wait(&wg_multi)
	intrinsics.atomic_add(&wg_multi_woke, 1)
}

@(private = "file")
wg_multi_releaser :: proc(arg: rawptr) {
	waitgroup_done(&wg_multi)
}

@(test)
test_integration_waitgroup_wakes_many_waiters :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	wg_multi = {}

	wg_multi_woke = 0
	waitgroup_add(&wg_multi, 1)
	for _ in 0 ..< WG_MULTI_WAITERS {
		go_(wg_multi_waiter) // all park on the same counter==1
	}
	go_(wg_multi_releaser) // single Done wakes every waiter
	run()

	testing.expectf(
		t,
		wg_multi_woke == WG_MULTI_WAITERS,
		"woke %d waiters, want %d",
		wg_multi_woke,
		WG_MULTI_WAITERS,
	)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
