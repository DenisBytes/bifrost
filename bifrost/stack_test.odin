package bifrost

import "core:testing"

@(test)
test_stack_alloc_default :: proc(t: ^testing.T) {
	s, err := stack_alloc()
	testing.expectf(t, err == .None, "stack_alloc err = %v", err)
	defer stack_free(s)

	usable := int(s.hi - s.lo)
	testing.expectf(t, usable >= STACK_MIN, "usable = %d, want >= %d", usable, STACK_MIN)
	testing.expect(t, s.lo % PAGE_SIZE == 0, "lo not page-aligned")
	testing.expect(t, s.hi % PAGE_SIZE == 0, "hi not page-aligned")
}

@(test)
test_stack_alloc_custom_size :: proc(t: ^testing.T) {
	s, err := stack_alloc(64 * 1024)
	testing.expectf(t, err == .None, "stack_alloc err = %v", err)
	defer stack_free(s)

	usable := int(s.hi - s.lo)
	testing.expectf(t, usable >= 64 * 1024, "usable = %d, want >= 65536", usable)
}

@(test)
test_stack_is_writable_end_to_end :: proc(t: ^testing.T) {
	// The whole usable range [lo, hi) must be writable: touch the lowest and
	// highest usable bytes. If the guard page were misplaced (inside the usable
	// range) this would fault.
	s, err := stack_alloc()
	testing.expectf(t, err == .None, "stack_alloc err = %v", err)
	defer stack_free(s)

	lo_byte := cast(^u8)s.lo
	hi_byte := cast(^u8)(s.hi - 1)
	lo_byte^ = 0xAB
	hi_byte^ = 0xCD
	testing.expect(t, lo_byte^ == 0xAB, "low byte not writable")
	testing.expect(t, hi_byte^ == 0xCD, "high byte not writable")
}

@(test)
test_stack_free_zero_is_safe :: proc(t: ^testing.T) {
	// Freeing a zero Stack must be a no-op (callers free unconditionally).
	stack_free(Stack{})
}

@(test)
test_align_up :: proc(t: ^testing.T) {
	testing.expect(t, align_up(0, 4096) == 0, "align_up(0)")
	testing.expect(t, align_up(1, 4096) == 4096, "align_up(1)")
	testing.expect(t, align_up(4096, 4096) == 4096, "align_up(4096)")
	testing.expect(t, align_up(4097, 4096) == 8192, "align_up(4097)")
}
