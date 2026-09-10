package bifrost

import "base:intrinsics"
import "core:sync"

// Phase 8.6: Cond — a condition variable associated with a Mutex, built on a
// ticket-based notify list. Mirrors sync.Cond (src/sync/cond.go:21) over the
// runtime's notifyList (src/runtime/sema.go:544-700).
//
// USAGE CONTRACT (the predicate idiom, identical to sync.Cond):
//   mutex_lock(m)
//   for !predicate {
//       cond_wait(c, m)
//   }
//   ... act on the predicate ...
//   mutex_unlock(m)
//
// The caller MUST hold the mutex when calling cond_wait; it is released inside
// wait and re-acquired before return. The PREDICATE must always be mutated
// while holding the same mutex the waiters use — that is what closes the
// signal-before-wait race, because a late waiter sees the new value during its
// under-mutex check and never parks.
//
// WHY TICKETS, NOT A COUNTING SEMAPHORE (this is the whole design):
// bifrost's first Cond parked waiters on a counting u32 semaphore. That makes a
// permit ANONYMOUS, so a goroutine that *entered* cond_wait after a signal
// could consume the permit released for an already-parked waiter and then park
// itself. The original waiter was never woken, and a textbook predicate-loop
// program deadlocked deterministically — a two-goroutine ping-pong died 3/3 at
// gomaxprocs=1, and cond_broadcast (the remedy Go's own documentation
// prescribes) died identically. That was a lost wakeup, not the mere
// unfairness the old comment claimed.
//
// Tickets close it: cond_wait takes a monotonically increasing ticket BEFORE
// releasing the mutex, and parks only if the notify cursor has not already
// passed that ticket. A notification can therefore only ever be consumed by a
// waiter that registered before it was issued.
//
// DEVIATIONS from sync.Cond:
//   - No copy-protection. Go's Cond embeds a noCopy that `go vet` flags; Odin
//     has no equivalent check, so copying a Cond after first use is undetected
//     caller error.
//   - Requires cond_init. Go's Cond is usable as soon as its L is set; bifrost's
//     ticket cursors and list must start zeroed, and the Mutex it is paired with
//     is not zero-value-usable either (see mutex.odin).

Cond :: struct {
	// wait is the ticket number of the next waiter, incremented atomically
	// OUTSIDE the lock — Go's notifyListAdd is a bare atomic add, so taking a
	// ticket never serialises against other waiters.
	wait: u32,
	// notify is the ticket number of the next waiter to be notified. Read
	// without the lock on the fast paths, written only under it. Mirrors
	// notifyList.notify (sema.go:553).
	//
	// wait and notify both wrap, and that is handled correctly as long as their
	// unwrapped difference stays below 2^31 — which would need 2^31 waiters on
	// one Cond. See cond_ticket_less.
	notify: u32,
	// lock guards head/tail and the write side of notify.
	lock: sync.Mutex,
	// head/tail are the FIFO list of parked waiters, threaded through
	// Sudog.waitlink.
	//
	// DEVIATION: Go threads its notifyList through sudog.next; bifrost uses
	// waitlink because next/prev are the channel Waitq links and release_sudog
	// asserts both are nil. sema.odin makes the same choice for the same reason.
	head: ^Sudog,
	tail: ^Sudog,
}

// cond_init prepares c for use. Must be called before any wait/signal/broadcast.
cond_init :: proc(c: ^Cond) {
	c^ = {}
}

// cond_ticket_less reports whether ticket a precedes ticket b, tolerating u32
// wraparound. Mirrors `less` (sema.go:568).
@(private)
cond_ticket_less :: proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) < 0
}

// cond_park_commit is the gopark unlock callback for cond_wait: it runs on g0
// once the goroutine is safely _Gwaiting and releases the Cond lock the waiter
// held while enqueueing. Structurally identical to chanparkcommit and
// sema_park_commit.
@(private)
cond_park_commit :: proc "c" (gp: ^G, lock: rawptr) -> bool {
	sync.unlock(cast(^sync.Mutex)lock)
	return true
}

// cond_wait atomically releases m and parks until cond_signal or cond_broadcast
// wakes us, then re-acquires m. Caller MUST hold m on entry. Mirrors
// (*Cond).Wait (sync/cond.go:70) over notifyListAdd/notifyListWait
// (sema.go:576 / :585).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
cond_wait :: proc(c: ^Cond, m: ^Mutex) {
	// Take a ticket before releasing the mutex. Everything after this is ordered
	// against that ticket, so a signal issued once the mutex is free cannot be
	// absorbed by a goroutine that has not yet taken one. atomic_add returns the
	// value BEFORE adding, which is exactly our ticket (Go: `l.wait.Add(1) - 1`).
	t := intrinsics.atomic_add(&c.wait, u32(1))
	mutex_unlock(m)
	cond_notify_wait(c, t)
	mutex_lock(m)
}

