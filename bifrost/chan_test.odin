package bifrost

import "core:testing"

// Phase 6.1 unit tests: the Sudog pool (acquire_sudog/release_sudog, in
// proc.odin) and the channel wait queue (Waitq, in chan.odin). Both run without
// the scheduler loop: runtime_init wires m0 to allp[0], so getm().p is valid for
// the pool, and teardown must reclaim every pooled Sudog (the tracking allocator
// flags a leak otherwise).

@(test)
test_sudog_acquire_release_reuse :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	// First acquire allocates; releasing returns it to the local cache; the next
	// acquire hands back the very same object (LIFO reuse, no new allocation).
	s1 := acquire_sudog()
	testing.expect(t, s1 != nil, "acquire_sudog returned nil")
	release_sudog(s1)
	s2 := acquire_sudog()
	testing.expect(t, s2 == s1, "expected the released sudog to be reused")
	release_sudog(s2)
}

@(test)
test_sudog_pool_no_unbounded_growth :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	// Acquire a batch and release it all, then re-acquire the same count: every
	// object must come from the released set (reuse, not fresh allocation).
	N :: 64
	first: [N]^Sudog
	for i in 0 ..< N {
		first[i] = acquire_sudog()
	}
	for i in 0 ..< N {
		release_sudog(first[i])
	}

	seen := make(map[^Sudog]bool, N)
	defer delete(seen)
	for s in first {
		seen[s] = true
	}
	second: [N]^Sudog
	for i in 0 ..< N {
		second[i] = acquire_sudog()
		testing.expect(t, seen[second[i]], "re-acquire returned a sudog not from the released set")
	}
	// Return them so teardown's pool free reclaims everything (no leak).
	for i in 0 ..< N {
		release_sudog(second[i])
	}
}

@(test)
test_waitq_fifo_order :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	a := acquire_sudog()
	b := acquire_sudog()
	c := acquire_sudog()

	q: Waitq
	waitq_enqueue(&q, a)
	waitq_enqueue(&q, b)
	waitq_enqueue(&q, c)

	testing.expect(t, waitq_dequeue(&q) == a, "dequeue 1 != a")
	testing.expect(t, waitq_dequeue(&q) == b, "dequeue 2 != b")
	testing.expect(t, waitq_dequeue(&q) == c, "dequeue 3 != c")
	testing.expect(t, waitq_dequeue(&q) == nil, "dequeue on empty queue != nil")

	// Dequeued sudogs come back fully unlinked (next/prev nil), so they are
	// releasable; returning them keeps teardown leak-clean.
	release_sudog(a)
	release_sudog(b)
	release_sudog(c)
}

@(test)
test_waitq_empty_dequeue :: proc(t: ^testing.T) {
	q: Waitq
	testing.expect(t, waitq_dequeue(&q) == nil, "empty waitq should dequeue nil")
}

// make_chan / destroy_chan / close_chan operate purely on the channel and the
// caller's allocator, so they need no running scheduler.

@(test)
test_make_chan_unbuffered :: proc(t: ^testing.T) {
	c := make_chan(size_of(int), 0)
	defer destroy_chan(c)

	testing.expect(t, c != nil, "make_chan returned nil")
	testing.expectf(t, c.dataqsiz == 0, "dataqsiz = %d, want 0", c.dataqsiz)
	testing.expect(t, c.buf == nil, "unbuffered channel should have nil buf")
	testing.expectf(t, c.elem_size == size_of(int), "elem_size = %d, want %d", c.elem_size, size_of(int))
	testing.expectf(t, c.qcount == 0, "qcount = %d, want 0", c.qcount)
	testing.expectf(t, c.closed == 0, "closed = %d, want 0", c.closed)
}

@(test)
test_make_chan_buffered :: proc(t: ^testing.T) {
	c := make_chan(size_of(int), 4)
	defer destroy_chan(c)

	testing.expectf(t, c.dataqsiz == 4, "dataqsiz = %d, want 4", c.dataqsiz)
	testing.expect(t, c.buf != nil, "buffered channel should have a non-nil buf")
	// The buffer lives immediately after the header in the same allocation.
	want_buf := rawptr(uintptr(c) + uintptr(size_of(Hchan)))
	testing.expect(t, c.buf == want_buf, "buf should point just past the header")
}

