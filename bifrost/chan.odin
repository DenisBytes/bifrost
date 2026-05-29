package bifrost

import "core:mem"
import "core:sync"

// Channels: bifrost's port of Go's chan.go, built up across Phase 6. This file
// (6.1) lands the wait queue and the channel header; make_chan + send/recv +
// close arrive in 6.2-6.5, and a typed Chan(T) wrapper in 6.6. Mirrors chan.go;
// every divergence from Go is noted at its site.

// Waitq is a FIFO queue of Sudogs (parked goroutines) waiting on a channel: one
// for blocked senders (Hchan.sendq) and one for blocked receivers
// (Hchan.recvq). It is doubly linked through Sudog.next/prev so the front pops
// in O(1) and a select can later splice a Sudog out of the middle. Mirrors Go's
// waitq (chan.go:57).
Waitq :: struct {
	first: ^Sudog,
	last:  ^Sudog,
}

// Hchan is a channel's header. For a buffered channel the dataqsiz-element ring
// buffer is allocated immediately after this header by make_chan (Phase 6.2);
// `buf` points at it. Mirrors Go's hchan (chan.go:34), reduced to the fields
// bifrost uses; the GC/type fields (elemtype, the typed buffer) collapse to a
// raw byte buffer plus elem_size because bifrost copies untyped bytes.
Hchan :: struct {
	// qcount is the number of elements currently in the buffer.
	qcount: uint,
	// dataqsiz is the buffer capacity in elements (0 == unbuffered channel).
	dataqsiz: uint,
	// buf points at the dataqsiz-element ring buffer, or nil when unbuffered.
	buf: rawptr,
	// elem_size is the size of one element in bytes.
	elem_size: u16,
	// closed is non-zero once close_chan has run.
	closed: u32,
	// sendx / recvx are the ring buffer's send and receive cursors.
	sendx: uint,
	recvx: uint,
	// recvq / sendq hold goroutines blocked on receive and on send.
	recvq: Waitq,
	sendq: Waitq,
	// lock serializes every operation on this channel. Per Go it is also held
	// briefly by the runtime while parking/readying a goroutine on the channel.
	lock: sync.Mutex,
}

// waitq_enqueue appends sgp to the back of q. Mirrors (*waitq).enqueue (chan.go).
@(private)
waitq_enqueue :: proc(q: ^Waitq, sgp: ^Sudog) {
	sgp.next = nil
	x := q.last
	if x == nil {
		sgp.prev = nil
		q.first = sgp
		q.last = sgp
		return
	}
	sgp.prev = x
	x.next = sgp
	q.last = sgp
}

// waitq_dequeue removes and returns the Sudog at the front of q, or nil if empty.
// Mirrors (*waitq).dequeue (chan.go).
//
// DEVIATION: Go's dequeue loops, skipping any Sudog whose goroutine already lost
// a select wake race (sgp.isSelect + a g.selectDone CAS). bifrost has no select
// yet (Phase 7), so isSelect is always false and that branch — together with the
// surrounding for loop — is omitted; Phase 7 reinstates it.
@(private)
waitq_dequeue :: proc(q: ^Waitq) -> ^Sudog {
	sgp := q.first
	if sgp == nil {
		return nil
	}
	y := sgp.next
	if y == nil {
		q.first = nil
		q.last = nil
	} else {
		y.prev = nil
		q.first = y
		sgp.next = nil // mark as removed
	}
	return sgp
}

// make_chan creates a channel carrying elem_size-byte elements with the given
// buffer capacity (0 = unbuffered/synchronous). It returns a ready-to-use
// ^Hchan; pair it with destroy_chan to release it. Mirrors makechan (chan.go).
//
// Like Go, the header and the ring buffer are one allocation: buf points just
// past the header. DEVIATION: bifrost copies elements as raw bytes (no element
// type), so there is no pointer/no-pointer split — every channel takes the
// single-block path, and the buffer base is header-aligned (8), which suffices
// for the byte-wise copies send/recv use.
make_chan :: proc(elem_size: int, capacity: int, allocator := context.allocator) -> ^Hchan {
	assert(elem_size >= 0, "make_chan: negative element size")
	assert(elem_size < 1 << 16, "make_chan: element size too large")
	assert(capacity >= 0, "make_chan: negative capacity")

	buf_bytes := elem_size * capacity
	block, err := mem.alloc_bytes(size_of(Hchan) + buf_bytes, align_of(Hchan), allocator)
	if err != .None {
		panic("make_chan: allocation failed")
	}

	c := cast(^Hchan)raw_data(block) // block is zeroed, so all fields start clear
	c.elem_size = u16(elem_size)
	c.dataqsiz = uint(capacity)
	if buf_bytes > 0 {
		c.buf = rawptr(uintptr(c) + uintptr(size_of(Hchan)))
	}
	return c
}

// destroy_chan frees a channel created by make_chan. The buffer shares the
// header's allocation, so this is a single free. The caller must ensure no
// goroutine is still blocked on the channel (close_chan + drain first); bifrost
// has no GC to reclaim it otherwise.
destroy_chan :: proc(c: ^Hchan, allocator := context.allocator) {
	if c == nil {
		return
	}
	free(c, allocator)
}

// close_chan marks the channel closed. Shell for Phase 6.2: it sets the closed
// flag under the lock and rejects nil/double close. Waking blocked senders and
// receivers is Phase 6.5 — until send/recv (6.3/6.4) land, no goroutine can be
// queued, so there is nothing to wake yet. Mirrors closechan (chan.go).
close_chan :: proc(c: ^Hchan) {
	if c == nil {
		panic("close of nil channel")
	}
	sync.lock(&c.lock)
	defer sync.unlock(&c.lock)
	if c.closed != 0 {
		panic("close of closed channel")
	}
	c.closed = 1
	// TODO(phase 6.5): release every sudog on sendq (each panics on resume) and
	// recvq (each receives the zero value with ok=false), then goready them.
}
