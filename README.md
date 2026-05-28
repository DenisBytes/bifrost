# bifrost

> **Bifröst** — the rainbow bridge between worlds. The name fits a goroutine
> runtime: channels are bridges between independently executing tasks, and the
> scheduler is the bridge between user code and the OS thread that runs it.

`bifrost` is a from-scratch reimplementation of Go's goroutine runtime —
the **scheduler**, **channels**, **`select`**, **sync primitives**, and
(later) **timers** and a **network poller** — written in [Odin](https://odin-lang.org/).

The goal is faithful replication. The implementation tracks Go's runtime
(`src/runtime/`) closely: every exported procedure documents the Go source it
parallels, and every place bifrost diverges from Go records *why* (usually a
limitation of having no compiler instrumentation, unlike Go).

## Status

Early development. The current milestone (Phases 0–4 of [`PLAN.md`](PLAN.md))
builds up to **running goroutines on a single-threaded cooperative
scheduler**: data layout, the x86_64 context switch, fixed-size stacks, and
`go_` / `gosched` / `gopark` / `goready`. Multi-threaded scheduling,
channels, `select`, and `sync` follow in later milestones.

## Platform support

**Linux x86_64 only** for now. The context switch is hand-written SysV AMD64
assembly; other architectures and operating systems come later.

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
