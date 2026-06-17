;═══════════════════════════════════════════════════════════════════════════════
; §17  Dot Product
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 17_dot_product.asm
;  Description : Float dot product: scalar MOVSS/MULSS/ADDSS vs SSE HADDPS
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 17_dot_product.asm — Dot product of two float arrays: scalar then SSE
; Goal: floating-point loads and stores, FP accumulation, SSE packed operations
;
; The dot product of vectors A and B is:
;   result = A[0]*B[0] + A[1]*B[1] + ... + A[n-1]*B[n-1]
;
; We implement two versions:
;
; 1. SCALAR: process one float at a time using SSE scalar instructions
;    MOVSS  — move scalar single-precision float (32-bit)
;    MULSS  — multiply scalar single-precision floats
;    ADDSS  — add scalar single-precision floats
;
; 2. SSE PACKED: process 4 floats at a time using 128-bit XMM registers
;    MOVUPS — move unaligned packed single-precision floats (4 floats, 16 bytes)
;    MULPS  — multiply 4 pairs of floats in parallel
;    ADDPS  — add 4 pairs of floats in parallel
;    Horizontal sum: add the 4 lanes of the accumulator at the end
;      HADDPS xmm0, xmm0 — add adjacent pairs: (a+b, c+d, a+b, c+d)
;      HADDPS xmm0, xmm0 — add those pairs:    (a+b+c+d, ...)
;
; Build:
;   nasm -f elf64 17_dot_product.asm -o bin/17_dot_product.o
;   ld bin/17_dot_product.o -o bin/17_dot_product
; Run:
;   ./bin/17_dot_product
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test vectors — 8 floats each
    ; Dot product = 1*2 + 2*3 + 3*4 + 4*5 + 5*6 + 6*7 + 7*8 + 8*9
    ;             = 2 + 6 + 12 + 20 + 30 + 42 + 56 + 72
    ;             = 240
    align 16                            ; 16-byte align for SSE loads
    vec_a  dd 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0
    vec_b  dd 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0
    vec_n  equ 8                        ; number of elements

    lbl_scalar  db "Scalar dot product  = ", 0
    lbl_sse     db "SSE    dot product  = ", 0
    newline     db 10

section .bss
    float_str  resb 32       ; buffer for float → string conversion

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; dot_scalar — compute dot product using scalar SSE instructions (one float/iter)
;   Input:  rdi = pointer to float array A
;           rsi = pointer to float array B
;           rdx = number of elements n
;   Output: xmm0 = dot product (single-precision float)
; ───────────────────────────────────────────────────────────────────────────
dot_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xorps xmm0, xmm0       ; xmm0 = 0.0 — clear accumulator (XOR with self zeros the register)
    xor   rcx, rcx          ; rcx = 0 — loop index

.ds_loop:
    cmp  rcx, rdx           ; have we processed all n elements?
    jge  .ds_done           ; yes — return the accumulated sum

    movss xmm1, [rdi + rcx*4]  ; xmm1 = A[i] — load one 32-bit float from array A
                                ;   rcx*4 = byte offset (each float = 4 bytes)
    mulss xmm1, [rsi + rcx*4]  ; xmm1 = A[i] * B[i] — multiply by B[i]
                                ;   MULSS: Multiply Scalar Single-precision — operates on low float
    addss xmm0, xmm1            ; xmm0 += A[i] * B[i] — accumulate into result
                                ;   ADDSS: Add Scalar Single-precision — adds low 32 bits of xmm1 to xmm0

    inc  rcx                ; i++ — advance to next element
    jmp  .ds_loop           ; loop

.ds_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; xmm0 holds the dot product

