package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.1 integration: stress the runtime semaphore across multiple OS
// threads, where the missed-wakeup window the xadd/nwait dance closes is
// actually exercised.

@(private = "file")
SEMA_INT_N :: 5000

@(private = "file")
sema_int_addr: u32

@(private = "file")
sema_int_counter: i64

@(private = "file")
sema_int_worker :: proc(arg: rawptr) {
	sema_acquire(&sema_int_addr) // enter critical section
	intrinsics.atomic_add(&sema_int_counter, 1)
	sema_release(&sema_int_addr) // leave
}

// Binary semaphore as a mutex on 4 OS threads. Every goroutine increments the
// shared counter while holding the sema, so the exact count proves both
// mutual exclusion and that no acquirer was left stranded.
@(test)
test_integration_sema_mutex_contention :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	sema_int_addr = 1
	sema_int_counter = 0
	for _ in 0 ..< SEMA_INT_N {
		go_(sema_int_worker)
	}
	run()

	testing.expectf(t, sema_int_counter == SEMA_INT_N, "count = %d, want %d", sema_int_counter, SEMA_INT_N)
	testing.expectf(t, sema_int_addr == 1, "addr = %d, want 1 (mutex released)", sema_int_addr)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

// Counting semaphore with concurrent producers (release) and consumers
// (acquire) on 4 OS threads. Symmetric counts must balance: every release
// satisfies exactly one acquire, so all consumers complete.
@(private = "file")
SEMA_PC_N :: 2000

@(private = "file")
sema_pc_addr: u32

@(private = "file")
sema_pc_consumed: i64

@(private = "file")
sema_pc_consumer :: proc(arg: rawptr) {
	sema_acquire(&sema_pc_addr)
	intrinsics.atomic_add(&sema_pc_consumed, 1)
}

@(private = "file")
sema_pc_producer :: proc(arg: rawptr) {
	sema_release(&sema_pc_addr)
}

@(test)
test_integration_sema_producer_consumer :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()

	sema_pc_addr = 0
	sema_pc_consumed = 0
	for _ in 0 ..< SEMA_PC_N {
		go_(sema_pc_consumer) // many will park (addr starts at 0)
	}
	for _ in 0 ..< SEMA_PC_N {
		go_(sema_pc_producer) // each release wakes one
	}
	run()

	testing.expectf(t, sema_pc_consumed == SEMA_PC_N, "consumed = %d, want %d", sema_pc_consumed, SEMA_PC_N)
	testing.expectf(t, sema_pc_addr == 0, "addr = %d, want 0 (balanced)", sema_pc_addr)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
