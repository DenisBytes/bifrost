# bifrost — Implementation Plan

> Each task is a *single, small, teachable* step. Mark `[x]` when finished.
> The agent will only expand the **next unchecked task** into a full
> teaching brief when asked. Do tasks in order — later tasks depend on
> invariants set up by earlier ones.
>
> All Go file/line references are in `/home/denisbytes/dev/go/src/runtime/`
> unless otherwise noted.

---

## Phase 0 — Project bootstrap

- [x] **0.1 Repo layout for `bifrost`.**
      Public package `bifrost` lives in `bifrost/` at the repo root (NOT
      `src/`); tests are colocated as `*_test.odin` (no separate `tests/`
      dir). This is the idiomatic Odin layout and matches kafka-odin —
      a deliberate deviation from the original `src/`+`tests/` sketch.
      Created: `bifrost/`, `examples/` (one dir per example), `ols.json`,
      `Makefile` (`build`, `check`, `test`, `test-integration`,
      `run-example`, `clean`), `README.md` (name story + Linux-x86_64-only
      note), `LICENSE` (MIT). No runtime code yet.
- [x] **0.2 Hello-world example skeleton.**
      `examples/hello/` imports the package and prints "ok", proving the
      build pipeline works before any real code lands.
- [x] **0.3 Initialise git, write `.gitignore` for Odin builds.**
      First commit: `CLAUDE.md`, `PLAN.md`, skeleton from 0.1/0.2.
- [x] **0.4 CI pipeline (GitHub Actions) — minimal.**
      `.github/workflows/test.yml` with `unit`, `integration`, and
      `examples` jobs on `ubuntu-latest`. Odin is installed via the
      `laytan/setup-odin@v2` action (nightly) — there *is* a usable
      setup-odin action, contrary to the original note. Each job installs
      `nasm` (needed to assemble `asm_amd64.asm`, Phase 2). Triggers on
      push to `main` and PRs. The multi-arch/Darwin matrix is deferred to
      Task 13.x.
- [x] **0.5 CI lint / style gate.**
      `.github/workflows/lint.yml` runs `make check`
      (`odin check bifrost -vet -strict-style`). DEVIATION: this Odin
      toolchain has no `odin fmt` command, so `-strict-style` (tabs, brace
      placement, spacing) is the format/style gate — there is no separate
      `tools/check-fmt.sh`. kafka-odin gates the same way.

---

## Phase 1 — Data layout (no behavior yet)

> Goal: have the same *shape* of structs as Go's runtime so every later
> task is a 1-to-1 translation. No scheduler logic in this phase.

- [x] **1.1 Define `gobuf`.** (`Gobuf` in `runtime2.odin`)
      Mirror `runtime2.go:303`. Fields `sp, pc, g, ctxt, lr, bp`.
      DEVIATION: current Go has no `ret` field, so bifrost omits it. Field
      offsets (sp@0, pc@8, bp@40) are guarded by a test for the Phase 2 asm.
- [x] **1.2 Define `stack`.** (`Stack` in `runtime2.odin`)
      Mirror `runtime2.go:460`. `lo`, `hi`. The `stack_alloc`/`stack_free`
      allocator lands in Phase 3 rather than as a panicking stub here.
- [x] **1.3 Define `g`.** (`G` in `runtime2.odin`)
      Mirror `runtime2.go:471`. Minimal subset: `stack`, `sched`,
      `atomicstatus`, `goid`, `m`, `schedlink`, `waitreason`, `param`.
- [x] **1.4 Define `m`.** (`M` in `runtime2.odin`)
      Mirror `runtime2.go:616`. Subset: `g0`, `curg`, `p`, `nextp`, `id`,
      `alllink`. DEVIATION: `tls` and the `park` note are deferred to Phase 5
      (multi-M); single-M tracks the current g via the global `current_g`.
- [x] **1.5 Define `p`.** (`P` in `runtime2.odin`)
      Mirror `runtime2.go:774`. Subset: `id`, `status` (`P_Status`), `m`,
      `runqhead`, `runqtail`, `runq[256]`, `runnext`, `gfree` (`G_List`).
