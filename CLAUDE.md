# bifrost — Contributor & Agent Guide (CLAUDE.md)

> **Bifröst** — the rainbow bridge between worlds. The name fits a
> goroutine runtime: channels are bridges between independently
> executing tasks, and the scheduler is the bridge between user code
> and the OS.

## Project Goal
Build a library in **Odin**, named **bifrost**, that replicates Go's
goroutines and the surrounding runtime (scheduler, channels, select,
sync primitives, timers, eventually a network poller) as faithfully as
possible. The full Go reference implementation is available locally at
`/home/denisbytes/dev/go/` — primarily under `src/runtime/`. Always
cross-check designs against that source.

## Engineering Discipline (the rules that matter)
1. **Verify every claim against the Go source.** Before implementing how
   something works, open the relevant file under
   `/home/denisbytes/dev/go/src/runtime/` and keep the file + line range in
   the doc comment. Canonical files:
   - `runtime2.go` — `g`, `m`, `p`, `schedt`, `gobuf`, `sudog`, `stack`
   - `proc.go` — scheduler, `gopark`, `goready`, `mcall`, `schedule`
   - `chan.go` — `hchan`, send/recv, `waitq`
   - `select.go` — `scase`, `selectgo`
   - `stack.go` — stack alloc, growth, `morestack`
   - `sema.go` — semaphore-based sync
   - `lock_*.go` — runtime mutex
   - `netpoll*.go` — network poller
   - `time.go` — timers
2. **Be honest about deviations.** Where Odin can't match Go (no
   compiler-inserted preemption checks, no write barriers, no split-stack
   `morestack`, no `odin fmt`), say so explicitly in a doc comment and
   record *why* we chose the alternative, framed as "Go does X because
   <reason>; bifrost does Y because <Odin/scope reason>." The stated goal is
   to be able to defend every divergence.
3. **Smallest correct step, tracked in `PLAN.md`.** `PLAN.md` is the Phase
   0–13 roadmap with `[ ]`/`[x]` checkboxes. Implement in order — later
   tasks depend on invariants set up by earlier ones. Check a box only when
   its acceptance test passes.
4. **No new dependencies** beyond Odin `core:`, `base:`, `vendor:`, inline
   `asm`, and hand-written NASM assembly. The whole point is replication.
   (The `nasm` assembler is a build tool, like Go's own assembler — not a
   library dependency.)
5. **Pick the Go source over intuition.** If the Go code does something
   subtle (`casgstatus` ordering, `acquirep`/`releasep` invariants, sudog
   recycling, the `runnext` slot), preserve it and explain *why* it matters
   in a comment.

## Architecture (target: Go's G-M-P model)
- **G** — a goroutine: a stack + saved register state + scheduling metadata.
- **M** — an OS thread (`core:thread`).
- **P** — a logical processor: holds a local runnable queue and the
  resources an M needs to run goroutine code. `gomaxprocs == len(allp)`.
- **Schedt** — global scheduler state (global runq, idle M/P lists, sysmon).

Build order (see `PLAN.md` for the task-level breakdown):
1. Data layout (G, M, P, Gobuf, Stack, Schedt) and globals.
2. **Context switch** primitive (`gogo` / `gosave` / `mcall`) — hand-written
   NASM per architecture (x86_64 first).
3. Stack allocation (fixed-size first; growable later, optional).
4. Single-threaded cooperative scheduler (`go_`, `gosched`, `gopark`,
   `goready`).
5. Multi-M scheduler with per-P local runqs + global runq + work stealing.
6. **Channels** (unbuffered, then buffered) using `Sudog` + `Waitq`.
7. **select** with the randomized two-phase algorithm from `select.go`.
8. **sync** primitives on `gopark`/`goready`: Mutex, WaitGroup, Once, etc.
9. **Timers / Sleep**; 10. **Preemption**; 11. **Netpoller**;
   12. tooling/docs; 13. testing infrastructure + fuzzer; CI throughout.

## Conventions
File layout mirrors Go's `runtime/` where practical: `runtime2.odin`,
`proc.odin`, `chan.odin`, `select.odin`, `stack.odin`, `sema.odin`,
`asm_amd64.asm`, etc. The public package is `bifrost`, living in `bifrost/`
at the repo root. Examples live one-per-directory under `examples/`.

Naming mirrors the user's Odin style (see `/home/denisbytes/dev/kafka-odin`):
- **Types:** `Pascal_Case` / `Ada_Case`. Runtime structs keep Go's terse
  names with Odin casing: `G`, `M`, `P`, `Schedt`, `Sudog`, `Hchan`,
  `Gobuf`, `Stack`, `Waitq`, `Scase`.
- **Procedures:** `snake_case`. Internal scheduler procs keep Go names for
  grep-parity against the Go source: `gopark`, `goready`, `runqput`,
  `runqget`, `globrunqput`, `schedule`, `execute`, `mcall`, `gogo`,
  `gosave`, `casgstatus`, `newg`. Public API is friendlier: `go_`,
  `gosched`.
- **Constants:** `UPPER_CASE ::`. **Struct fields:** `snake_case`.
- **Status enum:** `G_Status :: enum { Idle, Runnable, Running, Waiting,
  Dead }` (maps to Go's `_Gidle/_Grunnable/...`; document the mapping).
- **Errors:** union types with a `.None` enum member where a path is
  fallible; `or_return` to chain. No panics on recoverable paths; most
  internal runtime procs are infallible by design.
- **Memory:** explicit `allocator := context.allocator` params; pair
  allocations with `defer delete()`/`free()`.
- **Doc comments:** a substantial `//` block above every exported decl,
  explaining invariants and edge cases and citing the Go `file:line` it
  parallels. `@(private)` marks internals.
- **Calling convention:** asm-backed routines are `foreign` `proc "c"`
  (SysV AMD64 ABI). Use `#force_inline proc "contextless"` for tiny
  register helpers if ever needed.

## Building, testing, running
- `make check` — `odin check bifrost -vet -strict-style`. This is the style
  gate (the toolchain ships no `odin fmt`).
- `make test` — colocated `*_test.odin` unit tests (`core:testing`,
  `@(test)`).
- `make test-integration` — heavier stress tests, gated on
  `BIFROST_INTEGRATION=1` (mirrors kafka-odin's integration pattern).
- `make build` — type-check + compile every example into `./bin`.
- `make run-example EXAMPLE=hello` — build and run one example.
- Requires the Odin nightly compiler and `nasm` (for the context-switch
  assembly). CI runs on `ubuntu-latest` via `laytan/setup-odin@v2`.

## Testing approach
- **Unit tests** are colocated as `*_test.odin` in the `bifrost` package,
  one test file per source file. Use `testing.expect` / `testing.expectf`.
- Tests run **serially** (`-define:ODIN_TEST_THREADS=1`, set in the Makefile):
  the runtime is global state (`allp`, `sched`, `m0`, `g0`), so tests that boot
  it cannot run concurrently. A per-test fresh runtime is Phase 13.2 work.
- **Integration/stress tests** live in `integration_*_test.odin` in the same
  package; each begins with `if integration_skip(t) do return` so the unit
  suite is unaffected unless `BIFROST_INTEGRATION=1`.
- Every phase in `PLAN.md` ships with an acceptance test; the box is checked
  only when it passes.

## Platform / Out of Scope (for now)
- **Linux x86_64 only.** aarch64, Darwin, and Windows come after x86_64 is
  solid.
- Cgo, race detector on plain memory, write barriers, GC cooperation,
  generational/concurrent GC, growable (split) stacks, signals other than
  `SIGURG`. See `PLAN.md` "Out of scope" for the full list.
