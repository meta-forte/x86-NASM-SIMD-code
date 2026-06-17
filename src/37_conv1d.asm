;═══════════════════════════════════════════════════════════════════════════════
; §07  1-D Convolution
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 07_conv1d.asm
;  Description : 3-tap FIR filter: scalar MAC loop vs SSE2 PMADDWD
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 07_conv1d.asm — 1D convolution with a 3-tap kernel on 16-bit samples
; Goal: multiply-accumulate patterns in scalar and SSE2
;
; 1D convolution: out[i] = k0*in[i-1] + k1*in[i] + k2*in[i+1]
; This is a 3-tap FIR filter. "Tap" = number of kernel coefficients.
; Border pixels (i=0, i=n-1) use zero-padding (out-of-bounds inputs = 0).
;
; Samples are int16_t (16-bit signed integers, range -32768 to 32767).
; Kernel is also int16_t.
; Output is int32_t (32-bit) to hold the full product without overflow.
;
; Example kernel [1, 2, 1] approximates a simple smoothing (blurring) filter.
;
; SCALAR:
;   For each output sample, load 3 input samples, multiply by kernel, sum.
;
; SSE2 PACKED 16-bit:
;   PMULLW: Packed Multiply Low 16-bit Words → 8 multiplications in parallel
;   PMADDWD: Packed Multiply-Add Words → multiply 8 pairs and add adjacent pairs,
;            giving 4 int32_t results
;   For 3-tap convolution we process one output per iteration with PMADDWD.
;
; Build:
;   nasm -f elf64 07_conv1d.asm -o bin/07_conv1d.o
;   ld bin/07_conv1d.o -o bin/07_conv1d
; Run:
;   ./bin/07_conv1d
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16

    ; Input signal: 16-bit samples
    in_sig   dw 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120
    n_samp   equ ($ - in_sig) / 2      ; count = byte size / 2 (each sample is 2 bytes)

    ; 3-tap kernel: [k0, k1, k2]
    ; Smoothing kernel weights 1, 2, 1 (like a weighted average of 3 neighbors)
    kernel   dw 1, 2, 1
    ; k0 = 1 (weight for in[i-1])
    ; k1 = 2 (weight for in[i])
    ; k2 = 1 (weight for in[i+1])

    ; For SSE: replicate kernel into xmm register pattern as needed
    ; We'll load kernel[0] into a scalar, etc. for the scalar version.

    lbl_scal  db "Scalar output: ", 0
    lbl_sse   db "SSE2   output: ", 0
    newline   db 10
    space     db " ", 0

section .bss
    out_scalar  resd 12     ; output int32 samples (scalar) — 4 bytes each
    out_sse     resd 12     ; output int32 samples (SSE)
    num_buf     resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; conv1d_scalar — 3-tap convolution, scalar implementation
;   Input:  rdi = pointer to int16_t input array
;           rsi = pointer to int32_t output array
;           rdx = number of input samples n
;   Kernel is read from the global 'kernel' variable.
;   Boundary: zero-padding (samples outside [0,n) are treated as 0).
; ───────────────────────────────────────────────────────────────────────────
conv1d_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved) — input pointer
    push r13                ; save r13 (callee-saved) — output pointer
    push r14                ; save r14 (callee-saved) — n
    push r15                ; save r15 (callee-saved) — loop index i

    mov  r12, rdi           ; r12 = input pointer
    mov  r13, rsi           ; r13 = output pointer
    mov  r14, rdx           ; r14 = n

    xor  r15, r15           ; r15 = i = 0

    ; Load kernel coefficients into registers once (avoids repeated memory reads)
    movsx r8, word [kernel]        ; r8 = k0 (sign-extend int16 to int64)
    movsx r9, word [kernel + 2]    ; r9 = k1
    movsx r10, word [kernel + 4]   ; r10 = k2

