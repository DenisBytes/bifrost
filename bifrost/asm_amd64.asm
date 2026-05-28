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
