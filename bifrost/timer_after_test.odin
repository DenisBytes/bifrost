package bifrost

import "core:testing"
import "core:time"

// Phase 7.6 acceptance: the canonical select-with-timeout idiom enabled by
// time_after over the timer infrastructure. A select that races a value
// channel against a time_after channel must pick the timeout case when nothing
// arrives within d.

@(private = "file")
ta_data_chan: Chan(int)

@(private = "file")
ta_timeout_fired: bool

@(private = "file")
ta_timeout_select :: proc(arg: rawptr) {
	after_ch := time_after(20 * time.Millisecond)
	defer chan_destroy(after_ch) // safe AFTER the timer fires (chosen==1 below)
	received: int
	tick: i64
	ops := []Select_Op{
		{c = ta_data_chan.c, elem = &received, dir = .Recv},
		{c = after_ch.c, elem = &tick, dir = .Recv},
	}
	chosen, _ := select_(ops[:], true)
	if chosen == 1 {
		ta_timeout_fired = true
	}
}

// No sender on ta_data_chan, so only the timeout case can fire.
@(test)
test_select_with_time_after_fires :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	ta_data_chan = chan_make(int, 0)
	defer chan_destroy(ta_data_chan)

	ta_timeout_fired = false
	go_(ta_timeout_select)
	run()

	testing.expect(t, ta_timeout_fired, "select with time_after did not pick the timeout case")
}