.cs_loop:
    cmp  r15, r14           ; i >= n?
    jge  .cs_done           ; yes — done

    ; Accumulate: sum = k0*in[i-1] + k1*in[i] + k2*in[i+1]
    xor  rax, rax           ; rax = 0 — accumulator

    ; Tap 0: k0 * in[i-1]  (boundary check: if i==0, treat as 0)
    test r15, r15           ; is i == 0?
    jz   .cs_tap0_zero      ; yes — skip (0 * k0 = 0)
    movsx rcx, word [r12 + r15*2 - 2]  ; rcx = in[i-1] (sign-extend int16 → int64)
    imul rcx, r8                        ; rcx = k0 * in[i-1]
    add  rax, rcx                       ; accumulator += k0 * in[i-1]
.cs_tap0_zero:

    ; Tap 1: k1 * in[i]
    movsx rcx, word [r12 + r15*2]    ; rcx = in[i] (sign-extend int16 → int64)
    imul rcx, r9                      ; rcx = k1 * in[i]
    add  rax, rcx                     ; accumulator += k1 * in[i]

    ; Tap 2: k2 * in[i+1]  (boundary check: if i==n-1, treat as 0)
    lea  rcx, [r15 + 1]    ; rcx = i + 1
    cmp  rcx, r14           ; is (i+1) >= n? (i.e., i is the last element)
    jge  .cs_tap2_zero      ; yes — skip (0 * k2 = 0)
    movsx rcx, word [r12 + r15*2 + 2]  ; rcx = in[i+1] (sign-extend int16 → int64)
    imul rcx, r10                       ; rcx = k2 * in[i+1]
    add  rax, rcx                       ; accumulator += k2 * in[i+1]
.cs_tap2_zero:

    ; Store 32-bit result (truncate rax to 32 bits for output)
    mov  [r13 + r15*4], eax  ; out[i] = accumulator (store as int32)

    inc  r15                ; i++
    jmp  .cs_loop           ; next sample

.cs_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; conv1d_sse — 3-tap convolution using SSE2 packed 16-bit multiply-add
;   Input:  rdi = pointer to int16_t input array
;           rsi = pointer to int32_t output array
;           rdx = number of input samples n
;
;   We use PMADDWD (Packed Multiply and Add Words):
;     PMADDWD xmm_dst, xmm_src
;     Multiplies 8 pairs of int16, then adds adjacent pairs → 4 int32 results
;     xmm_dst[i] = xmm_dst[2i] * xmm_src[2i] + xmm_dst[2i+1] * xmm_src[2i+1]
;
;   For each output sample out[i], we create a vector of [in[i-1], in[i], in[i+1], 0]
;   and a kernel vector [k0, k1, k2, 0].
;   PMADDWD gives: [k0*in[i-1] + k1*in[i], k2*in[i+1] + 0*0, ...]
;   We then need to add lane 0 and lane 1 of the result.
;   This is a simplified approach; real FFmpeg code does much more parallelism.
; ───────────────────────────────────────────────────────────────────────────
conv1d_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push r15                ; save r15 (callee-saved)

    mov  r12, rdi           ; r12 = input pointer
    mov  r13, rsi           ; r13 = output pointer
    mov  r14, rdx           ; r14 = n

    ; Load kernel into the low 6 bytes of xmm_kern
    ; We arrange as [k2, k1, k0, 0, ...] for PMADDWD usage
    movd    xmm7, dword [kernel]      ; xmm7[0..31] = {k1:16, k0:16} (two 16-bit words)
    pinsrw  xmm7, word [kernel+4], 2  ; insert k2 at word position 2
                                       ; PINSRW: Packed INsert Word — inserts a 16-bit value
    ; Now xmm7 = [0, 0, 0, 0, 0, 0, k2, k1, k0, ...]
    ; Actually xmm7 low words = k0, k1, k2, 0, 0, ...

    xor  r15, r15           ; r15 = i = 0

.csse_loop:
    cmp  r15, r14           ; i >= n?
    jge  .csse_done         ; yes — done

    ; Build vector [in[i+1], in[i], in[i-1], 0, ...] in low 3 words of xmm0
    ; We handle boundary conditions manually

    pxor    xmm0, xmm0      ; xmm0 = all zeros (PXOR: clear by XOR with self)

    ; Word 0 = in[i-1] (or 0 if i == 0)
    test r15, r15            ; i == 0?
    jz   .csse_no_prev       ; yes — leave word 0 as 0
    movsx rax, word [r12 + r15*2 - 2]    ; rax = in[i-1]
    pinsrw xmm0, ax, 0                    ; insert in[i-1] at word 0 of xmm0
