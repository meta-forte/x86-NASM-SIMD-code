;═══════════════════════════════════════════════════════════════════════════════
; §02  Arith Library
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 02_arith_lib.asm
;  Description : C-callable add/sub/mul/div/mod — System V ABI, IDIV, CQO
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 02_arith_lib.asm — Integer arithmetic functions callable from C
; Goal: understand parameter passing, return values, and the System V ABI
;
; System V AMD64 ABI (used by Linux/macOS):
;   Integer/pointer arguments are passed in registers, left-to-right:
;     1st arg → rdi
;     2nd arg → rsi
;     3rd arg → rdx
;     4th arg → rcx
;     5th arg → r8
;     6th arg → r9
;     Additional args → pushed onto the stack (right to left)
;
;   Integer return value → rax
;   128-bit return value → rdx:rax
;
;   Callee-saved (function MUST restore these before returning):
;     rbx, rbp, r12, r13, r14, r15
;
;   Caller-saved (function MAY clobber these freely):
;     rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11
;
; We expose three functions:
;   int64_t asm_add(int64_t a, int64_t b)
;   int64_t asm_sub(int64_t a, int64_t b)
;   int64_t asm_mul(int64_t a, int64_t b)
;
; Build (as a library linked with C):
;   nasm -f elf64 02_arith_lib.asm -o bin/02_arith_lib.o
;   gcc arith_test.c bin/02_arith_lib.o -o bin/02_arith_test -no-pie
; Run:
;   ./bin/02_arith_test
;
; If you want a standalone test without C, also see 02_arith_standalone below.
; ═══════════════════════════════════════════════════════════════════════════════

section .text

global asm_add              ; expose asm_add symbol to the C linker
global asm_sub              ; expose asm_sub symbol to the C linker
global asm_mul              ; expose asm_mul symbol to the C linker
global asm_div              ; expose asm_div symbol to the C linker
global asm_mod              ; expose asm_mod symbol to the C linker

; ───────────────────────────────────────────────────────────────────────────
; asm_add — add two signed 64-bit integers
;   C prototype: int64_t asm_add(int64_t a, int64_t b);
;   Input:  rdi = a  (first argument — per ABI)
;           rsi = b  (second argument — per ABI)
;   Output: rax = a + b
;
;   Note: we don't strictly need 'push rbp / mov rbp, rsp' for a leaf function
;   this simple, but we include it for consistency and to make backtraces work.
; ───────────────────────────────────────────────────────────────────────────
asm_add:
    push rbp                ; save caller's base pointer (rbp is callee-saved — we must restore it)
    mov  rbp, rsp           ; set our own base pointer = current stack top (establishes frame)

    mov  rax, rdi           ; rax = a — copy first argument into the return-value register
    add  rax, rsi           ; rax = a + b — add second argument to rax

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return to caller; rax holds the result

; ───────────────────────────────────────────────────────────────────────────
; asm_sub — subtract b from a
;   C prototype: int64_t asm_sub(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a - b
; ───────────────────────────────────────────────────────────────────────────
asm_sub:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — copy first argument to return register
    sub  rax, rsi           ; rax = a - b — subtract second argument

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds result

; ───────────────────────────────────────────────────────────────────────────
; asm_mul — multiply two signed 64-bit integers
;   C prototype: int64_t asm_mul(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a * b (lower 64 bits; upper 64 bits discarded)
;
;   IMUL with two operands: IMUL dst, src → dst = dst * src
;   The upper 64 bits of the full 128-bit product would go into rdx, but
;   we don't need them for normal integer multiplication.
; ───────────────────────────────────────────────────────────────────────────
asm_mul:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — start with first argument in return register
    imul rax, rsi           ; rax = a * b — signed multiply; lower 64 bits in rax

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds lower 64 bits of product

; ───────────────────────────────────────────────────────────────────────────
; asm_div — signed integer division
;   C prototype: int64_t asm_div(int64_t a, int64_t b);
;   Input:  rdi = a (dividend), rsi = b (divisor)
;   Output: rax = a / b (quotient)
;
;   IDIV instruction:
;     Divides rdx:rax (128-bit) by the operand.
;     Before IDIV: sign-extend rax into rdx using CQO (convert quadword to octword).
;     After IDIV: rax = quotient, rdx = remainder.
; ───────────────────────────────────────────────────────────────────────────
asm_div:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — load dividend into rax for IDIV
    cqo                     ; sign-extend rax into rdx:rax (rdx = sign-extension of rax)
                            ; this prepares the 128-bit dividend that IDIV expects
    idiv rsi                ; signed divide rdx:rax by rsi: rax = quotient, rdx = remainder

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds quotient

; ───────────────────────────────────────────────────────────────────────────
; asm_mod — signed integer modulo (remainder)
;   C prototype: int64_t asm_mod(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a % b (remainder)
; ───────────────────────────────────────────────────────────────────────────
asm_mod:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — dividend into rax
    cqo                     ; sign-extend rax into rdx:rax (prepare 128-bit dividend)
    idiv rsi                ; rax = quotient, rdx = remainder

    mov  rax, rdx           ; rax = rdx = remainder (move result to return register)

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds the remainder
