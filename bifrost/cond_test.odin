package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.6 unit tests for Cond. cond_wait atomically releases its associated
// Mutex and parks; cond_signal wakes one waiter; cond_broadcast wakes all.
// Tests use the canonical predicate idiom (`while !predicate { wait }`) so
// they're robust to spurious wakeups and to signal-before-wait races.

@(private = "file")
c: Cond

@(private = "file")
cm: Mutex

@(private = "file")
cond_predicate: bool

@(private = "file")
cond_woke: i32

@(private = "file")
cond_waiter :: proc(arg: rawptr) {
	mutex_lock(&cm)
	for !cond_predicate {
		cond_wait(&c, &cm)
	}
	intrinsics.atomic_add(&cond_woke, 1)
	mutex_unlock(&cm)
}

@(private = "file")
cond_signaler :: proc(arg: rawptr) {
	mutex_lock(&cm)
	cond_predicate = true
	cond_signal(&c)
	mutex_unlock(&cm)
}

@(test)
test_cond_signal_wakes_one_waiter :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = false
	cond_woke = 0
	go_(cond_waiter) // parks on cond
	go_(cond_signaler) // sets predicate, signals
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 1, "woke = %d, want 1", cond_woke)
}

// A single broadcast wakes EVERY parked waiter.
@(private = "file")
cond_broadcaster :: proc(arg: rawptr) {
	mutex_lock(&cm)
	cond_predicate = true
	cond_broadcast(&c)
	mutex_unlock(&cm)
}

@(test)
test_cond_broadcast_wakes_all :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = false
	cond_woke = 0
	for _ in 0 ..< 5 {
		go_(cond_waiter) // five parked waiters
	}
	go_(cond_broadcaster) // one broadcast wakes them all
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 5, "woke = %d, want 5", cond_woke)
}

// If the predicate is already true at wait time, the waiter returns without
// parking — proves the while-predicate idiom is safe even when the signal
// "preceded" the wait.
@(private = "file")
cond_waiter_predicate_true :: proc(arg: rawptr) {
	mutex_lock(&cm)
	for !cond_predicate {
		cond_wait(&c, &cm)
	}
	intrinsics.atomic_add(&cond_woke, 1)
	mutex_unlock(&cm)
}

@(test)
test_cond_wait_skips_when_predicate_already_true :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	cond_init(&c)
	mutex_init(&cm)

	cond_predicate = true // already true: waiter must NOT park
	cond_woke = 0
	go_(cond_waiter_predicate_true)
	run()

	testing.expectf(t, intrinsics.atomic_load(&cond_woke) == 1, "woke = %d, want 1 (no signaler needed)", cond_woke)
}

// ---------------------------------------------------------------------------
// Lost-wakeup regression: the ticket notify list
// ---------------------------------------------------------------------------

@(private = "file")
pp_m: Mutex
@(private = "file")
pp_c: Cond
@(private = "file")
pp_turn: int
@(private = "file")
pp_rounds: int
@(private = "file")
PP_DONE :: 20

@(private = "file")
pp_side :: proc(me: int) {
	for {
		mutex_lock(&pp_m)
		for pp_turn != me { 	// predicate loop, exactly as documented
			cond_wait(&pp_c, &pp_m)
		}
		if pp_rounds >= PP_DONE {
			// Hand the turn over before leaving, or the peer waits on a
			// predicate that can never become true — a bug in the TEST, not in
			// Cond, and one that looks exactly like the defect under test.
			pp_turn = 1 - me
			mutex_unlock(&pp_m)
			cond_broadcast(&pp_c)
			return
		}
		pp_rounds += 1
		pp_turn = 1 - me // predicate mutated under the mutex
		mutex_unlock(&pp_m)
		cond_broadcast(&pp_c)
	}
}

@(private = "file")
pp_a :: proc(arg: rawptr) {pp_side(0)}
@(private = "file")
pp_b :: proc(arg: rawptr) {pp_side(1)}

@(test)
test_cond_ping_pong_no_lost_wakeup :: proc(t: ^testing.T) {
	// The textbook predicate idiom: every state change under the mutex, every
	// wait in a `for !predicate` loop. With a counting semaphore behind Cond, a
	// goroutine ENTERING cond_wait after a signal consumed the permit released
	// for the already-parked peer and then parked itself, so both sides ended up
	// parked with nobody left to signal. This deadlocked 3/3 before the ticket
	// notify list; the test runner reports it as a hang or a deadlock exit.
	pp_turn = 0
	pp_rounds = 0
	runtime_init(1)
	defer runtime_teardown()
	mutex_init(&pp_m)
	cond_init(&pp_c)
	go_(pp_a)
	go_(pp_b)
	run()
	testing.expectf(t, pp_rounds == PP_DONE, "completed %d of %d ping-pong rounds", pp_rounds, PP_DONE)
}

@(test)
test_cond_signal_before_wait_is_not_absorbed :: proc(t: ^testing.T) {
	// A signal issued for ticket t must be consumable ONLY by the waiter holding
	// t. cond_notify_wait's early return is that guarantee: a waiter that takes
	// its ticket, is signalled before it reaches the list, and then arrives, must
	// return immediately rather than park forever.
	cv: Cond
	cond_init(&cv)
	testing.expect(t, cv.wait == 0 && cv.notify == 0, "fresh Cond must start at ticket 0")

	// Hand out a ticket without parking, then signal it.
	t0 := intrinsics.atomic_add(&cv.wait, u32(1))
	testing.expect(t, t0 == 0, "first ticket must be 0")
	cond_signal(&cv)
	testing.expectf(t, cv.notify == 1, "notify = %d, want 1 after signalling ticket 0", cv.notify)

	// The holder of ticket 0 now arrives: it must see itself already notified.
	testing.expect(
		t,
		cond_ticket_less(t0, cv.notify),
		"ticket 0 must read as already notified, so cond_notify_wait returns without parking",
	)
}

@(test)
test_cond_ticket_less_handles_wraparound :: proc(t: ^testing.T) {
	// wait/notify are u32 counters that wrap. Ordering must stay correct across
	// the wrap, which is why the comparison is `i32(a - b) < 0` and not `a < b`.
	testing.expect(t, cond_ticket_less(0, 1), "0 precedes 1")
	testing.expect(t, !cond_ticket_less(1, 0), "1 does not precede 0")
	testing.expect(t, cond_ticket_less(max(u32), 0), "max(u32) precedes 0 across the wrap")
	testing.expect(t, !cond_ticket_less(0, max(u32)), "0 does not precede max(u32)")
	testing.expect(t, !cond_ticket_less(5, 5), "a ticket does not precede itself")
}
