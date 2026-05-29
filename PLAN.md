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

- [x] **2.1 Concept: what `gogo` and `mcall` actually do.**
      Captured as the header doc comment in `asm_amd64.asm` (callee-saved
      registers on SysV AMD64, the saved-frame layout, why bifrost saves more
      than Go) instead of a separate brief.
- [x] **2.2 / 2.3 Context-switch primitives (`asm_amd64.asm`).**
      NASM file exporting `gogo(to)` (restore + resume, never returns) and
      `gosave_switch(from, to)` (save current, resume target — a swapcontext).
      DEVIATION: rather than Go's split `gosave`+`gogo` that save only sp/pc/bp,
      bifrost pushes the full callee-saved set (rbx, rbp, r12-r15) onto the
      suspended goroutine's own stack, because Odin goroutine functions are
      ordinary SysV functions whose callee-saved registers must survive the
      switch (Go's compiler spills them per ABIInternal; Odin's does not).
      `setup_context` (asm_amd64.odin) builds a fresh saved frame. Foreign
      decls + arch guard in `asm_amd64.odin`.
- [ ] **2.4 Implement `mcall(fn: proc(^G))`.**
      MOVED TO PHASE 4: mcall must save curg into curg.sched, switch to
      g0's stack, and call fn(curg) there — it needs g0/current_g wiring that
      only exists once the scheduler is built. See `proc.go` callers of mcall
      (e.g. `goschedguarded_m`).
- [x] **2.5 Sanity test: ping-pong between two stacks.**
      `asm_amd64_test.odin`: two coroutines on two 64 KiB stacks bounce via
      `gosave_switch`, each incrementing a counter; one returns to the test via
      `gogo`. Acceptance met: count_a == iters, count_b == iters-1, no segfault.
      Requires `nasm` to assemble.

---

## Phase 3 — Stack management (start fixed-size)

- [x] **3.1 Fixed-size stack allocator.** (`stack.odin`)
      `stack_alloc(size)`/`stack_free` via `core:sys/linux` mmap + a low-end
      PROT_NONE guard page; 16 KiB default (`STACK_MIN`). No span cache. Tests
      cover bounds, alignment, writability, and zero-Stack free.
- [ ] **3.2 `newg(fn, arg)`** — MOVED TO PHASE 4. newg allocates a G + stack
      and uses `setup_context` so the first `gogo` runs a trampoline that calls
      fn then exits. It is only exercisable once the scheduler exists, so it
      lands with go_/execute in Phase 4. See `proc.go` `newproc`, `newproc1`.
- [ ] **3.3 `goexit` trampoline** — MOVED TO PHASE 4. After the user fn
      returns, the trampoline marks the G `Dead`, returns it to the per-P
      gfree list, and re-enters the scheduler. Needs mcall/schedule, so it is
      built in Phase 4. See `proc.go` `goexit`, `goexit0`.
- [x] **3.4 Growable stacks — documented as out of scope.**
      Go grows stacks via compiler-inserted `morestack`; Odin's compiler does
      not, so bifrost uses fixed stacks (see `STACK_MIN` doc comment). Recorded
      as a permanent deviation; not revisited in this milestone.

---

## Phase 4 — Single-M, single-P scheduler

> The simplest scheduler that actually runs goroutines. One OS thread,
> one P, cooperative scheduling only.

