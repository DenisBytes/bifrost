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

@(private = "file")
stop_ok: bool
@(private = "file")
stop_again: bool
@(private = "file")
stop_remaining: int

@(private = "file")
after_stop_body :: proc(arg: rawptr) {
	ch := time_after(time.Hour) // far enough that it can never fire under test
	stop_ok = time_after_stop(ch)
	stop_again = time_after_stop(ch) // idempotent: already gone
	n := 0
	for pp in allp {
		n += len(pp.timers)
	}
	stop_remaining = n
	chan_destroy(ch) // now safe: nothing can fire into it
}

@(test)
test_time_after_stop_cancels :: proc(t: ^testing.T) {
	// Without a cancel path the canonical select-with-timeout loop leaves a live
	// Timer holding the raw ^Hchan on every iteration the data case wins:
	// destroying the channel is a use-after-free, keeping it is an unbounded
	// leak. time_after_stop is what makes `defer chan_destroy` correct.
	stop_ok = false
	stop_again = true
	stop_remaining = -1
	runtime_init(1)
	defer runtime_teardown()
	go_(after_stop_body)
	run()
	testing.expect(t, stop_ok, "time_after_stop must report true for a still-pending timer")
	testing.expect(t, !stop_again, "a second time_after_stop must report false, not re-cancel")
	testing.expectf(t, stop_remaining == 0, "%d timers still queued after cancel", stop_remaining)
}

@(private = "file")
drain_body :: proc(arg: rawptr) {
	// Deliberately leak a pending timer: run() must drop it rather than let a
	// later run() fire it into memory this channel occupied.
	ch := time_after(time.Hour)
	chan_destroy(ch)
}

@(test)
test_run_drains_pending_timers :: proc(t: ^testing.T) {
	runtime_init(1)
	defer runtime_teardown()
	go_(drain_body)
	run()
	n := 0
	for pp in allp {
		n += len(pp.timers)
		testing.expectf(t, pp.ntimers == 0, "P %d: ntimers = %d after run(), want 0", pp.id, pp.ntimers)
	}
	testing.expectf(t, n == 0, "%d timers survived run(); a later run() would fire them into freed memory", n)
}

@(test)
test_time_after_stop_preserves_heap_order :: proc(t: ^testing.T) {
	// Cancelling swaps the last element into the hole, which may need to move UP
	// rather than down — sifting only downward silently corrupts the heap and
	// makes later timers fire out of order.
	runtime_init(1)
	defer runtime_teardown()
	pp := allp[0]
	base := mono_now_ns() + i64(time.Hour)

	chans: [8]Chan(i64)
	for i in 0 ..< 8 {
		chans[i] = chan_make(i64, 1)
		// Descending deadlines, so the entry removed from the middle is usually
		// replaced by one that belongs higher in the heap.
		timer_push(pp, Timer{deadline = base + i64(8 - i) * 1000, f = time_after_fire, arg = rawptr(chans[i].c)})
	}
	testing.expect(t, time_after_stop(chans[3]), "cancel of a queued timer must succeed")
	testing.expect(t, time_after_stop(chans[5]), "cancel of a queued timer must succeed")

	// The heap invariant must still hold everywhere.
	for i in 0 ..< len(pp.timers) {
		l, r := 2 * i + 1, 2 * i + 2
		if l < len(pp.timers) {
			testing.expectf(t, pp.timers[i].deadline <= pp.timers[l].deadline, "heap broken at %d/%d", i, l)
		}
		if r < len(pp.timers) {
			testing.expectf(t, pp.timers[i].deadline <= pp.timers[r].deadline, "heap broken at %d/%d", i, r)
		}
	}
	testing.expectf(t, len(pp.timers) == 6, "len = %d, want 6 after two cancels", len(pp.timers))

	for i in 0 ..< 8 {
		time_after_stop(chans[i])
		chan_destroy(chans[i])
	}
}
