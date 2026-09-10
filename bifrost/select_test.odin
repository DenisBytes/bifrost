package bifrost

import "core:testing"

// Phase 7 unit tests for select_. These drive the scheduler (a blocking select
// parks and is woken by a peer), so each test spawns goroutines and runs.

@(private = "file")
sel_chosen: int

@(private = "file")
sel_ok: bool

@(private = "file")
sel_val: int

@(private = "file")
sa: ^Hchan

@(private = "file")
sb: ^Hchan

// --- pass 1: non-blocking ---------------------------------------------------

// Nothing ready + block=false selects the default (chosen == -1).
@(private = "file")
sel_default_worker :: proc(arg: rawptr) {
	ops := []Select_Op{{c = sa, elem = &sel_val, dir = .Recv}}
	sel_chosen, sel_ok = select_(ops, false)
}

@(test)
test_select_default_when_nothing_ready :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 0)
	defer destroy_chan(sa)

	sel_chosen, sel_ok = -2, false
	go_(sel_default_worker)
	run()

	testing.expectf(t, sel_chosen == -1, "chosen = %d, want -1 (default)", sel_chosen)
}

// A buffered value makes the receive case ready: pass 1 takes it without parking.
@(private = "file")
sel_ready_recv_worker :: proc(arg: rawptr) {
	v := 7
	chansend(sa, &v, true) // buffered, does not block
	out: int
	ops := []Select_Op{{c = sa, elem = &out, dir = .Recv}}
	sel_chosen, sel_ok = select_(ops, false)
	sel_val = out
}

@(test)
test_select_ready_buffered_recv :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 1)
	defer destroy_chan(sa)

	sel_chosen, sel_ok, sel_val = -2, false, 0
	go_(sel_ready_recv_worker)
	run()

	testing.expectf(t, sel_chosen == 0, "chosen = %d, want 0", sel_chosen)
	testing.expect(t, sel_ok, "recv_ok should be true")
	testing.expectf(t, sel_val == 7, "received %d, want 7", sel_val)
}

// Room in the buffer makes the send case ready: pass 1 enqueues without parking.
@(private = "file")
sel_ready_send_worker :: proc(arg: rawptr) {
	v := 42
	ops := []Select_Op{{c = sa, elem = &v, dir = .Send}}
	sel_chosen, sel_ok = select_(ops, false)
	// confirm it landed in the buffer
	out: int
	_, _ = chanrecv(sa, &out, true)
	sel_val = out
}

@(test)
test_select_ready_buffered_send :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 1)
	defer destroy_chan(sa)

	sel_chosen, sel_val = -2, 0
	go_(sel_ready_send_worker)
	run()

	testing.expectf(t, sel_chosen == 0, "chosen = %d, want 0", sel_chosen)
	testing.expectf(t, sel_val == 42, "buffered value = %d, want 42", sel_val)
}

// A closed channel makes a receive case ready in pass 1: chosen with ok=false.
@(private = "file")
sel_closed_worker :: proc(arg: rawptr) {
	out := 5
	ops := []Select_Op{{c = sa, elem = &out, dir = .Recv}}
	sel_chosen, sel_ok = select_(ops, false)
	sel_val = out
}

@(test)
test_select_closed_recv_ready :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 0)
	defer destroy_chan(sa)
	close_chan(sa)

	sel_chosen, sel_ok, sel_val = -2, true, 5
	go_(sel_closed_worker)
	run()

	testing.expectf(t, sel_chosen == 0, "chosen = %d, want 0", sel_chosen)
	testing.expect(t, !sel_ok, "recv_ok should be false on closed channel")
	testing.expectf(t, sel_val == 0, "value = %d, want 0 (zeroed)", sel_val)
}

// --- pass 2/3: blocking park + wake -----------------------------------------

// A blocking select on one channel parks, then a sender on another goroutine
// wakes it.
@(private = "file")
sel_block_recv_worker :: proc(arg: rawptr) {
	out: int
	ops := []Select_Op{{c = sa, elem = &out, dir = .Recv}}
	sel_chosen, sel_ok = select_(ops, true)
	sel_val = out
}

@(private = "file")
sel_sender_a :: proc(arg: rawptr) {
	v := 99
	chansend(sa, &v, true)
}

@(test)
test_select_blocking_woken_by_sender :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 0)
	defer destroy_chan(sa)

	sel_chosen, sel_ok, sel_val = -2, false, 0
	go_(sel_block_recv_worker) // parks in select
	go_(sel_sender_a) // wakes it
	run()

	testing.expectf(t, sel_chosen == 0, "chosen = %d, want 0", sel_chosen)
	testing.expect(t, sel_ok, "recv_ok should be true")
	testing.expectf(t, sel_val == 99, "received %d, want 99", sel_val)
}

