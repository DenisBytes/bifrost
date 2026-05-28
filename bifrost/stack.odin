package bifrost

import "core:sys/linux"

// PAGE_SIZE is the assumed virtual page size. x86_64 Linux uses 4 KiB; bifrost
// is x86_64-only for now, so this is hardcoded rather than queried.
PAGE_SIZE :: 4096

// STACK_MIN is the default usable stack size per goroutine (excluding its guard
// page).
//
// DEVIATION: Go's _StackMin is 8 KiB and Go grows stacks on demand via
// compiler-inserted morestack checks (stack.go). bifrost has no morestack — the
// Odin compiler inserts no stack-growth prologue — so a goroutine's entire call
// tree must fit in this fixed allocation. bifrost therefore starts larger
// (16 KiB) and never grows. See PLAN 3.4.
STACK_MIN :: 16 * 1024

// Stack_Error reports why a goroutine stack could not be allocated.
Stack_Error :: enum {
	None = 0,
	Out_Of_Memory, // the mmap reservation failed
	Guard_Failed, // protecting the guard page failed
}

// stack_alloc reserves a fixed-size goroutine stack of at least `size` usable
// bytes, preceded by a PROT_NONE guard page so that overflowing the stack
// faults (SIGSEGV) instead of silently corrupting adjacent memory. It returns
// the usable bounds as a Stack{lo, hi}: the stack pointer starts at hi and
// grows down toward lo; the guard page sits just below lo.
//
// DEVIATION: Go's stackalloc (stack.go) serves stacks from per-P span caches
// and grows them; bifrost maps one fixed region per goroutine with mmap +
// mprotect and never grows it (see STACK_MIN).
stack_alloc :: proc(size: int = STACK_MIN) -> (s: Stack, err: Stack_Error) {
	usable := align_up(size, PAGE_SIZE)
	total := uint(usable + PAGE_SIZE) // one guard page at the low end

	ptr, e := linux.mmap(0, total, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if e != .NONE {
		return {}, .Out_Of_Memory
	}
	base := uintptr(ptr)

	// Stacks grow down, so the guard page protects the low end: an overflow
	// past `lo` runs into it and faults.
	if linux.mprotect(rawptr(base), uint(PAGE_SIZE), {}) != .NONE {
		linux.munmap(ptr, total)
		return {}, .Guard_Failed
	}

	s.lo = base + uintptr(PAGE_SIZE) // first usable byte (just above the guard)
	s.hi = base + uintptr(total) // one past the top of the usable region
	return s, .None
}

// stack_free unmaps a stack previously returned by stack_alloc, including its
// guard page. A zero Stack (lo == 0) is ignored so callers can free
// unconditionally.
stack_free :: proc(s: Stack) {
	if s.lo == 0 {
		return
	}
	base := s.lo - uintptr(PAGE_SIZE) // step back onto the guard page
	total := uint(s.hi - base)
	linux.munmap(rawptr(base), total)
}

// align_up rounds n up to the next multiple of align (align need not be a power
// of two).
@(private)
align_up :: proc "contextless" (n: int, align: int) -> int {
	return ((n + align - 1) / align) * align
}
