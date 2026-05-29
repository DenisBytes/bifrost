// chan demonstrates the channel worker-pool idiom on bifrost: a producer streams
// jobs through a buffered channel and closes it; several worker goroutines drain
// it concurrently across OS threads until the close signals completion. The
// typed Chan(T) API gives type-safe send/recv over the runtime's channel core.
package main

import "base:intrinsics"
import "core:fmt"

import bifrost "../../bifrost"

N :: 100

jobs: bifrost.Chan(int)

sum_of_squares: i64

producer :: proc(arg: rawptr) {
	for i in 1 ..= N {
		bifrost.chan_send(jobs, i)
	}
	bifrost.chan_close(jobs) // tells workers to stop once the buffer drains
}

worker :: proc(arg: rawptr) {
	for {
		v, ok := bifrost.chan_recv(jobs)
		if !ok {
			break
		}
		intrinsics.atomic_add(&sum_of_squares, i64(v) * i64(v))
	}
}

main :: proc() {
	bifrost.runtime_init(4)
	jobs = bifrost.chan_make(int, 8)

	bifrost.go_(producer)
	for _ in 0 ..< 3 {
		bifrost.go_(worker)
	}

	bifrost.run()
	bifrost.chan_destroy(jobs)

	fmt.printfln("3 workers summed squares of 1..%d across 4 OS threads = %d", N, sum_of_squares)
}
