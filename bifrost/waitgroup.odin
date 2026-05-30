package bifrost

import "base:intrinsics"

// Phase 8.3: WaitGroup tracks a count of in-flight goroutines; waitgroup_wait
// blocks until the count returns to 0. State is packed into one u64 — high 32
// bits are the i32 counter, low 32 bits are the u32 waiter count — and every
// transition is a CAS on the full word, so the classic lost-wakeup race between
// "add decrements counter to 0" and "wait registers as a waiter" is closed
// atomically by the single state word (no separate fields, no nested lock).
// Mirrors sync.WaitGroup (src/sync/waitgroup.go).
//
// DEVIATIONS from sync.WaitGroup:
//   - Slot widths: bifrost uses 32+32 bits (counter | waiters) for simplicity;
//     Go uses 32+32 too but in the opposite order under a different atomic.
//   - Reuse detection is best-effort: waitgroup_wait panics if it observes a
//     non-zero counter immediately after wake, but a Wait/Add interleaving that
//     completes between the wake and the load isn't caught. Go has a more
//     elaborate reuse guard; bifrost's is the simplest correct check.
//   - No "race detector" hooks (sync.WaitGroup integrates with Go's -race).

WaitGroup :: struct {
	state: u64, // hi 32 = i32 counter, lo 32 = u32 waiters
	sema:  u32,
}

// waitgroup_add adds delta to the counter; delta may be negative to decrement.
// Panics on a resulting negative counter. When the counter reaches 0 and there
// are queued waiters, every waiter is woken via sema_release before return.
waitgroup_add :: proc(wg: ^WaitGroup, delta: i32) {
	for {
		state := intrinsics.atomic_load(&wg.state)
		counter := i32(state >> 32)
		waiters := u32(state & 0xFFFFFFFF)
		new_counter := counter + delta
		// Overflow-safety invariant: u32(new_counter) is stored only after
		// new_counter >= 0 is checked here, so state>>32 is always in [0,
		// INT_MAX] and i32(state >> 32) is always non-negative on the next load.
		// Any i32 overflow in counter+delta therefore lands in the negative
		// range and is caught by this branch.
		if new_counter < 0 {
			panic("waitgroup_add: negative counter")
		}
		new_state: u64
		do_wake := false
		if new_counter == 0 && waiters > 0 {
			// We brought the counter to 0 with waiters queued: clear waiters
			// atomically as part of this CAS, then drain the sema below.
			new_state = 0
			do_wake = true
		} else {
			new_state = (u64(u32(new_counter)) << 32) | u64(waiters)
		}
		if _, ok := intrinsics.atomic_compare_exchange_strong(&wg.state, state, new_state); ok {
			if do_wake {
				for _ in 0 ..< waiters {
					sema_release(&wg.sema)
				}
			}
			return
		}
	}
}

// waitgroup_done decrements the counter by 1 — convenience for the common
// `defer waitgroup_done(&wg)` idiom.
waitgroup_done :: proc(wg: ^WaitGroup) {
	waitgroup_add(wg, -1)
}

// waitgroup_wait blocks until the counter is 0. Returns immediately if it is
// already 0. Panics if a fresh Add cycle slips in between the wake and the
// reuse check (best-effort detection).
waitgroup_wait :: proc(wg: ^WaitGroup) {
	for {
		state := intrinsics.atomic_load(&wg.state)
		counter := i32(state >> 32)
		waiters := u32(state & 0xFFFFFFFF)
		if counter == 0 {
			return
		}
		// Register atomically with the current counter snapshot: if the counter
		// changes (Add raced us), the CAS retries with the fresh value, so we
		// never sleep against a permit that was already drained.
		new_state := (u64(u32(counter)) << 32) | u64(waiters + 1)
		if _, ok := intrinsics.atomic_compare_exchange_strong(&wg.state, state, new_state); ok {
			sema_acquire(&wg.sema)
			// The waker set state to 0 as part of its draining CAS. A non-zero
			// counter here means another Add cycle began before we observed
			// completion — sync.WaitGroup forbids that pattern. Best-effort:
			// the check fires only when the next cycle landed before our load.
			if intrinsics.atomic_load(&wg.state) >> 32 != 0 {
				panic("waitgroup_wait: state>>32 != 0 after wake — caller began a new Add cycle before this Wait returned (forbidden; see sync.WaitGroup)")
			}
			return
		}
	}
}
