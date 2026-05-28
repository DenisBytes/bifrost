// Package bifrost is a from-scratch reimplementation of Go's goroutine
// runtime — the scheduler, channels, select, sync primitives, and (later)
// timers and a network poller — written in Odin.
//
// The name is the Bifröst, the rainbow bridge of Norse myth: channels are
// the bridges between independently executing goroutines, and the scheduler
// is the bridge between user code and the OS thread that runs it.
//
// The implementation tracks Go's runtime (/home/denisbytes/dev/go/src/runtime)
// closely: every exported procedure documents the Go source it parallels and
// any deliberate deviation. Linux x86_64 only for now.
package bifrost

// VERSION is the current bifrost revision. bifrost follows Go's G-M-P
// scheduling model; see PLAN.md for the implementation roadmap.
VERSION :: "0.0.0-dev"
