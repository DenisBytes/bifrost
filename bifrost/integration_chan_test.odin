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
