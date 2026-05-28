package bifrost

import "core:testing"

// Phase 2 acceptance test (PLAN 2.5): two coroutines on two independent stacks
// ping-pong control back and forth via the context-switch primitives, each
// incrementing its own counter. Proves gogo / gosave_switch / setup_context
// save and restore execution state correctly, including callee-saved registers.

@(private = "file")
Ping_Pong :: struct {
	main_buf: Gobuf, // the test's own context; fibers gogo here when done
	a_buf:    Gobuf,
	b_buf:    Gobuf,
	count_a:  int,
	count_b:  int,
	iters:    int,
}

// File-global so the contextless fiber entries (which take no arguments) can
// reach the shared state.
@(private = "file")
pp: Ping_Pong

@(private = "file")
fiber_a :: proc "contextless" () {
	for {
		pp.count_a += 1
		if pp.count_a >= pp.iters {
			gogo(&pp.main_buf) // done: hand control back to the test
		}
		gosave_switch(&pp.a_buf, &pp.b_buf) // yield to B, save A
	}
}

@(private = "file")
fiber_b :: proc "contextless" () {
	for {
		pp.count_b += 1
		gosave_switch(&pp.b_buf, &pp.a_buf) // yield to A, save B
	}
}

@(test)
test_context_switch_ping_pong :: proc(t: ^testing.T) {
	stack_a := make([]u8, 64 * 1024)
	stack_b := make([]u8, 64 * 1024)
	defer delete(stack_a)
	defer delete(stack_b)

	pp = Ping_Pong {
		iters = 1000,
	}
	setup_context(&pp.a_buf, cast(rawptr)fiber_a, stack_a)
	setup_context(&pp.b_buf, cast(rawptr)fiber_b, stack_b)

	// Save the test's context and run A. A returns control here via
	// gogo(&main_buf) once it has incremented iters times.
	gosave_switch(&pp.main_buf, &pp.a_buf)

	testing.expectf(t, pp.count_a == pp.iters, "count_a = %d, want %d", pp.count_a, pp.iters)
	testing.expectf(t, pp.count_b == pp.iters - 1, "count_b = %d, want %d", pp.count_b, pp.iters - 1)
}
