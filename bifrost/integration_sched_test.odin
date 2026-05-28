package bifrost

import "core:testing"

// Heavier scheduler stress, gated on BIFROST_INTEGRATION. Single-M cooperative
// scheduling at scale: many goroutines, many yields, exercising the local
// runq + global-queue overflow (runqputslow) and dead-G reuse.

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
