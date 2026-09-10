# bifrost

> **Bifröst** — the rainbow bridge between worlds. The name fits a goroutine
> runtime: channels are bridges between independently executing tasks, and the
> scheduler is the bridge between user code and the OS thread that runs it.

`bifrost` is a from-scratch reimplementation of Go's goroutine runtime —
the **scheduler**, **channels**, **`select`**, **sync primitives** and
**timers** — written in [Odin](https://odin-lang.org/).

The goal is faithful replication. The implementation tracks Go's runtime
(`src/runtime/`) closely: every exported procedure documents the Go source it
parallels, and every place bifrost diverges from Go records *why* (usually a
limitation of having no compiler instrumentation, unlike Go).

## Status

Research-grade, not production-ready — see [Limitations](#limitations), which
you should read before using this for anything real.

Phases 0–9 of [`PLAN.md`](PLAN.md) are implemented: the data layout, the x86_64
context switch, fixed-size stacks, a **multi-threaded G-M-P scheduler** with
per-P run queues and work stealing, **channels** (buffered and unbuffered),
**`select`**, the **sync primitives** (`Mutex`, `RWMutex`, `WaitGroup`, `Once`,
`Cond`, and the runtime semaphore they are built on), and **timers**
(`time_sleep`, `time_after`). A deterministic-schedule fuzzer skeleton
(Phase 13.6) is in place.

`runtime_init(n)` for `n > 1` starts **`n` real OS threads**, so goroutines run
in genuine parallel and shared state needs bifrost's own synchronisation —
`Mutex`, `Cond`, channels — not just careful ordering.

Preemption (Phase 10) and the network poller (Phase 11) are not implemented.

## Platform support

**Linux x86_64 only.** The context switch is hand-written SysV AMD64 assembly;
other architectures and operating systems come later.

## Limitations

Read these before using bifrost. Each is a real constraint, not a rough edge.

- **No goroutine may make a blocking syscall.** bifrost pins one OS thread per P
  for the process lifetime and has no `entersyscall`/`handoffp` — Go's mechanism
  for handing a P to another thread when a goroutine blocks in the kernel. A
  goroutine that blocks in a syscall takes its P out of service permanently, and
  the deadlock detector cannot see it, because a futex-blocked M is never on the
  idle list. In practice: **`core:sync`, `core:os` and blocking `core:net` calls
  are unsafe inside `go_`.** Use bifrost's own `Mutex`, `Cond`, `WaitGroup` and
  channels instead. Two goroutines contending on a `core:sync.Mutex` at
  `gomaxprocs=1` hang the runtime with no output; `fmt.println` to a pipe a slow
  reader is draining is enough to do the same. Fixing this properly is
  PLAN.md Phase 10–11.
- **No preemption.** A goroutine that never yields, parks or finishes keeps its
  P forever. Scheduling is cooperative (Phase 10).
- **Fixed stacks, no growth.** 32 KiB per goroutine by default, raisable with
  `-define:BIFROST_STACK_MIN=...`. Deep `core:` call trees can overflow it —
  `json.marshal` of a depth-8 struct does. Overflow faults on a 64 KiB guard
  region rather than corrupting a neighbour, but only for frames smaller than
  that guard.
- **Roughly 32,000 live goroutines.** Each costs two kernel VMAs (an `mmap` plus
  the `mprotect` that splits it) against a default `vm.max_map_count` of 65530.
  Exceeding it aborts the process: `go_` has no error return. Dead goroutines are
  recycled, so this is a high-water mark rather than a total.
- **Blocking calls are goroutine-only.** `chan_send`, `chan_recv`, `select_`,
  `mutex_lock`, `time_sleep` and friends panic with a diagnostic if called from
  the thread that runs `run()`, or from a thread bifrost did not create. There is
  no way to hand work in from a foreign thread.
- **You must call `runtime_teardown`.** There is no GC; it is what releases
  goroutine stacks, the G/M/P structures and the sudog pool.
- **No operational visibility.** No goroutine dump, no counters, no tracing.

## Building for release

Build and test with an optimization flag, and keep doing so:

```sh
make test-speed      # the suite at -o:speed
make test-size       # and at -o:size
make examples-speed  # builds AND runs every example optimized
```

This is not optional diligence. bifrost's context switch preserves callee-saved
registers across an OS-thread change, so the runtime is sensitive to what the
optimizer is allowed to cache in one — a green suite at Odin's default
`-o:minimal` is not evidence that a release build works.

## Architecture

bifrost mirrors Go's **G-M-P** model:

- **G** — a goroutine: a stack, a saved register snapshot, and scheduling state.
- **M** — an OS thread (`core:thread`).
- **P** — a logical processor holding a local run queue; `GOMAXPROCS == len(allp)`.

## Building and testing

Requires the [Odin compiler](https://odin-lang.org/docs/install/) (nightly)
and [NASM](https://www.nasm.us/) (to assemble the context-switch routines).

```sh
make build              # type-check the library + compile examples into ./bin
make check              # odin check -vet -strict-style (the style gate)
make test               # run the colocated unit tests
make test-integration   # run the env-gated scheduler stress tests
make run-example EXAMPLE=hello
```

## Layout

```
bifrost/        the runtime package (mirrors Go's src/runtime file names)
examples/       small runnable programs, one directory each
.github/        CI workflows (lint + test, on Odin nightly)
PLAN.md         the full Phase 0–13 implementation roadmap
CLAUDE.md       contributor / agent guide
```

## Acknowledgments

bifrost is a study of, and tribute to, the Go runtime. The reference
implementation it tracks is [Go](https://go.dev/), whose `runtime` package is
distributed under a BSD-3-Clause license by The Go Authors. bifrost shares no
code with Go — it is an independent reimplementation in Odin — but it follows
Go's design closely and cites the Go source throughout.

## License

MIT. See [LICENSE](LICENSE).
