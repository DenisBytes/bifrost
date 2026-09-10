package bifrost

import "base:intrinsics"
import "core:mem"
import "core:sync"

// select: bifrost's port of Go's select.go. Go's selectgo is driven by the
// compiler (which lays out the scase array and order scratch); bifrost has no
// such support, so the public select_ takes an explicit slice of Select_Op
// (like reflect.rselect) and allocates the poll/lock order scratch itself.
//
// The algorithm (selectgo) is unchanged from Go: randomize a poll order for
// fairness, sort a lock order by channel address to avoid lock-ordering
// deadlock, lock all channels, then
//   pass 1 - if any case is already ready, complete it and return;
//   pass 2 - otherwise enqueue a Sudog on every case and park;
//   pass 3 - on wake, find the case that fired and dequeue the losers.
// Every divergence from Go is noted at its site.

// Select_Dir is the direction of a select case.
Select_Dir :: enum u8 {
	Recv, // case v = <-c
	Send, // case c <- v
}

// Select_Op describes one case of a select: the channel, the element pointer
// (source for a send, destination for a receive; nil to discard a received
// value), and the direction. A nil channel is never ready and is skipped (it
// can never be selected), matching a nil channel in a Go select.
Select_Op :: struct {
	c:    ^Hchan,
	elem: rawptr,
	dir:  Select_Dir,
}

// sellock locks every distinct channel in lock order. lockorder is sorted by
// channel address, so duplicate channels are adjacent and each is locked once.
// Mirrors sellock (select.go:34).
@(private)
sellock :: proc(ops: []Select_Op, lockorder: []int) {
	last: ^Hchan
	for o in lockorder {
		c := ops[o].c
		if c != last {
			sync.lock(&c.lock)
			last = c
		}
	}
}

// selunlock unlocks every distinct channel, in reverse lock order. A channel
// equal to the previous (i-1) entry is skipped now and unlocked when that entry
// is reached. Mirrors selunlock (select.go:45). Touch nothing after the last
// unlock: once unlocked, a woken peer may free state out from under us.
@(private)
selunlock :: proc(ops: []Select_Op, lockorder: []int) {
	for i := len(lockorder) - 1; i >= 0; i -= 1 {
		c := ops[lockorder[i]].c
		if i > 0 && c == ops[lockorder[i - 1]].c {
			continue
		}
		sync.unlock(&c.lock)
	}
}

// selparkcommit is the gopark callback for a blocked select: it runs on g0 once
// the goroutine is _Gwaiting and unlocks every channel the select holds, walking
// gp.waiting (built in lock order, so duplicates are adjacent). Mirrors
// selparkcommit (select.go:63). The lock arg is unused (Go passes nil).
@(private)
selparkcommit :: proc "c" (gp: ^G, lock: rawptr) -> bool {
	lastc: ^Hchan
	for sg := gp.waiting; sg != nil; sg = sg.waitlink {
		if sg.c != lastc && lastc != nil {
			sync.unlock(&lastc.lock)
		}
		lastc = sg.c
	}
	if lastc != nil {
		sync.unlock(&lastc.lock)
	}
	return true
}

// dequeue_sudog removes a specific Sudog from q, handling the "already removed"
// case (a losing waker may have unlinked it during the select wake race).
// Mirrors (*waitq).dequeueSudoG (select.go:627).
@(private)
dequeue_sudog :: proc(q: ^Waitq, sgp: ^Sudog) {
	x := sgp.prev
	y := sgp.next
	defer {
		// Defensively clear both links on every return: the acquire_sudog
		// symmetric asserts now require it by construction, not by case-position
		// invariant (e.g. the already-removed case used to leave both untouched).
		sgp.next = nil
		sgp.prev = nil
	}
	if x != nil {
		if y != nil {
			x.next = y
			y.prev = x
			return
		}
		x.next = nil
		q.last = x
		return
	}
	if y != nil {
		y.prev = nil
		q.first = y
		return
	}
	// x == y == nil: sgp is either the only element or was already removed.
	if q.first == sgp {
		q.first = nil
		q.last = nil
	}
}