- [x] **4.1 `casgstatus` and the g status enum.** (`status.odin`, Phase 1)
      `G_Status{Idle,Runnable,Running,Waiting,Dead}` + atomic-CAS `casgstatus`.
      DEVIATION: Go spins to tolerate the GC `_Gscan` bit; bifrost has no GC, so
      a failed CAS is a bug and panics (mirrors Go's throw).
- [x] **4.2 Per-P run queue ops.** (`proc.odin`)
      `runqput(p, g, next)` (incl. the runnext slot, gated by `HAVE_SYSMON` like
      Go's `!haveSysmon` guard), `runqget(p)`, `runqputslow` overflow-to-global.
      DEVIATION: single-M, so plain loads/stores replace Go's atomic ring ops
      (atomics return in Phase 5).
- [x] **4.3 Global run queue ops.** (`proc.odin`)
      `globrunqput`, `globrunqputbatch`, `globrunqget` over the `G_Queue` FIFO.
      sched.lock unused until Phase 5 (single-M).
- [x] **4.4 `schedule()` / `execute()` + `mcall` (2.4).** (`proc.odin`, `asm`)
      schedule: findrunnable (local→global) → execute → `gogo(&g.sched)`; when
      idle, deadlock-detect or `gogo(&sched_return)` back to `run()`. mcall lands
      here (asm `mcall_switch`): save curg, switch to g0, call fn. `run()` /
      `schedule_bootstrap` boot the loop.
- [x] **4.5 `gosched()`.** (`proc.odin`)
      `mcall(gosched_m)`; gosched_m requeues curg `Running->Runnable` on the
      GLOBAL runq (fair) and calls schedule. Mirrors `proc.go:393`/goschedImpl.
- [x] **4.6 `gopark` and `goready`.** (`proc.odin`)
      gopark: `Running->Waiting` via `mcall(park_m)` with an optional unlockf
      (veto resumes); goready/ready: `Waiting->Runnable` + runqput. Park
      unlockf/lock held in package globals (Go uses m fields; Phase 5 moves them).
- [x] **4.7 Public `go_` + `newg`/`goexit` (3.2/3.3).** (`proc.odin`)
      `go_(fn, arg)` -> newg (reuses dead G+stack from gfree, else allocates) ->
      runqput. goexit_entry trampoline runs fn then `goexit` -> goexit0 (Dead +
      gfput + schedule). DEVIATION: fn/arg stored on the G and run via an Odin
      trampoline instead of Go's gostartcallfn stack encoding. Acceptance:
      1000-goroutine counter test == 1000; integration stress (10k goroutines,
      batch reuse) green; spawn/pingpong examples run.

---

## Phase 5 — Multi-M scheduler

> Now we run on `gomaxprocs` OS threads. This is where atomics, memory
> ordering, and lock-free queues start to matter.

> SCOPE (agreed with user): a *correct subset* — atomic run queues + work
> stealing + semaphore parking with a timeout backstop + best-effort wakeups.
> NO spinning-M "delicate dance" and NO sysmon (deferred). Threads lifecycle is
> *self-contained run()*: it starts the workers, runs to completion, then joins
> them. DEVIATION: a fixed M-per-P pool (one M pinned per P, created upfront)
> instead of Go's on-demand Ms + P handoff; load is balanced by stealing.

- [x] **5.1 acquirep/releasep + thread-local getg/getm.** (commit `5cd6fcb`)
      `@(thread_local) tls_g/tls_m` replace the single current_g; `acquirep`/
      `releasep` bind a P to an M. m0 binds P0 in scheduler_start.
- [x] **5.2 `newm` + real OS threads.** (`proc.odin`)
      `newm(pp)` allocates an M, its g0 + g0 stack, and starts an OS thread via
      `core:thread.create_and_start_with_data` whose entry (`m_thread_entry` →
      `mstart_run`) installs tls and runs `schedule` on the g0 stack. Mirrors
      newm/mstart0/mstart1.
- [x] **5.3 run() starts/stops the worker pool.**
      DEVIATION from Go's startTheWorld/startm: `run()` pre-creates one worker M
      per P beyond P0, runs m0's own schedule loop, and on shutdown joins +
      destroys the workers. Termination is driven by `sched.grunning` (atomic
      live-goroutine count) → `begin_shutdown` posts all Ms.
- [x] **5.4 Work stealing in `findrunnable`.** (`proc.odin`)
      Order: local runq → global runq → steal half from a random other P
      (`runqsteal`/`runqgrab`, a few rounds via a per-thread `fastrand`).
      runnext stays disabled (HAVE_SYSMON false), so its steal path is inert.
- [x] **5.5 M parking / unparking.** (`proc.odin`)
      Idle Ms park in `stopm` on a shared `sched.idle_sema` with `PARK_TIMEOUT`;
      producers (`go_`/`ready`/`gosched_m`) `wakep`. DEVIATION: the timeout
      backstop makes correctness independent of precise wakeups, replacing Go's
      spinning-M handshake. Deadlock is reported when all Ms go idle with live
      goroutines (`report_deadlock_if_stuck`, status-based like checkdead).
- [x] **5.6 Stress tests.** (`integration_sched_test.odin`)
      4-thread suite: 20k-goroutine parallel atomic counter (== expected,
      ≥2 Ms used), work-stealing test (children confined to one P spread across
      Ms), cross-M gopark/goready, repeated init/run/teardown — all leak-clean,
      run 20× in a loop with no race/deadlock. (Used 20k not 100k: each
      goroutine is a distinct mmap'd stack, so 100k would hit the default
      vm.max_map_count; documented.) `examples/parallel` runs on 4 OS threads.

---

## Phase 5.5 — Scheduler hardening (pre-flight before channels)

> A code review of Phase 5 surfaced one bug that *blocks* channels plus a
> cluster of robustness gaps. Channels are the first real consumer of
> `gopark` with a non-nil unlock callback (`hchan.lock`) driven by many
> goroutines at once, so the park/wakeup/deadlock machinery must be correct
> and lock-serialized first. SCOPE (agreed with user): full hardening — port
> Go's idle-M-list + per-M note model and run `checkdead` under `sched.lock`,
> not just the one blocking fix.

- [x] **5.5.1 Park callback onto M (BLOCKS Phase 6).**
      Move `park_unlockf`/`park_lock` (package globals — a cross-M data race)
      onto `M.waitunlockf`/`M.waitlock`, mirroring Go's `m.waitunlockf` /
      `m.waitlock` (`runtime2.go` m struct). `gopark` sets them via `getm()`;
      `park_m` reads them via `getm()` (same M — `mcall` switches to g0, not to
      another thread). Update the stale `proc.odin:40-41` comment.
- [x] **5.5.2 Fail-fast on thread spawn.**
      `newm` must check `thread.create_and_start_with_data` for `nil` and
      `panic` (consistent with the adjacent `stack_alloc` panic). A silent
      `nil` later hits `thread.destroy(nil)` and breaks the
      `gomaxprocs == live-Ms` invariant the deadlock detector relies on.
- [x] **5.5.3 Always-on ring-overflow guard.**
      `runqsteal`'s overflow check is an `assert` (stripped in release →
      silent ring corruption). Replace with an unconditional `panic`, mirroring
      Go's always-on `throw` (`proc.go` runqsteal).
- [x] **5.5.4 Per-M note + idle-M list (replace the shared counting sema).**
      The shared `sync.Sema` is a *counting* sema, so `wakep` over-posts and
      idle Ms busy-spin draining stale permits. Port Go's model: each M parks
      on its own one-shot note (`M.park: sync.Sema`, used binary), and `sched`
      keeps a LIFO idle-M list (`mput`/`mget` under `sched.lock`, mirror
      `proc.go` mput/mget). `wakep` pops exactly one idle M and wakes it;
      `begin_shutdown` wakes every idle M. Keep a long `PARK_TIMEOUT` only as a
      paranoia backstop. Permits no longer accumulate → state is clean across
      repeated `run()`.
- [x] **5.5.5 `checkdead` under `sched.lock`.**
      Determine "all Ms idle" from the idle-list count while holding
      `sched.lock` (mirror `proc.go:6397` `checkdead`) so the queue-empty
      check + idle count + status scan are one consistent snapshot.
      Distinguish a true all-`_Gwaiting` deadlock (panic with goids + wait
      reasons) from a *lost wakeup* (runnable work exists yet all Ms idle →
      loud, distinct error), restoring the lost-wakeup invariant the Phase-4
      `check_dead` had and the Phase-5 rewrite dropped.
- [x] **5.5.6 Comment-honesty pass (CLAUDE.md rule 2).**
      Fix stale "Phase 5 will…" caveats now that Phase 5 is done: the goexit
      temp-allocator caveat (`proc.odin:166-170`) and the `casgstatus`
      single-M justification (`status.odin`) — each restated to reflect
      multi-M reality or its real deferral phase.
- [x] **5.5.7 Re-verify.**
      `make check`/`test`/`test-integration` green; integration looped ≥20×
      with no race/deadlock; assert the idle-list/notes drain clean across
      repeated `run()` rounds.

---

## Phase 6 — Channels

> API decision (agreed with user): an **untyped core** that mirrors Go's
> `chan.go` one-to-one for grep-parity (operates on `elem_size` + `rawptr`),
> plus a thin **generic `Chan(T)` wrapper** for type-safe ergonomics. The
> `block bool` parameter is threaded through `chansend`/`chanrecv` from the
> start (only `block=true` is exercised now) so Phase 7 `select`'s
> non-blocking probes drop in cheaply.

- [x] **6.1 `Sudog` + `Waitq` + sudog pool.**
      `Sudog` = subset of `runtime2.go:404` (`g`, `next`, `prev`, `elem`,
      `success`, `c`, `isSelect`); `Waitq{first,last}` with enqueue/dequeue
      (`chan.odin`). `acquire_sudog`/`release_sudog` with a per-P cache backed by
      a central freelist, mirroring `proc.go:492`. DEVIATION: the central list
      uses a dedicated `sched.sudoglock` (like Go's `sched.sudoglock`), not the
      run-queue `sched.lock`, so sudog churn doesn't contend with scheduling. The
      `Hchan` struct also landed here (it is type-coupled to `Sudog.c`/`Waitq`);
      `dequeue`'s select wake-race skip is deferred to Phase 7. `sudog_pool_free`
      reclaims pooled sudogs at teardown (bifrost has no GC).
- [ ] **6.2 `make_chan(elem_size, capacity)` + `close_chan`.**
      The `Hchan` struct already exists (6.1). Add `make_chan`, allocating the
      ring buffer inline after the header like `chan.go` `makechan`, and the
      `close_chan` shell. Mirrors `chan.go`.
- [ ] **6.3 Unbuffered send/recv (synchronous handoff).**
      `chansend(c, elem, block)` / `chanrecv(c, elem, block)`: if a peer
      waits, `send`/`recv` copies the element straight across the parked
      goroutine's `sg.elem` and `goready`s it; else park on `sendq`/`recvq`
      via `gopark(chanparkcommit, &c.lock, …)` — now safe thanks to **5.5.1**.
      `chanparkcommit(gp, lock)` unlocks `c.lock` after the status flip. See
      `chan.go` `chansend`/`chanrecv`/`send`/`recv`/`chanparkcommit`.
- [ ] **6.4 Buffered send/recv.**
      Ring-buffer fast path with `qcount`/`dataqsiz`/`sendx`/`recvx`, including
      the buffered-and-sender-waiting rotate in `recv`. Same `chan.go`
      functions.
- [ ] **6.5 `close_chan`.**
      Wake all `sendq` waiters (they panic on resume: send on closed channel)
      and all `recvq` waiters (zero value, `ok=false`). Panic on close of a
      closed/nil channel. See `chan.go` `closechan`.
- [ ] **6.6 Typed `Chan(T)` wrapper.**
      `Chan :: struct($T)` over `^Hchan`; `chan_make($T, cap)`,
      `chan_send(ch, v)`, `chan_recv(ch) -> (T, bool)`, `chan_close(ch)` —
      thin parametric-polymorphism wrappers that `size_of(T)` into the untyped
      core and copy via `&v`.
- [ ] **6.7 Acceptance: worker pool + unbuffered ping-pong.**
      Producer pushes 10k ints into a buffered chan (cap 16); N consumer
      goroutines drain; sum matches expected. Plus an unbuffered ping-pong
      proving synchronous handoff. Multi-M (`runtime_init(4)`) integration
      stress, looped, leak-clean. `examples/` gets a `chan` worker-pool demo.

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