.csse_no_prev:

    ; Word 1 = in[i]
    movsx  rax, word [r12 + r15*2]    ; rax = in[i]
    pinsrw xmm0, ax, 1                ; insert in[i] at word 1 of xmm0

    ; Word 2 = in[i+1] (or 0 if i == n-1)
    lea    rax, [r15 + 1]
    cmp    rax, r14          ; i+1 >= n?
    jge    .csse_no_next     ; yes — leave word 2 as 0
    movsx  rax, word [r12 + r15*2 + 2]   ; rax = in[i+1]
    pinsrw xmm0, ax, 2                    ; insert in[i+1] at word 2 of xmm0
.csse_no_next:

    ; Now xmm0 = [0, 0, 0, 0, 0, in[i+1], in[i], in[i-1]] (16-bit words)
    ; xmm7     = [0, 0, 0, 0, 0, k2,      k1,    k0     ]

    pmaddwd xmm0, xmm7      ; xmm0 = {0, 0, 0, k2*in[i+1], k1*in[i] + k0*in[i-1]}
                             ; PMADDWD: multiply 8 pairs of int16, add adjacent pairs → 4 int32
                             ; Result at dword 0 = k0*in[i-1] + k1*in[i]
                             ; Result at dword 1 = k2*in[i+1] + 0*0

    ; Extract dword 0 and dword 1, add them
    movd   eax, xmm0         ; eax = dword 0 = k0*in[i-1] + k1*in[i]
    psrldq xmm0, 4           ; shift xmm0 right 4 bytes to move dword 1 to position 0
                              ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movd   ecx, xmm0         ; ecx = dword 1 = k2*in[i+1]
    add    eax, ecx           ; eax = total sum = k0*in[i-1] + k1*in[i] + k2*in[i+1]

    mov    [r13 + r15*4], eax ; store result as int32

    inc  r15                ; i++
    jmp  .csse_loop         ; loop

.csse_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_i32:                  ; print signed 32-bit; Input: edi
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    movsxd rdi, edi         ; sign-extend int32 to int64
    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13d, r13d

    test rdi, rdi
    jns  .p32pos
    neg  rdi
    mov  r13d, 1

.p32pos:
    mov  rax, rdi
    test rax, rax
    jnz  .p32d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .p32s
.p32d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .p32d
.p32s:
    test r13d, r13d
    jz   .p32t
    mov  byte [rbx], '-'
    inc  rbx
.p32t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.p32r:
    cmp  rsi, rdi
    jge  .p32w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .p32r
.p32w:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r13
    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pcl:
    cmp  byte [rdi+rcx], 0
    je   .pcw
    inc  rcx
    jmp  .pcl
.pcw:
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
    ; ── Scalar convolution ──
    mov  rdi, in_sig        ; rdi = input array
    mov  rsi, out_scalar    ; rsi = output buffer
    mov  rdx, n_samp        ; rdx = number of samples
    call conv1d_scalar

    mov  rdi, lbl_scal      ; "Scalar output: "
    call print_cstr

    xor  rbx, rbx           ; rbx = index = 0
.print_scal:
    cmp  rbx, n_samp
    jge  .do_sse
    mov  edi, [out_scalar + rbx*4]  ; edi = out[i] (int32)
    call print_i32
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall
    inc  rbx
    jmp  .print_scal

.do_sse:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE convolution ──
    mov  rdi, in_sig        ; rdi = input
    mov  rsi, out_sse       ; rsi = output
    mov  rdx, n_samp        ; rdx = count
    call conv1d_sse

    mov  rdi, lbl_sse       ; "SSE2   output: "
    call print_cstr

    xor  rbx, rbx
.print_sse:
    cmp  rbx, n_samp
    jge  .done
    mov  edi, [out_sse + rbx*4]  ; edi = out[i]
    call print_i32
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall
    inc  rbx
    jmp  .print_sse

.done:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall
