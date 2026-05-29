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
