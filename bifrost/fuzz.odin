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
// Perturbation lives at the globrunqget pick site. On its own that reaches only
// gosched, runqputslow and global-queue overflow — measured at 0% of scheduling
// decisions in every channel/select/Mutex/sema workload, because those wake
// goroutines onto a P's LOCAL ring, which never reaches the global queue. So
// ready() (proc.odin) additionally routes wakeups through globrunqput while a
// seed is set, which is what puts the primitives in front of the shuffle.
//
// Future work: shuffle the local runqs directly (harder — they are lock-free
// rings), bias the select wake race, inject delayed goreadies. See PLAN.md
// Phase 13.6 / 13.6b.
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
//   - gomaxprocs == 1, no timers: the same seed drives the same sequence of
//     global-queue picks. NOT byte-identical for select: select_'s poll order
//     comes from the unseeded per-thread fastrand (see select.odin), so a
//     select over two simultaneously-ready cases can still choose differently
//     between runs. Channel, sema and Mutex workloads reproduce.
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

// fuzz_perturbations counts how many times the fuzzer has actually REORDERED a
// scheduling decision (globrunqget picking a non-head entry), as opposed to
// merely being enabled. It exists because "the fuzzer is on" and "the fuzzer is
// exercising this workload" are very different claims: the perturbation site
// only fires when the global run queue holds more than one runnable G, so a
// workload with at most one runnable goroutine at a time is unperturbable no
// matter what seed is set. Tests assert on this rather than on the seed.
@(private)
fuzz_perturbations: u64

// runtime_set_fuzz_seed enables the deterministic-schedule fuzzer with the
// given seed. Pass 0 to disable. Must be called BEFORE run() so the runtime's
// observable scheduling is consistent for the whole run.
runtime_set_fuzz_seed :: proc(seed: u64) {
	intrinsics.atomic_store(&fuzz_seed_state, seed)
}

// runtime_fuzz_count returns the number of scheduling decisions the fuzzer has
// actually reordered since the last runtime_teardown. Zero while disabled, and
// zero even when enabled if the workload never had two goroutines runnable at
// once.
runtime_fuzz_count :: proc "contextless" () -> u64 {
	return intrinsics.atomic_load(&fuzz_perturbations)
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
