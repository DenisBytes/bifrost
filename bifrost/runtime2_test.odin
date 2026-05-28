package bifrost

import "core:testing"

// free_runtime releases what runtime_init allocated so each test starts from
// a clean slate (a stand-in for the Phase 13 teardown helper).
@(private)
free_runtime :: proc() {
	for pp in allp {
		free(pp)
	}
	delete(allp)
	allp = nil
}

@(test)
test_runtime_init_single_p :: proc(t: ^testing.T) {
	runtime_init(1)
	defer free_runtime()

	testing.expectf(t, gomaxprocs == 1, "gomaxprocs = %d, want 1", gomaxprocs)
	testing.expectf(t, len(allp) == 1, "len(allp) = %d, want 1", len(allp))
	testing.expect(t, allp[0] != nil, "allp[0] is nil")
	testing.expectf(t, allp[0].id == 0, "allp[0].id = %d, want 0", allp[0].id)
	testing.expectf(t, allp[0].status == .Idle, "allp[0].status = %v, want Idle", allp[0].status)
}

@(test)
test_runtime_init_wires_m0_g0 :: proc(t: ^testing.T) {
	runtime_init(1)
	defer free_runtime()

	testing.expect(t, m0.g0 == &g0, "m0.g0 should point at g0")
	testing.expect(t, g0.m == &m0, "g0.m should point at m0")
	testing.expect(t, allm == &m0, "allm should head at m0")
	testing.expect(t, current_g == &g0, "current_g should start as g0")
	testing.expect(t, getg() == &g0, "getg() should return g0 after init")
}

@(test)
test_runtime_init_multiple_ps :: proc(t: ^testing.T) {
	runtime_init(4)
	defer free_runtime()

	testing.expectf(t, len(allp) == 4, "len(allp) = %d, want 4", len(allp))
	for pp, i in allp {
		testing.expect(t, pp != nil, "P is nil")
		testing.expectf(t, pp.id == i32(i), "allp[%d].id = %d", i, pp.id)
		testing.expectf(t, pp.status == .Idle, "allp[%d].status = %v", i, pp.status)
	}
}

@(test)
test_zero_g_is_idle :: proc(t: ^testing.T) {
	// A zero-initialized G must read as _Gidle (status 0): newg relies on this
	// before its first casgstatus.
	gp := G{}
	testing.expectf(t, gp.atomicstatus == .Idle, "zero G status = %v, want Idle", gp.atomicstatus)
	testing.expect(t, gp.schedlink == nil, "zero G schedlink should be nil")
}

@(test)
test_casgstatus_transition :: proc(t: ^testing.T) {
	gp := G {
		atomicstatus = .Runnable,
	}
	casgstatus(&gp, .Runnable, .Running)
	testing.expectf(t, g_status(&gp) == .Running, "status = %v, want Running", g_status(&gp))

	casgstatus(&gp, .Running, .Waiting)
	testing.expectf(t, g_status(&gp) == .Waiting, "status = %v, want Waiting", g_status(&gp))
}

@(test)
test_gobuf_field_offsets :: proc(t: ^testing.T) {
	// The context-switch assembly (asm_amd64.asm) addresses Gobuf fields by
	// these exact byte offsets. If the struct layout changes, the asm breaks
	// silently — this test is the canary.
	testing.expectf(t, offset_of(Gobuf, sp) == 0, "offset(sp) = %d, want 0", offset_of(Gobuf, sp))
	testing.expectf(t, offset_of(Gobuf, pc) == 8, "offset(pc) = %d, want 8", offset_of(Gobuf, pc))
	testing.expectf(t, offset_of(Gobuf, bp) == 40, "offset(bp) = %d, want 40", offset_of(Gobuf, bp))
}