- [x] **1.6 Define `schedt`.** (`Schedt` in `runtime2.odin`)
      Mirror `runtime2.go:932`. Subset: `goidgen`, global runq (`G_Queue`
      head/tail/n), idle M list, idle P list, `lock`.
- [x] **1.7 Globals.** (`runtime2.odin`)
      `allgs`, `allm`, `allp`, `sched`, `gomaxprocs`, plus `m0`/`g0`/
      `current_g`. `runtime_init(procs)` allocates `allp`, zeroes `sched`,
      and wires m0/g0. `G_Status`/`P_Status`/`Wait_Reason` + `casgstatus`
      live in `status.odin`. No threads yet.

---

## Phase 2 — Context switching primitive (the hard part)

> This is the magic that makes goroutines possible. We do x86_64 SysV
> first; aarch64 is a later optional task.
>
> IMPLEMENTATION NOTE: Odin has no `@(naked)` attribute, so the switch
> routines cannot be Odin procedures (the compiler-inserted prologue would
> clobber a hand-written `rsp`/`rbp` rewrite). They live in a standalone
> **NASM** file `asm_amd64.asm`, linked via `@require foreign import
> "asm_amd64.asm"` — exactly how Odin's own `base/runtime/
> entry_unix_no_crt_amd64.asm` works — and are called as `proc "c"` (SysV
> AMD64 ABI). Go's reference file is GAS `asm_amd64.s`; bifrost cites it but
> translates to NASM syntax. `nasm` must be installed (build tool, not a
> library dependency).

- [ ] **2.1 Concept lesson: what `gogo` and `mcall` actually do.**
      No code; the agent writes a short brief covering: callee-saved
      registers on SysV AMD64, what `rsp`, `rbp`, `rip` mean, why we
      need a separate scheduling stack (`g0`).
- [ ] **2.2 Implement `gosave_systemstack_switch`-style save.**
      A NASM file `asm_amd64.asm` exporting:
      `gosave(buf: ^Gobuf)` — saves `rsp`, `rbp`, `rip` (return addr)
      into `buf`. See Go's `asm_amd64.s` `gosave_systemstack_switch`
      and `gogo`.
- [ ] **2.3 Implement `gogo(buf: ^Gobuf) -> never`.**
      Restore `rsp`, `rbp`, jump to `pc`. Mirror `asm_amd64.s` `gogo`.
- [ ] **2.4 Implement `mcall(fn: proc(^G))`.**
      Switch from current g to `g0`, then call `fn(curg)` on g0's
      stack. See `proc.go` callers of `mcall` (e.g. `Gosched_m`).
- [ ] **2.5 Sanity test: ping-pong between two stacks.**
      Allocate two raw stacks (just `make([]u8, 64*1024)`), build two
      `gobuf`s pointing at two trivial functions that increment a
      counter and `gogo` back to the other. Run for N iterations.
      Acceptance: counters match expected, no segfault.

---

## Phase 3 — Stack management (start fixed-size)

- [ ] **3.1 Fixed-size stack allocator.**
      8 KiB or 16 KiB per goroutine, page-aligned, with a guard page
      (`mmap` + `mprotect PROT_NONE` on the low page). See `stack.go`
      `stackalloc` for the *idea*; we are NOT implementing the
      stack cache spans yet.
- [ ] **3.2 `newg(fn, arg)`.**
      Allocate a `g`, allocate a stack, set up `gobuf` so that on
      first `gogo` it begins executing a trampoline `goexit0(fn, arg)`.
      See `proc.go` `newproc`, `newproc1`.
- [ ] **3.3 `goexit` trampoline.**
      A function that `mcall`s into `goexit0`, which marks the g dead
      and returns it to the per-P `gFree` list. See `proc.go` `goexit`,
      `goexit1`, `goexit0`.
- [ ] **3.4 (Deferred / optional) Growable stacks.**
      Real Go uses split stacks via compiler-inserted `morestack`
      checks. Odin's compiler does NOT do this. Document the
      limitation; revisit only after the rest of the runtime works.

---

## Phase 4 — Single-M, single-P scheduler

> The simplest scheduler that actually runs goroutines. One OS thread,
> one P, cooperative scheduling only.

- [ ] **4.1 `casgstatus` and the g status enum.**
      `_Gidle, _Grunnable, _Grunning, _Gwaiting, _Gdead`. Study
      `runtime2.go` constants and `proc.go:1219` `casfrom_Gscanstatus`.
      Implement as atomic CAS.
- [ ] **4.2 Per-P run queue ops.**
      `runqput(p, g, next bool)`, `runqget(p) -> g`. Mirror `proc.go`
      `runqput` / `runqget` *exactly* including the `runnext` slot.
- [ ] **4.3 Global run queue ops.**
      `globrunqput`, `globrunqget(p, max)`. See `proc.go` of same name.
- [ ] **4.4 `schedule()` core loop.**
      On `g0`: pick a runnable G (runnext → local runq → global runq),
      `casgstatus _Grunnable -> _Grunning`, `gogo(&g.sched)`. See
      `proc.go` `schedule` and `execute`.
- [ ] **4.5 `Gosched()`.**
      Public API: `mcall(gosched_m)` where `gosched_m` puts curg back
      on the global runq as `_Grunnable` and calls `schedule`. See
      `proc.go:393`.
- [ ] **4.6 `gopark` and `goready`.**
      `gopark` parks current g (`_Grunning -> _Gwaiting`) with an
      unlock function; `goready` makes a `_Gwaiting` g `_Grunnable`
      and `runqput`s it. See `proc.go:449` and `:485`.
- [ ] **4.7 Public `go_(fn, arg)` entry.**
      Equivalent of Go's `go fn(arg)`. Calls `newg`, `runqput(p, g, true)`.
      Acceptance test: spawn 1000 goroutines that each increment a
      shared counter via `Gosched`-yielding loop; final counter == 1000.

---

## Phase 5 — Multi-M scheduler

> Now we run on `gomaxprocs` OS threads. This is where atomics, memory
> ordering, and lock-free queues start to matter.

- [ ] **5.1 Spin up M0 and bind it to P0.**
      `m0` is the main OS thread. Implement `acquirep` / `releasep`.
      See `proc.go` of same name.
- [ ] **5.2 `newm(fn, p)`.**
      Allocate an `m`, allocate a `g0` with its own stack, start an
      OS thread (Odin `core:thread.create`) whose entry calls `mstart`.
      See `proc.go` `newm`, `mstart`, `mstart1`.
- [ ] **5.3 `startTheWorld` minimal.**
      For each idle P, ensure there is an M to run it. Park extra Ms
      on `m.park` semaphore. See `proc.go` `startm`, `wakep`.
- [ ] **5.4 Work stealing in `findrunnable`.**
      Order: local runnext → local runq → global runq → poll netpoll
      (later) → steal from a random other P (half its queue). See
      `proc.go` `findRunnable`, `runqsteal`, `runqgrab`.
- [ ] **5.5 M parking / unparking.**
      When `findrunnable` finds nothing, M parks on its semaphore.
      `wakep` / `startm` unparks. See `proc.go` `stopm`, `startm`.
- [ ] **5.6 Stress test.**
      4 Ms, 4 Ps, 100k goroutines doing `Gosched` in a loop and a
      shared atomic counter. Acceptance: no race, no deadlock, all
      goroutines terminate, counter == expected.

---

## Phase 6 — Channels

- [ ] **6.1 `sudog` pool.**
      Mirror `runtime2.go:404` and `proc.go:492` `acquireSudog` /
      `releaseSudog`. Per-P cache + central freelist.
- [ ] **6.2 `hchan` struct + `make_chan(elem_size, capacity)`.**
      Mirror `chan.go:34`. Allocate ring buffer inline after the
      header for efficiency, like `chan.go` `makechan`.
- [ ] **6.3 Unbuffered send/recv (synchronous handoff).**
      Implement the "direct send" path: if a receiver is waiting,
      copy element straight to its frame and `goready` it; else park
      sender on `hchan.sendq`. See `chan.go` `chansend`, `chanrecv`,
      `send`, `recv`.
- [ ] **6.4 Buffered send/recv.**
      Add the ring-buffer fast path with `qcount`, `dataqsiz`,
      `sendx`, `recvx`. See same functions in `chan.go`.
- [ ] **6.5 `close(ch)`.**
      Wake all senders (panic on send to closed) and all receivers
      (return zero value, ok=false). See `chan.go` `closechan`.
- [ ] **6.6 Acceptance: classic worker pool.**
      Producer goroutine pushes 10k ints into a buffered chan
      (cap 16), N consumers drain. Sum matches expected.

---

## Phase 7 — `select`

- [ ] **7.1 Concept lesson: the two-phase locking algorithm.**
      Why `select` must lock all involved channels in address order
      to avoid deadlock. Read `select.go:selectgo` carefully.
- [ ] **7.2 `scase` and `selectgo` skeleton.**
      Build the `scase` array, randomize a poll order, lock all
      channels in address order. See `select.go:20` and `selectgo`.
- [ ] **7.3 Pass 1: try every case non-blocking.**
      If any case is ready, execute it, unlock all, return its index.
- [ ] **7.4 Pass 2: enqueue sudogs on every case, park.**
      On wakeup, find which case fired, dequeue sudogs from the
      others, return.
- [ ] **7.5 `default` case.**
      Trivial: pass 1 falls through to default if nothing ready.
- [ ] **7.6 Acceptance: timeout idiom.**
      `select { case <-ch: ...; case <-time_after(50ms): ... }`
      (uses Phase 9 timer; do this task after 9.x).

---

## Phase 8 — `sync` primitives

- [ ] **8.1 Runtime semaphore (`semacquire`/`semrelease`).**
      The foundation. See `sema.go`. Built on `gopark`/`goready`,
      hashed `semaRoot` treaps.
- [ ] **8.2 `Mutex`.**
      Spin a few times, then `semacquire`. See `src/sync/mutex.go`.
- [ ] **8.3 `WaitGroup`.**
      Atomic counter + sema. See `src/sync/waitgroup.go`.
- [ ] **8.4 `Once`.**
      Atomic done flag + Mutex. See `src/sync/once.go`.
- [ ] **8.5 `RWMutex` (optional).**
      See `src/sync/rwmutex.go`.
- [ ] **8.6 `Cond` (optional).**
      See `src/sync/cond.go`.

---

## Phase 9 — Timers and `Sleep`

- [ ] **9.1 Min-heap of timers per P.**
      Mirror `time.go` `pp.timers`. Each timer has `when`, `period`,
      `f`, `arg`.
- [ ] **9.2 `time_sleep(ns)`.**
      `gopark` current g; on timer fire, `goready`. See `time.go`
      `timeSleep`.
- [ ] **9.3 Timer firing in `findrunnable`.**
      Before stealing, check next timer; if expired, run it. See
      `proc.go` `checkTimers`.

---

## Phase 10 — Preemption

- [ ] **10.1 Cooperative preemption flag.**
      `g.preempt` bool checked at our explicit yield points (channel
      ops, sema, sleep, `Gosched`). Honest about: Odin compiler does
      not insert checks at function prologues like Go does.
- [ ] **10.2 `sysmon` thread.**
      Background M not bound to a P. Every 10ms wakes a P that's
      been running too long, sets `g.preempt = true`, sends `SIGURG`.
      See `proc.go` `sysmon`, `retake`.
- [ ] **10.3 Signal-based async preemption (Linux only, hard).**
      `SIGURG` handler saves the interrupted g's registers into
      `g.sched`, switches to `g0`, calls `schedule`. See
      `signal_unix.go` `doSigPreempt` and `preempt.go`.
      *This is the most fragile task in the project.*

---

## Phase 11 — Netpoller (optional, large)

- [ ] **11.1 `epoll`-based poller skeleton.**
      `pollDesc` per fd, `netpoll(block) -> []*g`. See
      `netpoll_epoll.go`.
- [ ] **11.2 Integrate poller into `findrunnable`.**
      Idle Ms call `netpoll(true)` to wait for fds; ready Gs go on
      a P's runq.
- [ ] **11.3 Wrappers for `read`/`write`/`accept`.**
      They call `gopark` until the fd is ready, then do the syscall
      non-blockingly.

---

## Phase 12 — Tooling and docs

- [ ] **12.1 `runtime_dump()` debug helper.**
      Print all Gs, Ms, Ps and their states. Invaluable for
      debugging deadlocks.
- [ ] **12.2 Examples folder.**
      `examples/01_hello.odin`, `02_pingpong.odin`, `03_chan.odin`,
      `04_select.odin`, `05_workerpool.odin`.
- [ ] **12.3 Public API docs.**
      Per-procedure doc comments linking to the Go source line that
      inspired them.

---

## Phase 13 — Testing infrastructure (`bifrost/testing`)

> A separate sub-package that ships *with* bifrost and is itself the
> first real consumer of the runtime. The point is to make bugs in
> goroutine code (and in our own runtime) cheap to find.
>
> Design constraint: we have **no compiler instrumentation** (unlike
> Go's `-race`). Everything below is built from runtime hooks we
> already own — the scheduler, channels, sudog queues, g status —
> plus an opt-in "instrumented shared cell" type for true data-race
> detection. See the discussion at the bottom of this file.
>
> Public sub-package path: `src/bifrost/testing/`. Public CLI tool:
> `tools/bifrost-check/` (binary name `bifrost-check`).
>
> NOTE: most of this phase only makes sense once the scheduler,
> channels, and sync primitives exist. Do these tasks **after Phase
> 8**, but the *design lesson* (13.1) can happen anytime.

- [ ] **13.1 Concept lesson: what we can and cannot detect.**
      Agent-written brief comparing four classes of bug and what's
      feasible without compiler instrumentation:
      1. *Goroutine leaks* — easy. Snapshot `allgs` before/after a
         test, diff the non-`_Gdead` set. Mirrors `go.uber.org/goleak`.
      2. *Channel leaks* — easy. Track `make_chan` / final use; warn
         on chans with parked sudogs at test end.
      3. *Deadlock* — easy. If every G is `_Gwaiting`, no timer is
         pending, no netpoll fd is armed → deadlock. Already detected
         by Go's runtime.
      4. *Data races on plain memory* — **not** feasible without
         compiler help. Feasible only on opt-in wrapped cells
         (`Shared(T)`) whose access goes through our hooks, OR via
         deterministic-schedule fuzzing (13.6) which finds races by
         provoking schedules that crash, not by observing memory.

- [ ] **13.2 Test harness: `bifrost.testing.run(test_proc)`.**
      Boots a fresh runtime (its own `allp`, `allm`, `allgs`),
      executes `test_proc`, then tears it down cleanly. This isolates
      tests from each other so leak detectors aren't confused by
      neighbours.

- [ ] **13.3 Goroutine leak detector.**
      `expect_no_leaked_goroutines(opts)`. Take a snapshot at scope
      entry; at scope exit, list any G that is not in the snapshot
      and is not `_Gdead`. Print where it was spawned (capture
      caller PC at `go_`). Inspired by `go.uber.org/goleak`.

- [ ] **13.4 Channel leak detector.**
      Each `hchan` carries a debug field with creation site. At
      test end, walk all live chans and report any that still have
      sudogs in `sendq`/`recvq` and were not closed.

- [ ] **13.5 Deadlock and "stuck select" detector.**
      Sysmon-style helper that, every N ms during a test, asks the
      scheduler: "is *any* G runnable, or is there a timer that will
      fire, or a poll that can complete?" If no on all three,
      report deadlock with a dump of every G's `waitreason` and
      stack. For `select`, surface which channels each parked G is
      waiting on so "infinite select" cases are obvious in the dump.

- [ ] **13.6 Deterministic-schedule fuzzer (the core idea).**
      The most important task in this phase.
      Because *we own the scheduler*, we can replace its `findrunnable`
      with a deterministic, seed-driven one. Then we run the same
      test under thousands of different schedules and look for any
      that deadlock, leak, panic, or assert. This is essentially
      what Microsoft's *Coyote* and Rust's *Loom* do.
      - Add a build flag / runtime mode `BIFROST_SCHED=fuzz:<seed>`
        that forces the scheduler to pick the next runnable G from
        a PRNG seeded by `<seed>`.
      - Cap goroutine counts and step counts so a single run is
        bounded.
      - Provide `bifrost.testing.fuzz(test_proc, iterations)` which
        runs `test_proc` under N seeds and reports any failing seed
        for replay.
      Acceptance: a hand-written buggy program (e.g. a missing
      `close` on a channel awaited by a receiver) is reliably caught
      within a few hundred seeds.

- [ ] **13.6b Adversarial / "chaos" scheduler mode.**
      Same plumbing as 13.6, different policy. Instead of a uniform
      PRNG, the scheduler always makes the *meanest* legal choice:
      run the goroutine that just unblocked, starve the longest
      waiter, prefer the G that holds the most channel sudogs, etc.
      Cheap to add once 13.6 exists, surfaces fairness/liveness
      bugs (priority inversion, starvation, missed wakeups) much
      faster than uniform random. Exposed as `BIFROST_SCHED=chaos`
      and `bifrost.testing.chaos(test_proc)`.

- [ ] **13.7 Opt-in `Shared(T)` for true data-race detection.**
      A generic wrapper:
      ```
      Shared :: struct(T: typeid) { value: T, last_writer: G_id,
                                    vc: VectorClock /* per-G */ }
      ```
      All access goes through `load(s)` and `store(s, v)`. Each
      goroutine carries a vector clock; channel send/recv and
      mutex acquire/release update it (this is the standard
      happens-before tracking that TSan does, just opt-in). On
      `load`/`store` we check that the current G's vc dominates the
      previous accessor's vc; if not → data race.
      *Limitation that must be documented:* this only catches
      races on values you explicitly wrap. Plain `int` shared
      between Gs is not observable. That's the price of having no
      compiler.

- [ ] **13.8 CLI tool: `bifrost-check`.**
      A standalone binary built from `tools/bifrost-check/`. It does
      *not* itself do TSan-style analysis; it is a test driver that
      orchestrates the runtime modes above. Subcommands:
      - `bifrost-check leaks ./my_test_bin` — runs the binary under
        the leak/deadlock detectors (13.3–13.5) and reports.
      - `bifrost-check fuzz ./my_test_bin --iterations=1000 --jobs=N`
        — runs the deterministic-schedule fuzzer (13.6) in parallel
        worker processes, each with a different seed range. On the
        first failure, prints the failing seed and a reproduction
        command (`bifrost-check replay --seed=...`).
      - `bifrost-check replay --seed=S ./my_test_bin` — re-runs a
        single seed with verbose scheduler tracing dumped to stderr.
      The CLI is thin: most of the brains live in the runtime hooks
      and the `bifrost.testing` sub-package; the CLI just spawns and
      summarises.

- [ ] **13.9 CI integration.**
      Extend `.github/workflows/ci.yml`:
      - Job `tests`: run `bifrost-check leaks` over every example
        and every test binary.
      - Job `fuzz-smoke`: run `bifrost-check fuzz --iterations=200`
        on a curated list of test binaries (cheap; catches
        regressions without blowing CI minutes).
      - Job `fuzz-nightly` (separate `nightly.yml`, scheduled cron):
        `--iterations=100000` across all test binaries; uploads
        any failing seed as an artifact.
      - Optional matrix here: once aarch64 lands, add an
        `arm64` runner; until then keep it `ubuntu-latest` only.

- [ ] **13.10 Docs: `docs/testing.md`.**
      User-facing guide for: writing a bifrost test, opting into
      `Shared(T)`, interpreting a failing seed, replaying it,
      writing a leak-clean test. Be explicit about what the tool
      does *not* catch.

---

## Out of scope (do not plan)
- Garbage collector cooperation, write barriers, stack scanning.
- `defer` / `panic` / `recover` semantics across goroutines.
- Compiler-instrumented race detection (TSan-equivalent on plain
  memory). The opt-in `Shared(T)` cell in 13.7 is the closest we
  can get without forking the Odin compiler.
- Cgo callbacks, signals other than `SIGURG`.
- Windows / Darwin scheduling specifics until Linux works end to end.
