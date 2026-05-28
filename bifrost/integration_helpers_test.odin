package bifrost

// Integration-test helpers. These files compile only under `odin test` (the
// *_test.odin suffix), so they may freely import os/fmt.
//
// Integration/stress tests call `if integration_skip(t) do return` as their
// first line. When BIFROST_INTEGRATION is unset they bail out, leaving the unit
// suite unaffected; when it is set they print "INTEGRATION_RAN=<test>" so CI can
// confirm the heavy tests actually executed. Mirrors kafka-odin's pattern.

import "core:fmt"
import "core:os"
import "core:testing"

@(private)
INTEGRATION_ENV :: "BIFROST_INTEGRATION"

// integration_skip returns true when BIFROST_INTEGRATION is unset (the unit
// path), in which case the caller should `return` immediately. When set it
// returns false after printing the stdout marker INTEGRATION_RAN=<test-name>.
@(private)
integration_skip :: proc(t: ^testing.T, loc := #caller_location) -> bool {
	_ = t
	val, found := os.lookup_env(INTEGRATION_ENV, context.temp_allocator)
	if !found || len(val) == 0 {
		return true
	}
	fmt.printfln("INTEGRATION_RAN=%s", loc.procedure)
	return false
}