; ───────────────────────────────────────────────────────────────────────────
; dot_sse — compute dot product using SSE packed instructions (4 floats/iter)
;   Input:  rdi = pointer to float array A (ideally 16-byte aligned)
;           rsi = pointer to float array B (ideally 16-byte aligned)
;           rdx = number of elements n (we handle n % 4 tail separately)
;   Output: xmm0 = dot product
;
;   XMM register layout (128 bits = 4 x 32-bit floats):
;   [bits 127:96 | bits 95:64 | bits 63:32 | bits 31:0]
;   [  float[3]  |  float[2]  |  float[1]  |  float[0] ]
; ───────────────────────────────────────────────────────────────────────────
dot_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xorps xmm0, xmm0       ; xmm0 = {0.0, 0.0, 0.0, 0.0} — 4-lane accumulator, all zeros

    ; Process 4 floats per iteration
    mov  rcx, rdx           ; rcx = n
    shr  rcx, 2             ; rcx = n/4 — number of 4-float groups
    xor  r8, r8             ; r8 = 0 — byte index (advances by 16 per iteration)

.ds4_loop:
    test rcx, rcx           ; any groups left?
    jz   .ds4_tail          ; no — handle the tail

    movups xmm1, [rdi + r8]    ; xmm1 = {A[i+3], A[i+2], A[i+1], A[i+0]} — 4 floats from A
                                ;   MOVUPS: Move Unaligned Packed Singles — works even if not 16-aligned
    movups xmm2, [rsi + r8]    ; xmm2 = {B[i+3], B[i+2], B[i+1], B[i+0]} — 4 floats from B

    mulps  xmm1, xmm2          ; xmm1 = {A[i+3]*B[i+3], A[i+2]*B[i+2], A[i+1]*B[i+1], A[i+0]*B[i+0]}
                                ;   MULPS: Multiply Packed Singles — multiplies all 4 lanes in parallel

    addps  xmm0, xmm1          ; xmm0 += xmm1 — accumulate all 4 products into the 4-lane accumulator
                                ;   ADDPS: Add Packed Singles — adds 4 pairs of floats

    add  r8, 16             ; advance byte index by 16 (4 floats × 4 bytes each)
    dec  rcx                ; decrement group counter
    jmp  .ds4_loop          ; loop

.ds4_tail:
    ; Handle remaining elements (0 to 3 leftover floats)
    mov  rcx, rdx           ; rcx = n
    and  rcx, 3             ; rcx = n % 4 — number of leftover floats
    jz   .ds4_hsum          ; no tail — go directly to horizontal sum

    ; r8 already points to the right position (byte offset after the groups)
    ; Process remaining floats one at a time using scalar SSE
    xor  r9, r9             ; r9 = tail index (elements, not bytes)
.ds4_tail_loop:
    cmp  r9, rcx            ; all tail elements processed?
    jge  .ds4_hsum          ; yes

    ; Compute byte offset = r8 + r9*4; store in rax to avoid 3-register SIB
    lea  rax, [r8 + r9*4]           ; rax = byte offset of tail element
    movss xmm1, [rdi + rax]         ; xmm1 = A[tail_i] — scalar load from array A
    mulss xmm1, [rsi + rax]         ; xmm1 = A[tail_i] * B[tail_i] — scalar multiply
    addss xmm0, xmm1                ; xmm0[0] += product — accumulate into low lane
                                    ; (only xmm0 lane 0 is updated; other lanes unchanged)
    inc  r9
    jmp  .ds4_tail_loop

.ds4_hsum:
    ; Horizontal sum: collapse the 4-lane accumulator xmm0 = {d,c,b,a} into a single float
    ;
    ; Step 1: HADDPS xmm0, xmm0
    ;   Before: xmm0 = {d, c, b, a}
    ;   After:  xmm0 = {d+c, b+a, d+c, b+a}   — adds adjacent pairs
    ;   (HADDPS: Horizontal ADD Packed Singles)
    ;
    ; Step 2: HADDPS xmm0, xmm0
    ;   Before: xmm0 = {d+c, b+a, d+c, b+a}
    ;   After:  xmm0 = {(d+c)+(b+a), (d+c)+(b+a), ...}
    ;   Now all 4 lanes hold the same value: a+b+c+d
    ;
    ; The final result is in xmm0[0] (the lowest 32 bits).

    haddps xmm0, xmm0       ; Step 1: pairwise horizontal add
    haddps xmm0, xmm0       ; Step 2: pairwise horizontal add again — all lanes now = sum

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; xmm0[0] (and all lanes) = dot product

