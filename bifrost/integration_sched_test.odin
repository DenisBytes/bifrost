package bifrost

import "base:intrinsics"
import "core:testing"

// Heavier scheduler stress, gated on BIFROST_INTEGRATION. Single-M cooperative
// scheduling at scale: many goroutines, many yields, exercising the local
// runq + global-queue overflow (runqputslow) and dead-G reuse. The multi-M
// tests at the bottom run on gomaxprocs>1 real OS threads.

@(private = "file")
stress_counter: int

@(private = "file")
stress_worker :: proc(arg: rawptr) {
	stress_counter += 1
	for _ in 0 ..< 5 {
		gosched()
	}
}

@(test)
test_integration_many_goroutines :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(1)
	defer runtime_teardown()

	N :: 10000
	stress_counter = 0
	for _ in 0 ..< N {
		go_(stress_worker)
	}
	run()

	testing.expectf(t, stress_counter == N, "counter = %d, want %d", stress_counter, N)
	live := live_goroutines()
	testing.expectf(t, live == 0, "live goroutines after run = %d, want 0", live)
}

// Repeated batches must reuse dead Gs rather than growing allgs without bound.
@(test)
test_integration_batches_reuse :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(1)
	defer runtime_teardown()

	BATCH :: 2000
	ROUNDS :: 5
	stress_counter = 0
	for _ in 0 ..< ROUNDS {
		for _ in 0 ..< BATCH {
			go_(stress_worker)
		}
		run()
	}

	testing.expectf(t, stress_counter == BATCH * ROUNDS, "counter = %d, want %d", stress_counter, BATCH * ROUNDS)
	// Peak concurrency is one batch, so allgs should never exceed BATCH.
	testing.expectf(t, len(allgs) == BATCH, "allgs = %d, want %d (reuse)", len(allgs), BATCH)
}

// ---------------------------------------------------------------------------
// Multi-M (parallel) stress
// ---------------------------------------------------------------------------

@(private = "file")
par_counter: i64

// ms_seen records, as a bitmask, which M ids ran at least one goroutine, to
// prove work actually ran in parallel across OS threads.
@(private = "file")
ms_seen: u64

@(private = "file")
par_worker :: proc(arg: rawptr) {
	intrinsics.atomic_add(&par_counter, 1)
	intrinsics.atomic_or(&ms_seen, u64(1) << u64(getm().id))
	for _ in 0 ..< 4 {
		gosched()
	}
}

@(private = "file")
popcount :: proc(x: u64) -> int {
	n := 0
	v := x
	for v != 0 {
		n += int(v & 1)
		v >>= 1
	}
	return n
}

@(test)
test_integration_parallel_counter :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	N :: 20000
	par_counter = 0
	ms_seen = 0
	for _ in 0 ..< N {
		go_(par_worker)
	}
	run()

	testing.expectf(t, par_counter == N, "counter = %d, want %d", par_counter, N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
	ms := popcount(ms_seen)
	testing.expectf(t, ms >= 2, "only %d M(s) ran goroutines; expected parallel execution", ms)
}

// Repeated init/spawn/run/teardown cycles on multiple threads must stay
// leak-clean and not deadlock (exercises thread create/join each round).
@(test)
test_integration_multi_m_repeated :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	for round in 0 ..< 5 {
		runtime_init(4)
		par_counter = 0
		for _ in 0 ..< 3000 {
			go_(par_worker)
		}
		run()
		testing.expectf(t, par_counter == 3000, "round %d: counter = %d, want 3000", round, par_counter)
		runtime_teardown()
	}
}
