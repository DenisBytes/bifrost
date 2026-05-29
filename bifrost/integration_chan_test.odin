package bifrost

import "base:intrinsics"
import "core:testing"

// Phase 6.7 acceptance, gated on BIFROST_INTEGRATION. These run on gomaxprocs=4
// real OS threads, so the channel rendezvous happen cross-thread: the worker
// pool exercises the buffered ring + close-drain under contention, and the
// ping-pong exercises the unbuffered synchronous handoff round after round.

@(private = "file")
WP_N :: 10000

@(private = "file")
WP_CONSUMERS :: 4

@(private = "file")
wp_chan: Chan(int)

@(private = "file")
wp_sum: i64

@(private = "file")
wp_count: i64

@(private = "file")
wp_producer :: proc(arg: rawptr) {
	for i in 1 ..= WP_N {
		chan_send(wp_chan, i)
	}
	chan_close(wp_chan) // signal consumers to stop once the buffer drains
}

@(private = "file")
wp_consumer :: proc(arg: rawptr) {
	for {
		v, ok := chan_recv(wp_chan)
		if !ok {
			break // channel closed and drained
		}
		intrinsics.atomic_add(&wp_sum, i64(v))
		intrinsics.atomic_add(&wp_count, 1)
	}
}

// Classic worker pool: one producer streams 1..WP_N through a small buffered
// channel; WP_CONSUMERS drain concurrently until close. Every value is consumed
// exactly once, so the count and the sum are exact.
@(test)
test_integration_chan_worker_pool :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	wp_chan = chan_make(int, 16)
	defer chan_destroy(wp_chan)

	wp_sum = 0
	wp_count = 0
	go_(wp_producer)
	for _ in 0 ..< WP_CONSUMERS {
		go_(wp_consumer)
	}
	run()

	want_sum := i64(WP_N) * i64(WP_N + 1) / 2
	testing.expectf(t, wp_count == WP_N, "consumed %d, want %d", wp_count, WP_N)
	testing.expectf(t, wp_sum == want_sum, "sum = %d, want %d", wp_sum, want_sum)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

@(private = "file")
PP_K :: 1000

@(private = "file")
pp_ping: Chan(int)

@(private = "file")
pp_pong: Chan(int)

@(private = "file")
pp_rounds: i64

@(private = "file")
pp_player_a :: proc(arg: rawptr) {
	for _ in 0 ..< PP_K {
		chan_send(pp_ping, 1)
		_, _ = chan_recv(pp_pong)
	}
}

@(private = "file")
pp_player_b :: proc(arg: rawptr) {
	for _ in 0 ..< PP_K {
		_, _ = chan_recv(pp_ping)
		intrinsics.atomic_add(&pp_rounds, 1)
		chan_send(pp_pong, 2)
	}
}

// Unbuffered ping-pong: two goroutines alternate a value across two unbuffered
// channels for PP_K rounds. Each step is a synchronous handoff, and with 4 Ms
// the two players typically sit on different threads, so every round is a
// cross-M rendezvous.
@(test)
test_integration_chan_ping_pong :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	pp_ping = chan_make(int, 0)
	defer chan_destroy(pp_ping)
	pp_pong = chan_make(int, 0)
	defer chan_destroy(pp_pong)

	pp_rounds = 0
	go_(pp_player_a)
	go_(pp_player_b)
	run()

	testing.expectf(t, pp_rounds == PP_K, "rounds = %d, want %d", pp_rounds, PP_K)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}

@(private = "file")
SEL_N :: 2000

@(private = "file")
sel_c1: ^Hchan

@(private = "file")
sel_c2: ^Hchan

@(private = "file")
sel_sum: i64

@(private = "file")
sel_count: i64

@(private = "file")
sel_prod1 :: proc(arg: rawptr) {
	for i in 1 ..= SEL_N {
		v := i
		chansend(sel_c1, &v, true)
	}
	close_chan(sel_c1)
}

@(private = "file")
sel_prod2 :: proc(arg: rawptr) {
	for i in 1 ..= SEL_N {
		v := i
		chansend(sel_c2, &v, true)
	}
	close_chan(sel_c2)
}

// Each consumer multiplexes both channels with select, disabling a case (nil
// channel) once it closes, until both are drained — the idiomatic Go fan-in.
@(private = "file")
sel_consumer :: proc(arg: rawptr) {
	o1, o2: int
	ops := [2]Select_Op{{c = sel_c1, elem = &o1, dir = .Recv}, {c = sel_c2, elem = &o2, dir = .Recv}}
	for ops[0].c != nil || ops[1].c != nil {
		chosen, ok := select_(ops[:], true)
		if !ok {
			ops[chosen].c = nil // closed and drained: drop this case
			continue
		}
		v := o1
		if chosen == 1 {
			v = o2
		}
		intrinsics.atomic_add(&sel_sum, i64(v))
		intrinsics.atomic_add(&sel_count, 1)
	}
}

// Cross-M select fan-in: two producers stream into two channels and close them;
// three consumers select-multiplex both across 4 OS threads. This drives select
// parking/waking cross-thread, the loser-sudog dequeue (each parked consumer is
// queued on both channels), and close waking a parked selector — all under load.
@(test)
test_integration_select_fan_in :: proc(t: ^testing.T) {
	if integration_skip(t) do return

	runtime_init(4)
	defer runtime_teardown()
	sel_c1 = make_chan(size_of(int), 8)
	defer destroy_chan(sel_c1)
	sel_c2 = make_chan(size_of(int), 8)
	defer destroy_chan(sel_c2)

	sel_sum = 0
	sel_count = 0
	go_(sel_prod1)
	go_(sel_prod2)
	for _ in 0 ..< 3 {
		go_(sel_consumer)
	}
	run()

	want_count := i64(2 * SEL_N)
	per_producer := i64(SEL_N) * i64(SEL_N + 1) / 2
	testing.expectf(t, sel_count == want_count, "received %d, want %d", sel_count, want_count)
	testing.expectf(t, sel_sum == 2 * per_producer, "sum = %d, want %d", sel_sum, 2 * per_producer)
	testing.expectf(t, live_goroutines() == 0, "live goroutines = %d, want 0", live_goroutines())
}
