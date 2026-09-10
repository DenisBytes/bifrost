package bifrost

import "base:intrinsics"
import "core:sync"

// Phase 8.1: runtime semaphore. sema_acquire blocks on a user-provided u32
// counter until it is non-zero, then atomically decrements; sema_release
// atomically increments and wakes one waiter. Mutex / WaitGroup / Once
// (Phase 8.2-8.4) build on these. Mirrors sema.go (semacquire/semrelease,
// semaRoot).
//
// The missed-wakeup dance is the core of the design:
//   - sema_acquire: take root.lock, INCREMENT nwait, then recheck cansemacquire.
//     The recheck-while-locked guarantees that any concurrent sema_release that
//     publishes the +1 increment also observes nwait > 0 and waits for our lock.
//   - sema_release: atomically INCREMENT *addr, THEN load nwait. Publishing the
//     permit before observing nwait is the mirror invariant — together they
//     guarantee no acquirer parks holding a permit it could have consumed, and
//     no releaser walks away from a waiter it should have woken.

// SEMA_TABLE_SIZE shards waiter state across this many roots, hashed by addr.
// DEVIATION from Go's 251: bifrost has few sync primitives in play; 31 is a
// small prime, easy to tune up if contention shows.
@(private)
SEMA_TABLE_SIZE :: 31

// Sema_Root is one bucket of the semaphore hash table: a FIFO queue of Sudogs
// (each tagged with its addr in Sudog.elem) plus the count of currently-queued
// waiters. DEVIATION from Go: Go organises a Sema_Root's waiters as a treap
// keyed by addr (each addr's Sudogs threaded via waitlink); bifrost uses a
// single FIFO list and a linear scan to match addr. O(n) where n is the
// bucket's queue depth — fine for sync's typical low concurrency.
@(private)
Sema_Root :: struct {
	lock:  sync.Mutex,
	head:  ^Sudog,
	tail:  ^Sudog,
	nwait: u32, // atomic; read without the lock by sema_release's fast path
}

@(private)
sema_table: [SEMA_TABLE_SIZE]Sema_Root

// sema_root_for hashes addr to its bucket, mirroring Go's semTable.rootFor
// (sema.go:56): `(uintptr(addr) >> 3) % semTabSize`.
//
// The >> 3 drops the three always-zero low bits of the 8-byte-aligned addresses
// Go hashes. NOTE, because an earlier version of this comment had the reasoning
// backwards: the shift does not improve spread for 4-byte-spaced addresses, it
// WORSENS it. bifrost's Mutex is a bare u32, so two Mutexes 4 bytes apart — an
// array of them, or adjacent struct fields — hash to the same root in pairs.
// That is a contention concern, not a correctness one: the root's FIFO matches
// waiters by addr, so a collision only means sharing a lock.
@(private)
sema_root_for :: proc "contextless" (addr: ^u32) -> ^Sema_Root {
	return &sema_table[(uintptr(addr) >> 3) % SEMA_TABLE_SIZE]
}

// cansemacquire atomically decrements *addr from any non-zero value; returns
// true on success, false if *addr is already 0. Mirrors cansemacquire
// (sema.go:291).
@(private)
cansemacquire :: proc "contextless" (addr: ^u32) -> bool {
	for {
		v := intrinsics.atomic_load(addr)
		if v == 0 {
			return false
		}
		_, ok := intrinsics.atomic_compare_exchange_strong(addr, v, v - 1)
		if ok {
			return true
		}
	}
}

// sema_park_commit is the gopark unlock callback for sema_acquire: it runs on g0
// after the goroutine is _Gwaiting and releases the Sema_Root lock the acquirer
// held while enqueueing. Structurally identical to chanparkcommit.
@(private)
sema_park_commit :: proc "c" (gp: ^G, lock: rawptr) -> bool {
	sync.unlock(cast(^sync.Mutex)lock)
	return true
}

// sema_queue appends s to root's FIFO list, tagged with addr in s.elem. Caller
// holds root.lock.
@(private)
sema_queue :: proc(root: ^Sema_Root, addr: ^u32, s: ^Sudog) {
	s.elem = rawptr(addr)
	s.waitlink = nil
	if root.tail == nil {
		root.head = s
	} else {
		root.tail.waitlink = s
	}
	root.tail = s
}

