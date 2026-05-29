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

// Work stealing: a single goroutine spawns children onto its own P's local
// queue (under 256, so they never overflow to the global queue). Other Ms can
// only run them by stealing, so seeing >1 M execute children proves stealing.
@(private = "file")
steal_seen: u64

@(private = "file")
steal_counter: i64

@(private = "file")
steal_child :: proc(arg: rawptr) {
	intrinsics.atomic_add(&steal_counter, 1)
	intrinsics.atomic_or(&steal_seen, u64(1) << u64(getm().id))
}

@(private = "file")
steal_spawner :: proc(arg: rawptr) {
	for _ in 0 ..< 200 {
		go_(steal_child)
	}
}

@(test)
test_integration_work_stealing :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	steal_seen = 0
	steal_counter = 0
	go_(steal_spawner)
	run()

	testing.expectf(t, steal_counter == 200, "children = %d, want 200", steal_counter)
	ms := popcount(steal_seen)
	testing.expectf(t, ms >= 2, "children ran on only %d M(s); work stealing should spread them", ms)
}

// gopark on one M, goready from another: a parked goroutine must be resumable
// by a goroutine running on a different OS thread.
@(private = "file")
xm_parked: ^G

@(private = "file")
xm_resumed: bool

@(private = "file")
xm_readied: bool

@(private = "file")
xm_parker :: proc(arg: rawptr) {
	intrinsics.atomic_store(&xm_parked, getg())
	gopark(nil, nil, .None)
	xm_resumed = true // read after join, so a plain store is fine
}

@(private = "file")
xm_readier :: proc(arg: rawptr) {
	// Wait until the parker exists and has actually reached _Gwaiting, then ready
	// it. Spinning via gosched keeps this goroutine runnable (so the deadlock
	// detector never sees all Ms idle).
	for {
		gp := intrinsics.atomic_load(&xm_parked)
		if gp != nil && g_status(gp) == .Waiting {
			goready(gp)
			break
		}
		gosched()
	}
	xm_readied = true
}

@(test)
test_integration_park_ready_cross_m :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	xm_parked = nil
	xm_resumed = false
	xm_readied = false
	go_(xm_parker)
	go_(xm_readier)
	run()

	testing.expect(t, xm_readied, "readier did not run")
	testing.expect(t, xm_resumed, "parked goroutine did not resume after cross-M goready")
}

// Cross-M unbuffered channel handoff: producers and consumers run on different
// OS threads, so every rendezvous is a goroutine parking on one M and being
// woken by send/recv from another. This is the end-to-end exercise of the
// per-M park callback (5.5.1) and chanparkcommit across threads.
@(private = "file")
xchan: ^Hchan

@(private = "file")
xchan_sum: i64

@(private = "file")
xchan_recvs: i64

@(private = "file")
xchan_producer :: proc(arg: rawptr) {
	v := i64(1)
	chansend(xchan, &v, true)
}

@(private = "file")
xchan_consumer :: proc(arg: rawptr) {
	out: i64
	_, ok := chanrecv(xchan, &out, true)
	if ok {
		intrinsics.atomic_add(&xchan_sum, out)
		intrinsics.atomic_add(&xchan_recvs, 1)
	}
}

@(test)
test_integration_chan_cross_m :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	xchan = make_chan(size_of(i64), 0)
	defer destroy_chan(xchan)

	N :: 2000
	xchan_sum = 0
	xchan_recvs = 0
	for _ in 0 ..< N {
		go_(xchan_producer)
		go_(xchan_consumer)
	}
	run()

	testing.expectf(t, xchan_recvs == N, "recvs = %d, want %d", xchan_recvs, N)
	testing.expectf(t, xchan_sum == N, "sum = %d, want %d", xchan_sum, N)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
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