; ───────────────────────────────────────────────────────────────────────────
; print_float — print a single-precision float to stdout (approximate, integer part + 4 decimals)
;   Input:  xmm0 = float to print
;
;   We use CVTTSS2SI to truncate to integer, subtract to get fractional part,
;   and multiply to extract decimal digits. This is educational but not fully
;   general (doesn't handle negatives or very large floats).
; ───────────────────────────────────────────────────────────────────────────
print_float:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)

    ; Extract integer part
    cvttss2si rax, xmm0     ; rax = (int64_t) floor(xmm0) — truncate to integer
                            ; CVTTSS2SI: ConVerT Truncating Scalar Single to Integer
    push rax                ; save integer part

    ; Integer part → string
    mov  r12, float_str     ; r12 = start of output buffer
    mov  rbx, float_str     ; rbx = write position

    mov  rdi, rax           ; rdi = integer value
    ; Inline integer conversion
    test rax, rax
    jnz  .pf_intdig
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pf_dot
.pf_intdig:
    xor  rdx, rdx           ; rdx = 0 — high half
    mov  rcx, 10            ; divisor
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pf_intdig

    ; Reverse integer part in buffer
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pf_rv:
    cmp  rsi, rdi
    jge  .pf_dot
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pf_rv

.pf_dot:
    mov  byte [rbx], '.'    ; write decimal point
    inc  rbx                ; advance

    ; Extract fractional part: xmm0 - floor(xmm0)
    pop  rax                ; restore integer part
    cvtsi2ss xmm1, rax      ; xmm1 = (float) integer part
                            ; CVTSI2SS: ConVerT Signed Integer to Scalar Single
    subss xmm0, xmm1        ; xmm0 = fractional part = original - integer_part

    ; Multiply fractional part by 10 four times to get 4 decimal digits
    mov  rcx, 4             ; rcx = 4 digits to extract
    mov  r8d, 10            ; r8d = 10 (we'll use this to multiply)
    cvtsi2ss xmm2, r8d      ; xmm2 = 10.0
.pf_frac:
    mulss xmm0, xmm2        ; xmm0 = frac * 10 — shift decimal point right
    cvttss2si rax, xmm0     ; rax = (int) floor(frac * 10) — extract next digit
    cvtsi2ss xmm1, rax      ; xmm1 = (float) digit
    subss xmm0, xmm1        ; xmm0 = (frac * 10) - digit — remove the extracted digit
    add  al, '0'            ; convert digit to ASCII
    mov  [rbx], al          ; store in buffer
    inc  rbx                ; advance
    dec  rcx                ; one fewer digit to extract
    jnz  .pf_frac           ; loop

.pf_null:
    mov  byte [rbx], 0      ; null-terminate
    mov  rdx, rbx           ; end pointer
    sub  rdx, r12           ; rdx = length
    mov  rsi, r12           ; rsi = string start
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall                 ; write the float string

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; length = 0
.pc_l:
    cmp  byte [rdi + rcx], 0
    je   .pc_w
    inc  rcx
    jmp  .pc_l
.pc_w:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Scalar dot product ──
    mov  rdi, lbl_scalar    ; "Scalar dot product  = "
    call print_cstr

    mov  rdi, vec_a         ; rdi = pointer to A
    mov  rsi, vec_b         ; rsi = pointer to B
    mov  rdx, vec_n         ; rdx = number of elements (8)
    call dot_scalar         ; xmm0 = dot product

    call print_float        ; print xmm0

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE packed dot product ──
    mov  rdi, lbl_sse       ; "SSE    dot product  = "
    call print_cstr

    mov  rdi, vec_a         ; rdi = pointer to A
    mov  rsi, vec_b         ; rsi = pointer to B
    mov  rdx, vec_n         ; rdx = number of elements (8)
    call dot_sse            ; xmm0 = dot product

    call print_float        ; print xmm0

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)
