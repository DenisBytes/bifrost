package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 13.6 unit tests for the deterministic-schedule fuzzer skeleton.
// The premise: with a non-zero fuzz_seed, the scheduler perturbs its picks
// pseudo-randomly; runs are reproducible per seed and any property that holds
// under FIFO should also hold under any fuzz seed.

@(private = "file")
fz_counter: i64

@(private = "file")
fz_worker :: proc(arg: rawptr) {
	intrinsics.atomic_add(&fz_counter, 1)
	gosched()
	intrinsics.atomic_add(&fz_counter, 1)
}

// A property that holds regardless of scheduling: spawn N workers that each
// increment a counter twice. The final count must equal 2N for any seed.
@(test)
test_fuzz_property_holds_under_seeds :: proc(t: ^testing.T) {
	defer runtime_set_fuzz_seed(0) // never leak fuzz mode into subsequent tests
	seeds := []u64{0, 1, 42, 1337, 0xdeadbeef}
	for seed in seeds {
		runtime_init(1)
		runtime_set_fuzz_seed(seed)
		fz_counter = 0
		for _ in 0 ..< 20 {
			go_(fz_worker)
		}
		run()

		want := i64(40)
		testing.expectf(t, fz_counter == want, "seed=%d: counter=%d, want %d", seed, fz_counter, want)
		runtime_teardown()
	}
}

// Same seed should give a reproducible "first runnable on global runq" pick.
// Test it indirectly: two runs with the same seed and the same goroutines
// produce the same outcome (always true for this property, but it documents
// that set/clear works).
@(test)
test_fuzz_seed_setter_round_trip :: proc(t: ^testing.T) {
	runtime_set_fuzz_seed(0)
	testing.expect(t, !runtime_fuzz_active(), "seed=0 should leave fuzz mode off")
	runtime_set_fuzz_seed(1)
	testing.expect(t, runtime_fuzz_active(), "seed!=0 should activate fuzz mode")
	runtime_set_fuzz_seed(0) // reset so subsequent tests run in normal mode
}

// Helpers for test_fuzz_perturbation_is_active (full doc on the test itself).
@(private = "file")
fz_order_log: [10]i32

@(private = "file")
fz_order_mtx: Mutex

@(private = "file")
fz_order_worker :: proc(arg: rawptr) {
	id := i32(uintptr(arg))
	mutex_lock(&fz_order_mtx)
	for i in 0 ..< 10 {
		if fz_order_log[i] == 0 {
			fz_order_log[i] = id
			break
		}
	}
	mutex_unlock(&fz_order_mtx)
	gosched() // goes to global runq
	mutex_lock(&fz_order_mtx)
	for i in 0 ..< 10 {
		if fz_order_log[i] == 0 {
			fz_order_log[i] = id + 100
			break
		}
	}
	mutex_unlock(&fz_order_mtx)
}

@(private = "file")
run_fuzz_order_under_seed :: proc(seed: u64) -> [5]i32 {
	runtime_init(1)
	defer runtime_teardown()
	mutex_init(&fz_order_mtx)
	runtime_set_fuzz_seed(seed)
	fz_order_log = {}
	for i in 1 ..= 5 {
		go_(fz_order_worker, rawptr(uintptr(i)))
	}
	run()
	post_gosched: [5]i32
	for i in 0 ..< 5 {
		post_gosched[i] = fz_order_log[5 + i]
	}
	return post_gosched
}

// Verifies the perturbation actually fires by observing pick ordering. Five
// workers each log their id, gosched (which puts them onto the global runq for
// fairness), then log id+100. After all five reach the gosched phase, the
// global runq holds them in FIFO order; the second phase's order is
// determined by globrunqget — under FIFO it's spawn order [101..105], under
// fuzz it's seed-permuted. The order-invariant property test above would PASS
// even if the fuzz path were no-op'd; this test catches that silent regression.
@(test)
test_fuzz_perturbation_is_active :: proc(t: ^testing.T) {
	defer runtime_set_fuzz_seed(0)

	fifo := run_fuzz_order_under_seed(0)
	// FIFO globrunqget returns workers in the order they yielded, which is
	// the same as their spawn order: 1, 2, 3, 4, 5 → tagged 101..105.
	expected := [5]i32{101, 102, 103, 104, 105}
	testing.expectf(t, fifo == expected, "FIFO post-gosched order = %v, want %v", fifo, expected)

	// At least one of these seeds must produce a different post-gosched order
	// than FIFO. If they ALL match FIFO, the fuzz perturbation is silently
	// inactive (e.g., the random-index branch in globrunqget was removed).
	seeds := [?]u64{1, 42, 1337, 0xdeadbeef}
	any_differs := false
	for seed in seeds {
		order := run_fuzz_order_under_seed(seed)
		if order != expected {
			any_differs = true
		}
	}
	testing.expect(t, any_differs, "no fuzz seed produced a different order than FIFO — perturbation may be silently inactive")
}