// A blocking select over TWO channels parks on both; a send on the second wakes
// it and the loser sudog on the first must be cleanly dequeued.
@(private = "file")
sel_block_two_worker :: proc(arg: rawptr) {
	o1, o2: int
	ops := []Select_Op{{c = sa, elem = &o1, dir = .Recv}, {c = sb, elem = &o2, dir = .Recv}}
	sel_chosen, sel_ok = select_(ops, true)
	if sel_chosen == 1 {
		sel_val = o2
	} else if sel_chosen == 0 {
		sel_val = o1
	}
}

@(private = "file")
sel_sender_b :: proc(arg: rawptr) {
	v := 55
	chansend(sb, &v, true)
}

@(test)
test_select_blocking_two_channels :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 0)
	defer destroy_chan(sa)
	sb = make_chan(size_of(int), 0)
	defer destroy_chan(sb)

	sel_chosen, sel_ok, sel_val = -2, false, 0
	go_(sel_block_two_worker) // parks on both sa and sb
	go_(sel_sender_b) // sends on sb -> case 1 fires
	run()

	testing.expectf(t, sel_chosen == 1, "chosen = %d, want 1", sel_chosen)
	testing.expect(t, sel_ok, "recv_ok should be true")
	testing.expectf(t, sel_val == 55, "received %d, want 55", sel_val)
}

// A blocking select with a SEND case parks on the send queue, then a receiver on
// another goroutine wakes it (the send-side pass 2/3 path).
@(private = "file")
sel_block_send_worker :: proc(arg: rawptr) {
	v := 77
	ops := []Select_Op{{c = sa, elem = &v, dir = .Send}}
	sel_chosen, sel_ok = select_(ops, true)
}

@(private = "file")
sel_receiver_a :: proc(arg: rawptr) {
	out: int
	_, _ = chanrecv(sa, &out, true)
	sel_val = out
}

@(test)
test_select_blocking_send_woken_by_receiver :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	sa = make_chan(size_of(int), 0)
	defer destroy_chan(sa)

	sel_chosen, sel_ok, sel_val = -2, false, 0
	go_(sel_block_send_worker) // parks on sa.sendq via select
	go_(sel_receiver_a) // receives -> wakes the selector
	run()

	testing.expectf(t, sel_chosen == 0, "chosen = %d, want 0", sel_chosen)
	testing.expectf(t, sel_val == 77, "receiver got %d, want 77", sel_val)
}

@(test)
test_select_lockorder_is_sorted_and_groups_duplicates :: proc(t: ^testing.T) {
	// sellock/selunlock lock each distinct channel once by skipping entries equal
	// to their neighbour, so the sort must be TOTAL (ascending by address) and
	// must leave duplicate channels ADJACENT. A sort that failed either property
	// would double-lock a channel — a hang — or leave one locked on return.
	runtime_init(1)
	defer runtime_teardown()

	chans: [6]^Hchan
	for i in 0 ..< 6 {
		chans[i] = make_chan(size_of(int), 0)
	}
	defer for c in chans {destroy_chan(c)}

	// Deliberately include duplicates and both directions on one channel.
	ops := []Select_Op {
		{c = chans[3], dir = .Recv},
		{c = chans[0], dir = .Recv},
		{c = chans[3], dir = .Send}, // duplicate of index 0's channel
		{c = chans[5], dir = .Recv},
		{c = chans[0], dir = .Send}, // duplicate of index 1's channel
		{c = chans[1], dir = .Recv},
		{c = chans[3], dir = .Recv}, // third copy
		{c = chans[4], dir = .Recv},
	}

	// Reproduce select_'s ordering phases over the same input.
	n := len(ops)
	pollorder := make([]int, n)
	defer delete(pollorder)
	lockorder := make([]int, n)
	defer delete(lockorder)
	for i in 0 ..< n {
		pollorder[i] = i
	}
	select_build_lockorder(ops, pollorder, lockorder)

	for i in 1 ..< n {
		testing.expectf(
			t,
			uintptr(ops[lockorder[i - 1]].c) <= uintptr(ops[lockorder[i]].c),
			"lockorder not ascending at %d: %p then %p",
			i,
			ops[lockorder[i - 1]].c,
			ops[lockorder[i]].c,
		)
	}

	// Every case must appear exactly once.
	seen: [8]bool
	for o in lockorder {
		testing.expectf(t, !seen[o], "case %d appears twice in lockorder", o)
		seen[o] = true
	}
	for s, i in seen {
		testing.expectf(t, s, "case %d missing from lockorder", i)
	}

	// Duplicates adjacent: counting distinct runs must equal the distinct count.
	runs := 1
	for i in 1 ..< n {
		if ops[lockorder[i]].c != ops[lockorder[i - 1]].c {
			runs += 1
		}
	}
	testing.expectf(t, runs == 5, "distinct channel runs = %d, want 5", runs)
}
