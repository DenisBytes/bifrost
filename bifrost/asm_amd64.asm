; bifrost context-switch primitives — x86_64, System V AMD64 ABI.
;
; These live in hand-written assembly because Odin has no naked-procedure
; attribute: a compiler-inserted prologue/epilogue would clobber the manual
; rsp/rbp rewrites a context switch performs. Linked directly via Odin's
; `@(require) foreign import "asm_amd64.asm"`, the same path Odin's own
; base/runtime no-CRT entry points use.
;
; Model: Go's asm_amd64.s gogo (@402) and mcall (@425).
;
; DEVIATION FROM GO: Go's gobuf saves only sp/pc/bp, because the Go compiler,
; under ABIInternal, spills any live registers to the stack at a switch point.
; bifrost's goroutine functions are ordinary SysV functions whose callee-saved
; registers (rbx, rbp, r12-r15) must survive a call. So bifrost pushes that set
; onto the *suspended* goroutine's own stack (the swapcontext / fcontext
; technique) and pops it on resume. The Gobuf therefore needs only `sp`; `pc`
; and `bp` are recorded for debugging/dumps but the resume address travels on
; the stack as the final `ret` target.
;
; CONSEQUENCE OF THAT CHOICE (load-bearing): because this switch preserves
; callee-saved registers across an OS-thread change, NO thread-derived value may
; be cached in one. The ELF TLS ABI entitles LLVM to treat the thread pointer as
; invariant for a function activation and hoist `mov %fs:0x0` into a callee-saved
; register; that cached base then travels with the goroutine to whatever M
; resumes it and addresses the previous thread's TLS block. Go is immune because
; its compiler dedicates a register to g and reloads it after every preemption
; point; LLVM has no such notion. bifrost compensates in runtime2.odin, where
; getg/getm/setg/setm are @(optimization_mode = "none") and are the only code
; permitted to touch tls_g/tls_m. Removing that attribute miscompiles the
; multi-M scheduler at every optimization level above -o:minimal.
;
; Saved-frame layout, growing down from a stack's top (each slot 8 bytes):
;     [sp + 0]  r15      [sp + 24] r12      [sp + 48] return address (resume pc)
;     [sp + 8]  r14      [sp + 32] rbx
;     [sp + 16] r13      [sp + 40] rbp

bits 64

global gogo
global gosave_switch
global mcall_switch

; Mark the stack as non-executable (avoids an exec-stack linker warning).
section .note.GNU-stack
section .text

; void gogo(Gobuf *to)          ; to in rdi ; never returns
;
; Resumes the context saved in `to`, abandoning the current one. Restores the
; callee-saved registers from the target stack and `ret`s to the saved resume
; address. Used both to enter a freshly built context (see setup_context) and
; to resume one previously saved by gosave_switch. Mirrors Go's gogo.
gogo:
	mov  rsp, [rdi + 0]      ; to.sp -> the saved frame
	pop  r15
	pop  r14
	pop  r13
	pop  r12
	pop  rbx
	pop  rbp
	ret                      ; jump to the saved resume address

; void gosave_switch(Gobuf *from /*rdi*/, Gobuf *to /*rsi*/)
;
; Saves the current execution context into `from`, then resumes `to`. From the
; caller's point of view this returns (normally) once some later switch resumes
; `from`. This is the symmetric "yield to a specific context" primitive (a
; swapcontext); the scheduler's asymmetric switch is mcall_switch (below).
gosave_switch:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov  [rdi + 0], rsp      ; from.sp = sp after saving the callee-saved set
	mov  rax, [rsp + 48]     ; resume address (above the 6 saved registers)
	mov  [rdi + 8], rax       ; from.pc (informational, for dumps)
	mov  [rdi + 40], rbp     ; from.bp (informational, for dumps)
	mov  rsp, [rsi + 0]      ; to.sp -> its saved frame
	pop  r15
	pop  r14
	pop  r13
	pop  r12
	pop  rbx
	pop  rbp
	ret                      ; jump to `to`'s saved resume address

