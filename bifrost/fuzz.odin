package bifrost

import "base:intrinsics"

// Phase 13.6 SKELETON: a deterministic-schedule fuzzer.
//
// The premise: bifrost owns the scheduler, so we can replace the "FIFO pick"
// in globrunqget with a seeded pseudo-random pick. A given seed reproduces the
// same sequence of picks; varying the seed explores different interleavings
// of currently-runnable goroutines. Tests can then be replayed under many
// seeds to surface ordering-dependent bugs that a FIFO scheduler would miss.
//
// This is the smallest useful fuzzer — perturbation lives only at the
// globrunqget pick site, since gosched/runqputslow/global overflow all funnel
// through that queue. Future work: shuffle local runqs (more complex because
// they are lock-free rings), bias select wake-race ordering, inject delayed
// goreadies. See PLAN.md Phase 13.6 / 13.6b.
//
// USAGE:
//   runtime_init(1)
//   runtime_set_fuzz_seed(some_seed)   // 0 == fuzz off (default)
//   // ... go_(workers) ...
//   run()
//
// API design choice: a single global seed. Each fuzz_next call atomically
// advances it via CAS, so multi-M is safe and the visible sequence is
// deterministic-per-seed (the OS-thread arrival order at the CAS is the only
// nondeterminism; in practice the cooperative scheduler keeps it stable).

@(private)
fuzz_seed_state: u64

// runtime_set_fuzz_seed enables the deterministic-schedule fuzzer with the
// given seed. Pass 0 to disable. Must be called BEFORE run() so the runtime's
// observable scheduling is consistent for the whole run.
runtime_set_fuzz_seed :: proc(seed: u64) {
	intrinsics.atomic_store(&fuzz_seed_state, seed)
}

// runtime_fuzz_active reports whether the fuzzer is currently enabled.
runtime_fuzz_active :: proc "contextless" () -> bool {
	return intrinsics.atomic_load(&fuzz_seed_state) != 0
}

// fuzz_next advances the seed via xorshift64 and returns the previous value.
// Returns 0 when the fuzzer is disabled so call sites can check the result.
@(private)
fuzz_next :: proc "contextless" () -> u64 {
	for {
		cur := intrinsics.atomic_load(&fuzz_seed_state)
		if cur == 0 {
			return 0
		}
		x := cur
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		if x == 0 {
			x = 0xDEAD_BEEF_CAFE_F00D // keep the stream alive on degenerate input
		}
		_, ok := intrinsics.atomic_compare_exchange_strong(&fuzz_seed_state, cur, x)
		if ok {
			return cur
		}
	}
}
