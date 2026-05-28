// hello is the smallest bifrost program: it imports the runtime package and
// prints "ok", proving the build and link pipeline works end to end before
// any real runtime code lands.
package main

import "core:fmt"

import bifrost "../../bifrost"

main :: proc() {
	fmt.printfln("bifrost %s: ok", bifrost.VERSION)
}
