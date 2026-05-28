package bifrost

// Foreign declarations for the context-switch primitives implemented in
// asm_amd64.asm, plus the Odin-side helper that builds a fresh saved frame.
// See that file for the rationale (Odin has no naked procedures), the Go
// references (asm_amd64.s gogo @402, mcall @425), and the saved-frame layout.
//
// bifrost targets Linux x86_64 only for now; the import is arch-guarded so a
// future port adds asm_<arch>.asm alongside without touching call sites.

when ODIN_ARCH == .amd64 {

	@(require)
	foreign import asm_ctx "asm_amd64.asm"

	foreign asm_ctx {
		// gogo resumes the context saved in `to`, abandoning the current one;
		// it does not return. Used to enter a freshly built context
		// (setup_context) or resume one saved by gosave_switch. Mirrors Go's
		// gogo (asm_amd64.s:402).
		gogo :: proc "c" (to: ^Gobuf) ---

		// gosave_switch saves the current context into `from` and resumes `to`.
		// It returns (normally) when some later switch resumes `from`. The
		// symmetric "yield to a specific context" primitive (a swapcontext);
		// the scheduler's asymmetric mcall is built on the same ideas in
		// Phase 4.
		gosave_switch :: proc "c" (from: ^Gobuf, to: ^Gobuf) ---

		// mcall_switch saves the current context into `save`, switches to the
		// scheduling stack `g0_sp`, and calls fn(gp) there. fn must not return.
		// The building block of mcall (proc.odin). Mirrors Go's mcall
		// (asm_amd64.s:425).
		mcall_switch :: proc "c" (save: ^Gobuf, fn: rawptr, gp: ^G, g0_sp: uintptr) ---
	}

	// CTX_SAVED_REGS is the number of callee-saved registers gosave_switch
	// pushes and gogo/gosave_switch pop (rbp, rbx, r12, r13, r14, r15).
	@(private)
	CTX_SAVED_REGS :: 6

	// setup_context initializes buf so that gogo(buf) begins executing `entry`
	// on stack_mem. It lays out the top of stack_mem to match the frame the asm
	// pops: CTX_SAVED_REGS zeroed callee-saved slots followed by `entry` as the
	// resume address, 16-byte aligned to satisfy the SysV entry convention
	// (rsp % 16 == 8 at the first instruction of `entry`).
	//
	// The six register slots are zeroed explicitly so a reused (non-fresh)
	// stack starts the goroutine with clean callee-saved registers.
	@(private)
	setup_context :: proc(buf: ^Gobuf, entry: rawptr, stack_mem: []u8) {
		top := (uintptr(raw_data(stack_mem)) + uintptr(len(stack_mem))) &~ uintptr(15)
		// 6 saved regs + return-address slot + 1 pad slot == 64 bytes keeps sp
		// 16-aligned (top is 16-aligned).
		sp := top - uintptr((CTX_SAVED_REGS + 2) * 8)

		for i in 0 ..< CTX_SAVED_REGS {
			(cast(^uintptr)(sp + uintptr(i * 8)))^ = 0
		}
		(cast(^uintptr)(sp + uintptr(CTX_SAVED_REGS * 8)))^ = uintptr(entry)

		buf.sp = sp
		buf.pc = uintptr(entry)
		buf.bp = 0
	}

} else {
	#panic("bifrost currently supports x86_64 (amd64) only")
}
