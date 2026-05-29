package bifrost

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
