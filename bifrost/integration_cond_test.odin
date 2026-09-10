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

// ---------------------------------------------------------------------------
// Bounded buffer: the case the unbounded-queue test above structurally cannot
// fail. With an unbounded queue only consumers ever wait, so some producer
// always issues the next signal and a lost wakeup is invisible. A capacity-1
// buffer makes BOTH sides wait, which is what exposed the counting-semaphore
// Cond's lost wakeup.
// ---------------------------------------------------------------------------

@(private = "file")
BB_CAP :: 1
@(private = "file")
BB_ITEMS :: 200
@(private = "file")
BB_PRODUCERS :: 4
@(private = "file")
BB_CONSUMERS :: 4

@(private = "file")
bb_m: Mutex
@(private = "file")
bb_c: Cond
@(private = "file")
bb_ring: [BB_CAP]int
@(private = "file")
bb_n: int
@(private = "file")
bb_produced: int
@(private = "file")
bb_consumed: int
@(private = "file")
bb_sum: int

@(private = "file")
bb_producer :: proc(arg: rawptr) {
	for {
		mutex_lock(&bb_m)
		for bb_n == BB_CAP && bb_produced < BB_ITEMS {
			cond_wait(&bb_c, &bb_m)
		}
		if bb_produced >= BB_ITEMS {
			mutex_unlock(&bb_m)
			cond_broadcast(&bb_c)
			return
		}
		bb_produced += 1
		bb_ring[bb_n] = bb_produced
		bb_n += 1
		mutex_unlock(&bb_m)
		cond_broadcast(&bb_c)
	}
}

@(private = "file")
bb_consumer :: proc(arg: rawptr) {
	for {
		mutex_lock(&bb_m)
		for bb_n == 0 && bb_consumed < BB_ITEMS {
			cond_wait(&bb_c, &bb_m)
		}
		if bb_n == 0 && bb_consumed >= BB_ITEMS {
			mutex_unlock(&bb_m)
			cond_broadcast(&bb_c)
			return
		}
		bb_n -= 1
		v := bb_ring[bb_n]
		bb_consumed += 1
		bb_sum += v
		mutex_unlock(&bb_m)
		cond_broadcast(&bb_c)
	}
}

@(test)
test_integration_cond_bounded_buffer :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	for procs in ([]i32{1, 2, 4, 8}) {
		bb_n = 0
		bb_produced = 0
		bb_consumed = 0
		bb_sum = 0

		runtime_init(procs)
		mutex_init(&bb_m)
		cond_init(&bb_c)
		for _ in 0 ..< BB_PRODUCERS {
			go_(bb_producer)
		}
		for _ in 0 ..< BB_CONSUMERS {
			go_(bb_consumer)
		}
		run()
		runtime_teardown()

		want := BB_ITEMS * (BB_ITEMS + 1) / 2
		testing.expectf(t, bb_produced == BB_ITEMS, "procs=%d: produced %d, want %d", procs, bb_produced, BB_ITEMS)
		testing.expectf(t, bb_consumed == BB_ITEMS, "procs=%d: consumed %d, want %d", procs, bb_consumed, BB_ITEMS)
		testing.expectf(t, bb_sum == want, "procs=%d: sum %d, want %d", procs, bb_sum, want)
	}
}
