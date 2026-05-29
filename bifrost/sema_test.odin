package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 8.1 unit tests for the runtime semaphore: sema_acquire blocks until
// *addr > 0 and atomically decrements; sema_release increments and wakes one
// waiter. These drive the scheduler (the parked-then-woken path), so each test
// spawns goroutines and runs.

@(private = "file")
sem_addr: u32

@(private = "file")
sem_count: int

@(private = "file")
sem_done: bool

// --- pre-released: no parking -----------------------------------------------

@(private = "file")
sem_simple_acquire_worker :: proc(arg: rawptr) {
	sema_acquire(&sem_addr)
	sem_done = true
}

@(test)
test_sema_acquire_when_available :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	sem_addr = 1
	sem_done = false
	go_(sem_simple_acquire_worker)
	run()

	testing.expect(t, sem_done, "acquire should have completed")
	testing.expectf(t, sem_addr == 0, "addr = %d, want 0 after acquire", sem_addr)
}

// --- park then release wakes ------------------------------------------------

@(private = "file")
sem_consumer :: proc(arg: rawptr) {
	sema_acquire(&sem_addr)
	sem_done = true
}

@(private = "file")
sem_producer :: proc(arg: rawptr) {
	sema_release(&sem_addr)
}

@(test)
test_sema_acquire_waits_for_release :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	sem_addr = 0
	sem_done = false
	go_(sem_consumer) // parks (addr==0)
	go_(sem_producer) // release wakes the consumer
	run()

	testing.expect(t, sem_done, "consumer should have been woken by release")
	testing.expectf(t, sem_addr == 0, "addr = %d, want 0 (consumed by acquire)", sem_addr)
}

// --- counting semaphore: many parked acquirers, many releasers --------------

@(private = "file")
sem_count_acquirer :: proc(arg: rawptr) {
	sema_acquire(&sem_addr)
	sem_count += 1
}

@(private = "file")
sem_count_releaser :: proc(arg: rawptr) {
	sema_release(&sem_addr)
}

@(test)
test_sema_counting_match :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	sem_addr = 0
	sem_count = 0
	for _ in 0 ..< 3 {
		go_(sem_count_acquirer)
	}
	for _ in 0 ..< 3 {
		go_(sem_count_releaser)
	}
	run()

	testing.expectf(t, sem_count == 3, "completed acquirers = %d, want 3", sem_count)
	testing.expectf(t, sem_addr == 0, "addr = %d, want 0 (balanced)", sem_addr)
}

// --- mutex-like binary semaphore: contended critical section ----------------

@(private = "file")
sem_mutex_worker :: proc(arg: rawptr) {
	sema_acquire(&sem_addr) // enter critical section
	intrinsics.atomic_add(&sem_count, 1)
	sema_release(&sem_addr) // leave
}

@(test)
test_sema_binary_mutual_exclusion :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	sem_addr = 1 // binary semaphore (mutex)
	sem_count = 0
	for _ in 0 ..< 20 {
		go_(sem_mutex_worker)
	}
	run()

	testing.expectf(t, sem_count == 20, "count = %d, want 20", sem_count)
	testing.expectf(t, sem_addr == 1, "addr = %d, want 1 (mutex released)", sem_addr)
}
