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
// advances it via CAS, so multi-M is safe. The xorshift STREAM is deterministic
// per seed, but the MAPPING (which M consumes which value) depends on OS thread
// arrival at the CAS. So:
//   - gomaxprocs == 1, no timers: byte-identical replay for the same seed.
//     Pure goroutine workloads (channels, select, sema, Mutex, ...) reproduce.
//   - With timers: replay diverges. time_sleep / time_after expire against
//     mono_now_ns, which is NOT seeded, and PARK_TIMEOUT-driven stopm wakeups
//     are wall-clock-paced. A goready'd-from-timer goroutine landing on the
//     runq mid-perturbation shifts sched.runq.n and therefore the (r % n)
//     index even when r is identical. Fuzz under timer workloads is still
//     useful for *finding* bugs; replay is not byte-identical.
//   - gomaxprocs >  1: same set of perturbations applied in seed-determined
//     order to the global PRNG, but goroutine-pick order across Ms is also
//     subject to OS scheduling. Sufficient for shaking out ordering bugs,
//     insufficient for byte-identical multi-M replay (follow-up: per-P seed).
// Disable race: a non-zero seed can produce ONE extra perturbation past a
// concurrent runtime_set_fuzz_seed(0) (the racing fuzz_next has already loaded
// a non-zero value when the disable lands). For test cleanup correctness,
// reset the seed BEFORE the next test creates goroutines.

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
// xorshift64 with shifts (13, 7, 17) is a bijection on u64 \ {0}: given a
// non-zero input the output is non-zero, so no degenerate-input guard is
// needed beyond the cur==0 disable check at the top of the loop.
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
		_, ok := intrinsics.atomic_compare_exchange_strong(&fuzz_seed_state, cur, x)
		if ok {
			return cur
		}
	}
}
