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

// Verifies the perturbation actually fires by observing pick ordering. Five
// workers each log their id, gosched (which puts them onto the global runq for
// fairness), then log id+100. After all five reach the gosched phase, the
// global runq holds them in FIFO order; the second phase's order is determined
// by globrunqget — under FIFO it's spawn order, under fuzz it's seed-permuted.
// A test like the property test would PASS even if the fuzz path were
// no-op'd; this test catches that silent regression.

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
