package bifrost

import "core:sys/linux"

// PAGE_SIZE is the assumed virtual page size. x86_64 Linux uses 4 KiB; bifrost
// is x86_64-only for now, so this is hardcoded rather than queried.
PAGE_SIZE :: 4096

// GUARD_SIZE is the size of the PROT_NONE region reserved immediately below
// every goroutine stack. It is deliberately much larger than one page.
//
// DEVIATION: Go does not rely on a guard region at all — its compiler emits a
// stack-bounds check in every function prologue, and for a frame larger than
// StackSmall it emits `LEAQ -(framesize-StackSmall)(SP), tmp; CMPQ tmp,
// stackguard0` plus an explicit underflow branch
// (cmd/internal/obj/x86/obj6.go:995-1050) precisely so that a big frame cannot
// skip the check. Odin emits no such prologue and offers no stack-probe flag
// (-stack-protector is SSP canaries, which do not probe pages), so bifrost must
// compensate with guard SIZE: a frame larger than the guard moves rsp past it
// in a single `sub rsp, N` and its locals land in whatever is mapped below.
// Because stacks are mmap'd back-to-back that is another live goroutine's
// usable stack, and the write does not fault — it surfaces later as gogo
// popping a corrupted saved frame and `ret`-ing into it.
//
// 64 KiB costs address space only: the region is a single mprotect'd VMA either
// way, so the per-goroutine VMA count and the RSS are both unchanged.
GUARD_SIZE :: 64 * 1024

// STACK_MIN is the default usable stack size per goroutine (excluding its guard
// region).
//
// DEVIATION: Go's stackMin is 2 KiB (stack.go:78) and a new goroutine starts at
// that size, growing on demand via compiler-inserted morestack checks. bifrost
// has no morestack — the Odin compiler inserts no stack-growth prologue — so a
// goroutine's entire call tree, including any fmt/reflection it reaches, must
// fit in this fixed allocation, and overflow faults on the guard region rather
// than growing (bounded by GUARD_SIZE; see stack_alloc).
//
// 32 KiB is NOT generous for stock core: code. Measured on this toolchain:
// json.marshal costs roughly 3.5 KiB per level of struct nesting and a depth-8
// struct overflows; fmt's %v on the same value uses about 61% of the budget.
// Callers with deep call trees should raise this. See PLAN 3.4.
STACK_MIN :: 32 * 1024

// Stack_Error reports why a goroutine stack could not be allocated.
Stack_Error :: enum {
	None = 0,
	Out_Of_Memory, // the mmap reservation failed
	Guard_Failed, // protecting the guard page failed
}

// stack_alloc reserves a fixed-size goroutine stack of at least `size` usable
// bytes, preceded by a GUARD_SIZE PROT_NONE region so that overflowing the
// stack faults (SIGSEGV) instead of silently corrupting adjacent memory. It
// returns the usable bounds as a Stack{lo, hi}: the stack pointer starts at hi
// and grows down toward lo; the guard region sits just below lo.
//
// LIMIT OF THE GUARANTEE (see GUARD_SIZE): overflow is caught only for call
// frames smaller than GUARD_SIZE. Odin emits no stack-probe prologue, so a
// single frame larger than the guard steps over it in one `sub rsp, N` and
// writes into the next goroutine's usable stack without faulting. 64 KiB is far
// beyond any frame the toolchain emits in practice, but it is a bound, not an
// absolute.
//
// DEVIATION: Go's stackalloc (stack.go) serves stacks from per-P span caches
// and grows them; bifrost maps one fixed region per goroutine with mmap +
// mprotect and never grows it (see STACK_MIN).
stack_alloc :: proc(size: int = STACK_MIN) -> (s: Stack, err: Stack_Error) {
	usable := align_up(size, PAGE_SIZE)
	total := uint(usable + GUARD_SIZE) // guard region at the low end

	ptr, e := linux.mmap(0, total, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	if e != .NONE {
		return {}, .Out_Of_Memory
	}
	base := uintptr(ptr)

	// Stacks grow down, so the guard protects the low end: an overflow past
	// `lo` runs into it and faults.
	if linux.mprotect(rawptr(base), uint(GUARD_SIZE), {}) != .NONE {
		linux.munmap(ptr, total)
		return {}, .Guard_Failed
	}

	s.lo = base + uintptr(GUARD_SIZE) // first usable byte (just above the guard)
	s.hi = base + uintptr(total) // one past the top of the usable region
	return s, .None
}

// stack_free unmaps a stack previously returned by stack_alloc, including its
// guard region. A zero Stack (lo == 0) is ignored so callers can free
// unconditionally.
stack_free :: proc(s: Stack) {
	if s.lo == 0 {
		return
	}
	base := s.lo - uintptr(GUARD_SIZE) // step back onto the guard region
	total := uint(s.hi - base)
	linux.munmap(rawptr(base), total)
}

// align_up rounds n up to the next multiple of align (align need not be a power
// of two).
@(private)
align_up :: proc "contextless" (n: int, align: int) -> int {
	return ((n + align - 1) / align) * align
}
