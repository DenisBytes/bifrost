// pingpong runs two goroutines that take turns printing, handing control back
// and forth with gosched. It mirrors the Phase 2 context-switch ping-pong, but
// driven by the cooperative scheduler instead of the raw primitives.
package main

import "core:fmt"

import bifrost "../../bifrost"

ROUNDS :: 3

ping :: proc(arg: rawptr) {
	for i in 0 ..< ROUNDS {
		fmt.println("ping")
		bifrost.gosched()
	}
}

pong :: proc(arg: rawptr) {
	for i in 0 ..< ROUNDS {
		fmt.println("pong")
		bifrost.gosched()
	}
}

main :: proc() {
	bifrost.runtime_init(1)
	bifrost.go_(ping)
	bifrost.go_(pong)
	bifrost.run()
	fmt.println("done")
}