// cond_notify_wait parks until ticket t is notified, or returns immediately if
// it already has been. Mirrors notifyListWait (sema.go:585).
@(private)
cond_notify_wait :: proc(c: ^Cond, t: u32) {
	sync.lock(&c.lock)

	// Return right away if this ticket has already been notified. This is the
	// case a counting semaphore cannot express: the notification was aimed at
	// US, was issued while we were between taking the ticket and reaching this
	// lock, and is ours alone to consume.
	if cond_ticket_less(t, intrinsics.atomic_load(&c.notify)) {
		sync.unlock(&c.lock)
		return
	}

	s := acquire_sudog()
	s.g = getg()
	s.ticket = t
	s.waitlink = nil
	if c.tail == nil {
		c.head = s
	} else {
		c.tail.waitlink = s
	}
	c.tail = s

	// cond_park_commit releases c.lock on g0, once we are safely _Gwaiting.
	gopark(cond_park_commit, &c.lock, .Cond_Wait)

	// Resumed: the notifier unlinked us and cleared waitlink/ticket under
	// c.lock, so the sudog is fully detached and release_sudog's assertions hold.
	release_sudog(s)
}

// cond_signal wakes the OLDEST unnotified waiter, if any. Mirrors
// (*Cond).Signal (sync/cond.go:85) over notifyListNotifyOne (sema.go:665).
//
// Safe to call with or without the caller's mutex held: correctness rests on the
// predicate being mutated under that mutex, not on where the signal is issued.
cond_signal :: proc(c: ^Cond) {
	// Fast path: no waiter has taken a ticket since the last notification, so
	// there is nothing to wake and no reason to touch the lock.
	if intrinsics.atomic_load(&c.wait) == intrinsics.atomic_load(&c.notify) {
		return
	}

	sync.lock(&c.lock)
	t := c.notify
	if t == intrinsics.atomic_load(&c.wait) { // re-check under the lock
		sync.unlock(&c.lock)
		return
	}
	intrinsics.atomic_store(&c.notify, t + 1)

	// Find the waiter holding exactly ticket t. It may not be at the head, and
	// it may not be in the list at all: a waiter that took ticket t but has not
	// yet reached cond_notify_wait's lock will observe the new notify cursor and
	// return without ever parking. Not finding it is therefore correct, not an
	// error — that goroutine has already been notified. This is precisely why
	// the cursor advances unconditionally rather than only on a successful
	// dequeue, and why popping the head would be wrong.
	prev: ^Sudog
	for s := c.head; s != nil; s = s.waitlink {
		if s.ticket == t {
			next := s.waitlink
			if prev == nil {
				c.head = next
			} else {
				prev.waitlink = next
			}
			if c.tail == s {
				c.tail = prev
			}
			s.waitlink = nil
			s.ticket = 0
			sync.unlock(&c.lock)
			goready(s.g) // goready takes scheduler locks; do it after the unlock
			return
		}
		prev = s
	}
	sync.unlock(&c.lock)
}

// cond_broadcast wakes every waiter that has taken a ticket so far. Mirrors
// (*Cond).Broadcast (sync/cond.go:96) over notifyListNotifyAll (sema.go:629).
//
// A waiter that takes its ticket after this call is not woken by it, which is
// correct: that waiter performs its predicate check under the caller's mutex and
// so observes the state this broadcast was announcing.
cond_broadcast :: proc(c: ^Cond) {
	if intrinsics.atomic_load(&c.wait) == intrinsics.atomic_load(&c.notify) {
		return
	}

	sync.lock(&c.lock)
	s := c.head
	c.head = nil
	c.tail = nil
	// Advance the cursor to the current ticket high-water mark. Every waiter not
	// in the detached list has either already been notified, or holds a ticket
	// below the new cursor and will notice that on reaching cond_notify_wait.
	intrinsics.atomic_store(&c.notify, intrinsics.atomic_load(&c.wait))
	sync.unlock(&c.lock)

	// Ready the detached list outside the lock.
	for s != nil {
		next := s.waitlink
		s.waitlink = nil
		s.ticket = 0
		goready(s.g)
		s = next
	}
}
