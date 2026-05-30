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
	// Verify the property under several distinct seeds; each run is fresh.
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
