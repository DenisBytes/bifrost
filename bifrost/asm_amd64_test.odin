package bifrost

import "core:testing"

// Phase 2 acceptance test (PLAN 2.5): two coroutines on two independent stacks
// ping-pong control back and forth via the context-switch primitives, each
// incrementing its own counter. Proves gogo / gosave_switch / setup_context
// save and restore execution state correctly.
//
// It does NOT prove callee-saved registers survive the switch, despite what this
// comment used to claim: both fibers are ordinary Odin frames, and the compiler
// emits its own save/restore for every callee-saved register a frame touches,
// which repairs a mismatched restore before the fiber can observe it. That
// property is covered by test_callee_saved_survive_context_switch at the bottom
// of this file, which keeps sentinels live across the switch from assembly.

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

// ---------------------------------------------------------------------------
// Callee-saved register preservation across a real context switch
// ---------------------------------------------------------------------------

@(private = "file")
cs_probe_self: Gobuf
@(private = "file")
cs_probe_peer: Gobuf
@(private = "file")
cs_probe_mask: u64
@(private = "file")
cs_probe_ran: bool

// cs_peer_entry runs on the peer stack. It immediately resumes the probe via
// gogo, which is the half of the round trip under test: gogo must pop exactly
// what gosave_switch pushed, in reverse.
@(private = "file")
cs_peer_entry :: proc "c" () {
	cs_probe_ran = true
	gogo(&cs_probe_self)
}

@(private = "file")
cs_names := [5]string{"rbx", "r12", "r13", "r14", "r15"}

@(test)
test_callee_saved_survive_context_switch :: proc(t: ^testing.T) {
	// The context switch is only correct if a suspended context's callee-saved
	// registers come back exactly as they went in — gogo's pops must be the
	// exact reverse of gosave_switch's pushes. An asymmetry there does not
	// crash: the resumed code simply continues with wrong register values, and
	// nothing else in the suite would notice.
	//
	// asm_amd64_test.odin's header has always claimed this coverage ("including
	// callee-saved registers"); the ping-pong above does not actually provide it,
	// because both fibers are Odin frames that save and restore those registers
	// themselves. This does, by keeping the sentinels live across the switch in
	// assembly with no Odin frame in between.
	stack, err := stack_alloc()
	testing.expectf(t, err == .None, "stack_alloc: %v", err)
	defer stack_free(stack)

	cs_probe_ran = false
	cs_probe_self = {}
	setup_context(&cs_probe_peer, cast(rawptr)cs_peer_entry, stack_to_bytes(stack))

	cs_probe_mask = callee_saved_switch_probe(&cs_probe_self, &cs_probe_peer)

	testing.expect(t, cs_probe_ran, "the peer context never ran")
	for i in 0 ..< 5 {
		testing.expectf(
			t,
			cs_probe_mask & (u64(1) << uint(i)) == 0,
			"callee-saved %s was clobbered across gosave_switch/gogo (mask=%5b)",
			cs_names[i],
			cs_probe_mask,
		)
	}
}