// select_build_lockorder fills lockorder with the cases named by pollorder,
// sorted ascending by channel address. Ports Go's in-place heap sort
// (select.go:205-238): n log n with a constant stack footprint, seeded from
// pollorder so that cases on the same channel keep poll order.
//
// It replaced an insertion sort, which was O(n^2) — an 8192-case select burned
// roughly 15 ms of CPU per call building the order alone.
//
// TWO PROPERTIES ARE LOAD-BEARING here, not just the sortedness:
//  1. A total order by address is what makes taking the locks in this order
//     deadlock-free against any other select over the same channels.
//  2. Duplicate channels must end up ADJACENT, because sellock and selunlock
//     each lock a channel exactly once by skipping an entry equal to its
//     neighbour. A sort that scattered duplicates would double-lock a channel
//     (a hang) or leave one held on return.
//
// Factored out of select_ so both properties can be tested directly.
@(private)
select_build_lockorder :: proc(ops: []Select_Op, pollorder, lockorder: []int) {
	norder := len(pollorder)

	// Phase 1: sift each pollorder entry up into a max-heap keyed by address.
	for i in 0 ..< norder {
		j := i
		c := uintptr(ops[pollorder[i]].c)
		for j > 0 && uintptr(ops[lockorder[(j - 1) / 2]].c) < c {
			k := (j - 1) / 2
			lockorder[j] = lockorder[k]
			j = k
		}
		lockorder[j] = pollorder[i]
	}

	// Phase 2: repeatedly move the max to the end, leaving ascending order.
	for i := norder - 1; i >= 0; i -= 1 {
		o := lockorder[i]
		c := uintptr(ops[o].c)
		lockorder[i] = lockorder[0]
		j := 0
		for {
			k := j * 2 + 1
			if k >= i {
				break
			}
			if k + 1 < i && uintptr(ops[lockorder[k]].c) < uintptr(ops[lockorder[k + 1]].c) {
				k += 1
			}
			if c < uintptr(ops[lockorder[k]].c) {
				lockorder[j] = lockorder[k]
				j = k
				continue
			}
			break
		}
		lockorder[j] = o
	}
}