; void mcall_switch(Gobuf *save /*rdi*/, void *fn /*rsi*/, G *gp /*rdx*/, uintptr g0_sp /*rcx*/)
;
; The asymmetric scheduler switch (Go's mcall, asm_amd64.s:425). Saves the
; current goroutine's context into `save` (so a later gogo(save) resumes the
; goroutine right after the mcall returns), switches rsp to the scheduling
; stack `g0_sp`, and calls fn(gp) there. fn must not return (it ends by
; gogo-ing into some goroutine or back to the bootstrap); `ud2` traps if it
; does. g0_sp must be 16-byte aligned.
mcall_switch:
	push rbp
	push rbx
	push r12
	push r13
	push r14
	push r15
	mov  [rdi + 0], rsp      ; save.sp = sp after saving the callee-saved set
	mov  rax, [rsp + 48]     ; resume address (above the 6 saved registers)
	mov  [rdi + 8], rax       ; save.pc (informational)
	mov  [rdi + 40], rbp     ; save.bp (informational)
	mov  rsp, rcx            ; switch to the g0 scheduling stack
	mov  rdi, rdx            ; arg0 = gp
	call rsi                 ; fn(gp) -- must not return
	ud2

; ---------------------------------------------------------------------------
; Test support
; ---------------------------------------------------------------------------

global callee_saved_switch_probe

; uint64 callee_saved_switch_probe(Gobuf *self /*rdi*/, Gobuf *other /*rsi*/)
;
; Loads a distinct sentinel into rbx and r12-r15, suspends via
; gosave_switch(self, other), and once something resumes `self` returns a bitmask
; of the registers that did NOT survive: bit0=rbx, bit1=r12, bit2=r13, bit3=r14,
; bit4=r15. 0 means the round trip preserved all five.
;
; WHY THIS IS IN ASSEMBLY, AND WHY IT SWITCHES DIRECTLY: the property under test
; is that gogo's pops are the exact reverse of gosave_switch/mcall_switch's
; pushes. An Odin callback cannot test it — the compiler emits its own
; save/restore of every callee-saved register it touches, so the callback's
; epilogue silently repairs a mismatched restore before the caller ever sees it.
; (Measured: with gogo's r12/r13 pops deliberately swapped, a probe that called
; an Odin function which yielded still reported all registers intact.) The
; sentinels must therefore be live in the registers across the switch with no
; intervening frame, which means the switch has to happen here.
callee_saved_switch_probe:
	push rbp
	mov  rbp, rsp
	push rbx
	push r12
	push r13
	push r14
	push r15
	sub  rsp, 24             ; scratch + realign: rsp is now 16-byte aligned
	mov  [rbp - 48], rdi     ; self
	mov  [rbp - 56], rsi     ; other

	mov  rbx, 0x1111111111111111
	mov  r12, 0x2222222222222222
	mov  r13, 0x3333333333333333
	mov  r14, 0x4444444444444444
	mov  r15, 0x5555555555555555

	mov  rdi, [rbp - 48]
	mov  rsi, [rbp - 56]
	call gosave_switch       ; suspend; returns when someone resumes `self`

	xor  rax, rax
	mov  rcx, 0x1111111111111111
	cmp  rbx, rcx
	je   .c12
	or   rax, 1
.c12:
	mov  rcx, 0x2222222222222222
	cmp  r12, rcx
	je   .c13
	or   rax, 2
.c13:
	mov  rcx, 0x3333333333333333
	cmp  r13, rcx
	je   .c14
	or   rax, 4
.c14:
	mov  rcx, 0x4444444444444444
	cmp  r14, rcx
	je   .c15
	or   rax, 8
.c15:
	mov  rcx, 0x5555555555555555
	cmp  r15, rcx
	je   .cdone
	or   rax, 16
.cdone:
	add  rsp, 24
	pop  r15
	pop  r14
	pop  r13
	pop  r12
	pop  rbx
	pop  rbp
	ret
