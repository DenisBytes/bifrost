// spawn launches several goroutines that yield cooperatively, showing the
// basic bifrost API: runtime_init -> go_ -> run, with gosched inside a
// goroutine to hand the processor to its peers.
package main

import "core:fmt"

import bifrost "../../bifrost"

worker :: proc(arg: rawptr) {
	id := int(uintptr(arg))
	fmt.printfln("goroutine %d: hello", id)
	bifrost.gosched()
	fmt.printfln("goroutine %d: resumed after yield", id)
}

main :: proc() {
	bifrost.runtime_init(1)
	// bifrost has no GC: runtime_teardown is what releases the goroutine
	// stacks, the G/M/P structures and the sudog pool. Pair it with every
	// runtime_init.
	defer bifrost.runtime_teardown()

	for i in 1 ..= 5 {
		bifrost.go_(worker, rawptr(uintptr(i)))
	}

	fmt.println("main: spawned 5 goroutines, starting scheduler")
	bifrost.run()
	fmt.println("main: all goroutines finished")
}