// select_ runs a select over ops. With block=true it returns once a case
// completes (or panics on send to a closed channel); with block=false it returns
// chosen=-1 if no case was ready (the `default` case). chosen is the index into
// ops of the case that ran; recv_ok reports, for a receive, whether a value was
// received (false if the channel was closed). Mirrors selectgo (select.go:122),
// reduced: no race detector, timers, profiling, or synctest.
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
select_ :: proc(ops: []Select_Op, block: bool) -> (chosen: int, recv_ok: bool) {
	gp := getg()
	ncases := len(ops)

	if ncases == 0 {
		if !block {
			return -1, false
		}
		gopark(nil, nil, .Select_No_Cases) // blocks forever
		panic("select_: unreachable")
	}

	// Order scratch. DEVIATION: Go's compiler supplies these arrays; bifrost
	// allocates them from the (malloc-backed, thread-safe) goroutine context and
	// frees them on return. They outlive a pass-2 park (heap, not stack).
	alloc := context.allocator
	pollorder := make([]int, ncases, alloc)
	defer delete(pollorder, alloc)
	lockorder := make([]int, ncases, alloc)
	defer delete(lockorder, alloc)

	// Poll order: a random permutation of the cases that have a channel (nil
	// channels are omitted — never ready, never blocked on).
	norder := 0
	for i in 0 ..< ncases {
		if ops[i].c == nil {
			continue
		}
		j := int(fastrand() % u32(norder + 1))
		pollorder[norder] = pollorder[j]
		pollorder[j] = i
		norder += 1
	}
	pollorder = pollorder[:norder]
	lockorder = lockorder[:norder]

	// Lock order: the same cases sorted by channel address.
	select_build_lockorder(ops, pollorder, lockorder)

	sellock(ops, lockorder)

	// Pass 1: look for a case that can proceed immediately.
	for o in pollorder {
		cas := &ops[o]
		c := cas.c
		if cas.dir == .Recv {
			if sg := waitq_dequeue(&c.sendq); sg != nil {
				chan_recv_elem(c, sg, cas.elem) // from a waiting sender
				selunlock(ops, lockorder)
				wake_ready(sg)
				return o, true
			}
			if c.qcount > 0 {
				if cas.elem != nil {
					mem.copy(cas.elem, chan_buf_slot(c, c.recvx), int(c.elem_size))
				}
				c.recvx += 1
				if c.recvx == c.dataqsiz {
					c.recvx = 0
				}
				c.qcount -= 1
				selunlock(ops, lockorder)
				return o, true
			}
			if c.closed != 0 {
				selunlock(ops, lockorder)
				if cas.elem != nil {
					mem.zero(cas.elem, int(c.elem_size))
				}
				return o, false
			}
		} else {
			if c.closed != 0 {
				selunlock(ops, lockorder)
				panic("send on closed channel")
			}
			if sg := waitq_dequeue(&c.recvq); sg != nil {
				chan_send_elem(c, sg, cas.elem) // to a waiting receiver
				selunlock(ops, lockorder)
				wake_ready(sg)
				return o, false
			}
			if c.qcount < c.dataqsiz {
				mem.copy(chan_buf_slot(c, c.sendx), cas.elem, int(c.elem_size))
				c.sendx += 1
				if c.sendx == c.dataqsiz {
					c.sendx = 0
				}
				c.qcount += 1
				selunlock(ops, lockorder)
				return o, false
			}
		}
	}

	if !block {
		selunlock(ops, lockorder)
		return -1, false
	}

	// Pass 2: nothing ready — enqueue a Sudog on every case (in lock order) and
	// park. select_done is reset first; a waker wins the right to resume us by
	// CAS'ing it 0->1 (see waitq_dequeue).
	gp.param = nil
	intrinsics.atomic_store(&gp.select_done, u32(0))
	if gp.waiting != nil {
		panic("select_: gp.waiting not nil entering park") // a leaked sudog list
	}
	nextp := &gp.waiting
	for o in lockorder {
		cas := &ops[o]
		c := cas.c
		sg := acquire_sudog()
		sg.g = gp
		sg.isSelect = true
		sg.elem = cas.elem
		sg.c = c
		nextp^ = sg // link onto gp.waiting in lock order
		nextp = &sg.waitlink
		if cas.dir == .Send {
			waitq_enqueue(&c.sendq, sg)
		} else {
			waitq_enqueue(&c.recvq, sg)
		}
	}
	nextp^ = nil // terminate the waiting list

	gopark(selparkcommit, nil, .Select)

	// Resumed: re-lock all channels and identify the winner (set by the waker).
	sellock(ops, lockorder)
	intrinsics.atomic_store(&gp.select_done, u32(0))
	won := cast(^Sudog)gp.param
	gp.param = nil

	// Pass 3: walk gp.waiting (lock order) alongside lockorder. Clear per-Sudog
	// state first, then for each: the winner was already dequeued by its waker
	// (just record it); every loser is still enqueued and must be removed.
	for sg1 := gp.waiting; sg1 != nil; sg1 = sg1.waitlink {
		sg1.isSelect = false
		sg1.elem = nil
		sg1.c = nil
	}
	casi := -1
	success := false
	sglist := gp.waiting
	gp.waiting = nil
	for o in lockorder {
		cas := &ops[o]
		if sglist == won {
			casi = o
			success = sglist.success
		} else {
			if cas.dir == .Send {
				dequeue_sudog(&cas.c.sendq, sglist)
			} else {
				dequeue_sudog(&cas.c.recvq, sglist)
			}
		}
		sgnext := sglist.waitlink
		sglist.waitlink = nil
		release_sudog(sglist)
		sglist = sgnext
	}

	if casi == -1 {
		panic("select_: woken with no completed case")
	}

	won_op := &ops[casi]
	selunlock(ops, lockorder)
	if won_op.dir == .Send {
		if !success {
			panic("send on closed channel")
		}
		return casi, false
	}
	return casi, success
}