// ---------------------------------------------------------------------------
// Coverage: does the fuzzer actually perturb the primitives?
// ---------------------------------------------------------------------------

@(private = "file")
FUZZ_WAITERS :: 32
@(private = "file")
fuzz_mu: Mutex
@(private = "file")
fuzz_cv: Cond
@(private = "file")
fuzz_gate: bool
@(private = "file")
fuzz_woken: int
@(private = "file")
fuzz_observed: u64

@(private = "file")
fuzz_waiter :: proc(arg: rawptr) {
	mutex_lock(&fuzz_mu)
	for !fuzz_gate {
		cond_wait(&fuzz_cv, &fuzz_mu)
	}
	fuzz_woken += 1
	mutex_unlock(&fuzz_mu)
}

@(private = "file")
fuzz_opener :: proc(arg: rawptr) {
	// Let every waiter park first, then release them all at once. A broadcast
	// goreadys FUZZ_WAITERS goroutines back to back, so the global run queue
	// genuinely holds many runnable Gs and the scheduler has a real choice to
	// perturb — which a two-goroutine ping-pong never offers, because with at
	// most one runnable goroutine there is nothing to reorder.
	for _ in 0 ..< FUZZ_WAITERS * 4 {
		gosched()
	}
	mutex_lock(&fuzz_mu)
	fuzz_gate = true
	mutex_unlock(&fuzz_mu)
	cond_broadcast(&fuzz_cv)
}

@(private = "file")
fuzz_run_broadcast_workload :: proc(seed: u64) {
	runtime_init(1)
	runtime_set_fuzz_seed(seed)
	fuzz_gate = false
	fuzz_woken = 0
	mutex_init(&fuzz_mu)
	cond_init(&fuzz_cv)
	for _ in 0 ..< FUZZ_WAITERS {
		go_(fuzz_waiter)
	}
	go_(fuzz_opener)
	run()
	// Capture before teardown, which resets the counter.
	fuzz_observed = runtime_fuzz_count()
	runtime_set_fuzz_seed(0)
	runtime_teardown()
}

@(test)
test_fuzz_reaches_sync_primitive_wakeups :: proc(t: ^testing.T) {
	// The perturbation site is globrunqget, but a readied goroutine normally goes
	// onto its P's LOCAL ring and never reaches the global queue — so before
	// ready()'s fuzz hook the fuzzer perturbed 0% of scheduling decisions in
	// every channel/select/Mutex/sema/Cond workload. This pins that a primitive
	// wakeup now actually consumes seed values, i.e. that the fuzzer exercises
	// something rather than silently doing nothing.
	fuzz_run_broadcast_workload(0x9E3779B97F4A7C15)

	testing.expectf(t, fuzz_woken == FUZZ_WAITERS, "woke %d of %d waiters", fuzz_woken, FUZZ_WAITERS)
	testing.expectf(
		t,
		fuzz_observed > 0,
		"the fuzzer reordered %d scheduling decisions: it perturbed nothing in a Cond/Mutex workload",
		fuzz_observed,
	)
}

@(test)
test_fuzz_seed_sweep_is_result_stable :: proc(t: ^testing.T) {
	// Many seeds over the same workload. Perturbing the schedule must reorder
	// wakeups without ever changing the ANSWER; a seed that does is an
	// ordering-dependent bug in the runtime, not in the test.
	for i in u64(1) ..= 40 {
		fuzz_run_broadcast_workload(i * 0x9E3779B97F4A7C15)
		testing.expectf(
			t,
			fuzz_woken == FUZZ_WAITERS,
			"seed #%d: woke %d of %d waiters",
			i,
			fuzz_woken,
			FUZZ_WAITERS,
		)
	}
}