// sema_dequeue removes and returns the oldest Sudog waiting on addr in this
// root, or nil. Clears s.elem and s.waitlink on the dequeued sudog so it is
// release-ready. Caller holds root.lock.
@(private)
sema_dequeue :: proc(root: ^Sema_Root, addr: ^u32) -> ^Sudog {
	prev: ^Sudog
	for s := root.head; s != nil; s = s.waitlink {
		if s.elem == rawptr(addr) {
			next := s.waitlink
			if prev == nil {
				root.head = next
			} else {
				prev.waitlink = next
			}
			if root.tail == s {
				root.tail = prev
			}
			s.waitlink = nil
			s.elem = nil
			return s
		}
		prev = s
	}
	return nil
}

// sema_acquire blocks until *addr > 0 and atomically decrements it. Cheap when
// uncontended (a single CAS); the slow path enqueues a Sudog and parks.
// Mirrors semacquire1 (sema.go:146).
//
// PRECONDITION: must be called from inside a goroutine started with go_, while
// run() is active. Calling it from the thread that runs run(), or from a thread
// bifrost did not create, panics with a diagnostic rather than faulting (mcall).
sema_acquire :: proc(addr: ^u32) {
	// Easy case: a permit is already available; no lock, no sudog, no park.
	if cansemacquire(addr) {
		return
	}
	// Slow path: acquire a sudog and enter the queue-or-retry loop. The current
	// G doesn't migrate mid-call (cooperative; no preemption inside this proc),
	// so s.g is set once and stays valid across re-enqueues.
	s := acquire_sudog()
	s.g = getg()
	root := sema_root_for(addr)
	for {
		sync.lock(&root.lock)
		// Make our queue intent visible BEFORE rechecking cansemacquire. Any
		// concurrent sema_release that follows now sees nwait > 0 and will block
		// on root.lock instead of skipping the wake.
		intrinsics.atomic_add(&root.nwait, u32(1))
		if cansemacquire(addr) {
			intrinsics.atomic_add(&root.nwait, ~u32(0)) // -1 (two's-complement wrap)
			sync.unlock(&root.lock)
			break
		}
		sema_queue(root, addr, s)
		gopark(sema_park_commit, &root.lock, .Sema_Acquire)
		// Resumed: sema_release dequeued s (so s.elem/waitlink were cleared
		// under the lock). Another acquirer may have raced us to the permit, so
		// loop: re-take the lock, re-increment nwait, recheck cansemacquire.
		// DEVIATION from sema.go:193: Go also checks `s.ticket != 0` for direct
		// handoff (sema.go:260, `semrelease1(handoff=true)`). bifrost omits the
		// ticket path — there is no anti-starvation regime yet, so a newly
		// arrived easy-path acquirer can race a just-woken waiter for the permit;
		// the retry handles it for correctness. Fairness/starvation is deferred.
		if cansemacquire(addr) {
			break
		}
	}
	release_sudog(s)
}

// sema_release atomically increments *addr and wakes one waiter (if any).
// Mirrors semrelease1 (sema.go:207).
sema_release :: proc(addr: ^u32) {
	// Publish the +1 BEFORE checking nwait. The pair (xadd-before-nwait load /
	// nwait++-before-recheck-cansemacquire in the acquirer) is what closes the
	// missed-wake window without a global lock.
	intrinsics.atomic_add(addr, u32(1))
	root := sema_root_for(addr)
	if intrinsics.atomic_load(&root.nwait) == u32(0) {
		return // fast path: no waiters
	}
	sync.lock(&root.lock)
	if intrinsics.atomic_load(&root.nwait) == u32(0) {
		// Another acquirer claimed the permit between the load and the lock —
		// nothing to do.
		sync.unlock(&root.lock)
		return
	}
	s := sema_dequeue(root, addr)
	if s != nil {
		intrinsics.atomic_add(&root.nwait, ~u32(0)) // -1 (two's-complement wrap)
	}
	sync.unlock(&root.lock)
	if s != nil {
		// goready takes scheduler locks; do it after we drop root.lock.
		goready(s.g)
	}
}