@(test)
test_close_chan_sets_flag :: proc(t: ^testing.T) {
	c := make_chan(size_of(int), 0)
	defer destroy_chan(c)

	close_chan(c)
	testing.expect(t, c.closed != 0, "close_chan did not set the closed flag")
}

// ---------------------------------------------------------------------------
// Unbuffered send/recv (6.3). These drive the scheduler: send/recv park
// goroutines and hand off between them, so each test spawns goroutines and runs.
// ---------------------------------------------------------------------------

@(private = "file")
tc_chan: ^Hchan

@(private = "file")
tc_got: int

@(private = "file")
tc_ok: bool

@(private = "file")
tc_send99 :: proc(arg: rawptr) {
	v := 99
	chansend(tc_chan, &v, true)
}

@(private = "file")
tc_recv :: proc(arg: rawptr) {
	out: int
	_, ok := chanrecv(tc_chan, &out, true)
	tc_got = out
	tc_ok = ok
}

// Sender parks first; the receiver finds it on sendq and completes via recv().
@(test)
test_chan_recv_from_waiting_sender :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	tc_chan = make_chan(size_of(int), 0)
	defer destroy_chan(tc_chan)

	tc_got, tc_ok = 0, false
	go_(tc_send99) // runs first, parks on sendq
	go_(tc_recv) // dequeues the sender -> recv()
	run()

	testing.expectf(t, tc_got == 99, "received %d, want 99", tc_got)
	testing.expect(t, tc_ok, "recv ok should be true")
}

// Receiver parks first; the sender finds it on recvq and completes via send().
// (Exercises the Phase 6.3 send() contribution.)
@(test)
test_chan_send_to_waiting_receiver :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	tc_chan = make_chan(size_of(int), 0)
	defer destroy_chan(tc_chan)

	tc_got, tc_ok = 0, false
	go_(tc_recv) // runs first, parks on recvq
	go_(tc_send99) // dequeues the receiver -> send()
	run()

	testing.expectf(t, tc_got == 99, "received %d, want 99", tc_got)
	testing.expect(t, tc_ok, "recv ok should be true")
}

@(private = "file")
tc_recv_into_123 :: proc(arg: rawptr) {
	out := 123
	_, ok := chanrecv(tc_chan, &out, true)
	tc_got = out
	tc_ok = ok
}

// Receiving from a closed, empty channel returns the zero value with ok=false
// and never parks (no send() involved).
@(test)
test_chan_recv_from_closed_empty :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	tc_chan = make_chan(size_of(int), 0)
	defer destroy_chan(tc_chan)
	close_chan(tc_chan)

	tc_got, tc_ok = -1, true
	go_(tc_recv_into_123)
	run()

	testing.expectf(t, tc_got == 0, "recv on closed empty should zero ep, got %d", tc_got)
	testing.expect(t, !tc_ok, "recv ok on closed empty should be false")
}

// Zero-size element (a `chan struct{}` signal channel): the byte copy is a no-op,
// so this exercises that the nil/size guards keep the pure-synchronisation
// rendezvous working with nothing to transfer.
@(private = "file")
sig_received: bool

@(private = "file")
sig_sender :: proc(arg: rawptr) {
	dummy: struct {}
	chansend(tc_chan, &dummy, true)
}

@(private = "file")
sig_receiver :: proc(arg: rawptr) {
	dummy: struct {}
	chanrecv(tc_chan, &dummy, true)
	sig_received = true
}

@(test)
test_chan_zero_size_signal :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	tc_chan = make_chan(0, 0)
	defer destroy_chan(tc_chan)

	sig_received = false
	go_(sig_sender)
	go_(sig_receiver)
	run()

	testing.expect(t, sig_received, "zero-size signal rendezvous did not complete")
}
