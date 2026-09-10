package bifrost

import "core:testing"

// ---------------------------------------------------------------------------
// Shared goroutine bodies (plain procs; state lives in file globals).
// ---------------------------------------------------------------------------

@(private = "file")
ran_flag: bool

@(private = "file")
set_flag :: proc(arg: rawptr) {
	ran_flag = true
}

@(private = "file")
counter: int

@(private = "file")
inc_and_yield :: proc(arg: rawptr) {
	counter += 1
	gosched()
}

// ---------------------------------------------------------------------------

@(test)
test_go_and_run_single :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	ran_flag = false
	go_(set_flag)
	run()

	testing.expect(t, ran_flag, "spawned goroutine did not run")
	testing.expectf(t, len(allgs) == 1, "allgs = %d, want 1", len(allgs))
	testing.expectf(t, g_status(allgs[0]) == .Dead, "goroutine status = %v, want Dead", g_status(allgs[0]))
}

// PLAN 4.7 acceptance: 1000 goroutines each increment a shared counter and
// yield; cooperative single-M scheduling means no data race, and all must run.
@(test)
test_thousand_goroutines_counter :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	counter = 0
	for _ in 0 ..< 1000 {
		go_(inc_and_yield)
	}
	run()

	testing.expectf(t, counter == 1000, "counter = %d, want 1000", counter)
	for gp in allgs {
		testing.expectf(t, g_status(gp) == .Dead, "goroutine %d not Dead: %v", gp.goid, g_status(gp))
	}
}

// gosched must actually interleave goroutines, not run one to completion first.
@(test)
test_gosched_interleaves :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	order := make([dynamic]int) // made in the test context so appends + delete match
	defer delete(order)
	interleave_order = &order

	go_(record_tag, rawptr(uintptr(1)))
	go_(record_tag, rawptr(uintptr(2)))
	run()

	testing.expectf(t, len(order) == 6, "len(order) = %d, want 6", len(order))
	if len(order) >= 2 {
		// First two entries come from different goroutines -> they interleaved.
		testing.expectf(t, order[0] == 1 && order[1] == 2, "order = %v, expected interleave starting 1,2", order)
	}
}

@(private = "file")
interleave_order: ^[dynamic]int

@(private = "file")
record_tag :: proc(arg: rawptr) {
	tag := int(uintptr(arg))
	for _ in 0 ..< 3 {
		append(interleave_order, tag)
		gosched()
	}
}

// gopark suspends a goroutine until another goroutine readies it.
@(private = "file")
park_target: ^G

@(private = "file")
park_resumed: bool

@(private = "file")
ready_ran: bool

@(private = "file")
parker :: proc(arg: rawptr) {
	park_target = getg()
	gopark(nil, nil, .None) // park unconditionally; resumed by goready
	park_resumed = true
}

@(private = "file")
readier :: proc(arg: rawptr) {
	if park_target != nil {
		goready(park_target)
	}
	ready_ran = true
}

@(test)
test_gopark_goready :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	park_target = nil
	park_resumed = false
	ready_ran = false

	go_(parker)
	go_(readier)
	run()

	testing.expect(t, ready_ran, "readier goroutine did not run")
	testing.expect(t, park_resumed, "parked goroutine never resumed after goready")
}

// Dead goroutines (with their stacks) are returned to the free list and reused
// by later go_ calls, so allgs does not grow across batches.
@(test)
test_goroutine_reuse :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()

	counter = 0
	for _ in 0 ..< 10 {
		go_(inc_and_yield)
	}
	run()
	first := len(allgs)

	for _ in 0 ..< 10 {
		go_(inc_and_yield)
	}
	run()
	second := len(allgs)

	testing.expectf(t, counter == 20, "counter = %d, want 20", counter)
	testing.expectf(t, first == 10, "first batch allgs = %d, want 10", first)
	testing.expectf(t, second == 10, "after reuse allgs = %d, want 10 (stacks should be reused)", second)
}

@(private = "file")
starve_respawns: int
@(private = "file")
starve_victim_resumed_at := -1
@(private = "file")
STARVE_LIMIT :: 5000

@(private = "file")
starve_victim :: proc(arg: rawptr) {
	gosched() // gosched_m -> globrunqput: the victim now lives on the GLOBAL queue
	starve_victim_resumed_at = starve_respawns
}

@(private = "file")
starve_respawner :: proc(arg: rawptr) {
	starve_respawns += 1
	if starve_respawns < STARVE_LIMIT {
		go_(starve_respawner) // runqput: stays on the LOCAL ring, forever
	}
}

@(test)
test_global_runq_fairness_poll :: proc(t: ^testing.T) {
	// Pins Go's 61-tick fairness poll (findRunnable, proc.go): "Check the global
	// runnable queue once in a while to ensure fairness. Otherwise two
	// goroutines can completely occupy the local runqueue by constantly
	// respawning each other."
	//
	// Without it, a goroutine that yields (and so lands on the GLOBAL queue)
	// starves behind a producer that keeps re-seeding the LOCAL ring, because
	// findrunnable reaches the global queue only once the local ring is empty.
	// At gomaxprocs == 1 no other M drains it, so the victim never runs.
	starve_respawns = 0
	starve_victim_resumed_at = -1
	runtime_init(1)
	defer runtime_teardown()
	go_(starve_victim)
	go_(starve_respawner)
	run()
	testing.expectf(
		t,
		starve_victim_resumed_at >= 0 && starve_victim_resumed_at < 200,
		"victim resumed after respawn #%d of %d; the 61-tick poll should resume it within ~61",
		starve_victim_resumed_at,
		STARVE_LIMIT,
	)
}

@(private = "file")
on_goroutine_observed: bool

@(private = "file")
check_on_goroutine :: proc(arg: rawptr) {
	on_goroutine_observed = on_goroutine()
}

@(test)
test_on_goroutine_predicate :: proc(t: ^testing.T) {
	// on_goroutine gates every blocking public API (see mcall). It must be false
	// on the thread that runs run() — that thread is m0 executing g0, and mcall
	// there would pass &g0.sched as both the save buffer and the destination
	// stack, with g0.sched.sp still 0 before run(): `mov rsp, 0` then `call`.
	//
	// The panic paths themselves cannot be unit-tested, because an Odin panic is
	// fatal and does not unwind; they are exercised as subprocesses instead.
	testing.expect(t, !on_goroutine(), "no runtime yet: on_goroutine must be false")

	runtime_init(1)
	defer runtime_teardown()
	testing.expect(t, !on_goroutine(), "on g0 before run(): on_goroutine must be false")

	on_goroutine_observed = false
	go_(check_on_goroutine)
	run()
	testing.expect(t, on_goroutine_observed, "inside a goroutine: on_goroutine must be true")

	testing.expect(t, !on_goroutine(), "back on g0 after run(): on_goroutine must be false")
}
