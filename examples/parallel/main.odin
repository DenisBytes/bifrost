// parallel runs goroutines across multiple OS threads. With runtime_init(4) the
// scheduler uses 4 Ps and 4 OS threads, so the goroutines execute in parallel;
// the shared counter is bumped atomically and printed once at the end (printing
// from the goroutines themselves would interleave).
package main

import "base:intrinsics"
import "core:fmt"

import bifrost "../../bifrost"

N :: 1000

counter: i64

worker :: proc(arg: rawptr) {
	intrinsics.atomic_add(&counter, 1)
	bifrost.gosched()
}

main :: proc() {
	bifrost.runtime_init(4)

	for _ in 0 ..< N {
		bifrost.go_(worker)
	}

	bifrost.run()
	fmt.printfln("ran %d goroutines across 4 OS threads; counter = %d", N, counter)
}
