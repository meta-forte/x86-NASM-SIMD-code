;═══════════════════════════════════════════════════════════════════════════════
; §23  Matrix Multiply
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 23_matrix_mul.asm
;  Description : 3×3 int32 naive triple loop; 4×4 float SSE broadcast+MULPS
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 23_matrix_mul.asm — Matrix multiplication: 3×3 scalar and 4×4 SSE
; Goal: cache blocking, register blocking, understanding access patterns
;
; Matrix multiplication: C = A × B
;   C[i][j] = sum over k of A[i][k] * B[k][j]
;
; Access pattern matters for cache performance:
;   - A is accessed row-by-row (cache friendly)
;   - B is accessed column-by-column (cache UNFRIENDLY — each access jumps by a full row)
;   - Solution: transpose B first, then access rows of B^T instead of columns of B
;
; We implement:
;   1. 3×3 scalar multiply (int32_t elements)
;   2. 4×4 SSE multiply (float elements) — four rows of B loaded as rows of B^T
;
; Build:
;   nasm -f elf64 23_matrix_mul.asm -o bin/23_matrix_mul.o
;   ld bin/23_matrix_mul.o -o bin/23_matrix_mul
; Run:
;   ./bin/23_matrix_mul
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; 3×3 integer matrices (row-major, int32_t)
    A3  dd  1, 2, 3
        dd  4, 5, 6
        dd  7, 8, 9

    B3  dd  9, 8, 7
        dd  6, 5, 4
        dd  3, 2, 1

    ; Expected C3 = A3 × B3:
    ; Row 0: [1*9+2*6+3*3, 1*8+2*5+3*2, 1*7+2*4+3*1] = [30, 24, 18]
    ; Row 1: [4*9+5*6+6*3, 4*8+5*5+6*2, 4*7+5*4+6*1] = [84, 69, 54]
    ; Row 2: [7*9+8*6+9*3, 7*8+8*5+9*2, 7*7+8*4+9*1] = [138, 114, 90]

    ; 4×4 float matrices (row-major, float32)
    align 16
    A4  dd  1.0, 2.0,  3.0,  4.0
        dd  5.0, 6.0,  7.0,  8.0
        dd  9.0, 10.0, 11.0, 12.0
        dd  13.0, 14.0, 15.0, 16.0

    B4  dd  1.0, 0.0, 0.0, 0.0   ; identity matrix
        dd  0.0, 1.0, 0.0, 0.0
        dd  0.0, 0.0, 1.0, 0.0
        dd  0.0, 0.0, 0.0, 1.0
    ; C4 = A4 × I = A4

    lbl_3x3   db "3x3 Integer matrix multiply result:", 10, 0
    lbl_4x4   db "4x4 Float matrix multiply (A x I = A):", 10, 0
    newline   db 10
    space     db " ", 0

section .bss
    C3       resd 9         ; 3×3 int32 output matrix
    C4       resd 16        ; 4×4 float output matrix
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; matmul_3x3_i32 — multiply two 3×3 int32 matrices
;   Input:  rdi = pointer to 3×3 matrix A (int32, row-major)
;           rsi = pointer to 3×3 matrix B (int32, row-major)
;           rdx = pointer to 3×3 output matrix C (int32, row-major)
;
;   C[i][j] = sum_{k=0}^{2} A[i][k] * B[k][j]
; ───────────────────────────────────────────────────────────────────────────
matmul_3x3_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = A
    mov  r13, rsi           ; r13 = B
    mov  r14, rdx           ; r14 = C

    ; Triple nested loop: i, j, k
    xor  r8, r8             ; r8 = i = 0 (row of A and C)

.mm3_i:
    cmp  r8, 3              ; i >= 3?
    jge  .mm3_done

    xor  r9, r9             ; r9 = j = 0 (column of B and C)

.mm3_j:
    cmp  r9, 3              ; j >= 3?
    jge  .mm3_next_i        ; advance to next row i

    xor  rbx, rbx           ; rbx = sum = 0 (accumulator for C[i][j])
    xor  r10, r10           ; r10 = k = 0 (inner sum index)

.mm3_k:
    cmp  r10, 3             ; k >= 3?
    jge  .mm3_store         ; yes — store C[i][j]

    ; Load A[i][k]: row i, column k → offset (i*3 + k) * 4 bytes
    imul rax, r8, 3            ; rax = i * 3
    add  rax, r10              ; rax = i*3 + k
    movsxd rax, dword [r12 + rax*4]  ; rax = A[i][k] (sign-extend int32 to int64)

    ; Load B[k][j]: row k, column j → offset (k*3 + j) * 4 bytes
    imul rcx, r10, 3           ; rcx = k * 3
    add  rcx, r9               ; rcx = k*3 + j
    movsxd rcx, dword [r13 + rcx*4]  ; rcx = B[k][j]

    imul rax, rcx           ; rax = A[i][k] * B[k][j] (64-bit product)
    add  rbx, rax           ; sum += product

    inc  r10                ; k++
    jmp  .mm3_k

.mm3_store:
    ; Store C[i][j] = sum — offset (i*3 + j) * 4
    imul rax, r8, 3            ; rax = i * 3
    add  rax, r9               ; rax = i*3 + j
    mov  [r14 + rax*4], ebx   ; C[i][j] = lower 32 bits of sum

    inc  r9                 ; j++
    jmp  .mm3_j

.mm3_next_i:
    inc  r8                 ; i++
    jmp  .mm3_i

.mm3_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; matmul_4x4_f32_sse — multiply two 4×4 float matrices using SSE
;   Input:  rdi = pointer to A (4×4 float, 16-byte aligned)
;           rsi = pointer to B (4×4 float, 16-byte aligned)
;           rdx = pointer to C (4×4 float, 16-byte aligned output)
;
;   Strategy: for each row i of A and each column j of B:
;     C[i][j] = dot product of row i of A with column j of B
;
;   SSE approach: process one row of C at a time.
;     Load row i of A into xmm registers.
;     For each column j (0..3):
;       Load B's column j (scattered in memory) into xmm4.
;       Compute dot product using MULPS + horizontal add.
;
;   Simpler approach for clarity: broadcast each element of A's row, multiply
;   by corresponding row of B, accumulate.
; ───────────────────────────────────────────────────────────────────────────
matmul_4x4_f32_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = A
    mov  r13, rsi           ; r13 = B
    mov  r14, rdx           ; r14 = C

    xor  rbx, rbx           ; rbx = row index i = 0

.mm4_row:
    cmp  rbx, 4             ; i >= 4?
    jge  .mm4_done

    ; C[i][0..3] = A[i][0]*B[0] + A[i][1]*B[1] + A[i][2]*B[2] + A[i][3]*B[3]
    ; where B[k] = row k of B = [B[k][0], B[k][1], B[k][2], B[k][3]]

    ; Pointer to row i of A: r12 + i * 16 (4 floats × 4 bytes each)
    imul rdi, rbx, 16          ; rdi = i * 16 (byte offset)
    add  rdi, r12              ; rdi = &A[i][0]

    pxor xmm0, xmm0         ; xmm0 = {0,0,0,0} — accumulator for C row i
                             ; PXOR: zero out the register

    ; Process each k = 0..3
    xor  r8, r8             ; r8 = k = 0

.mm4_k:
    cmp  r8, 4              ; k >= 4?
    jge  .mm4_store

    ; Load scalar A[i][k] and broadcast to all 4 lanes
    movss xmm1, [rdi + r8*4]   ; xmm1 = A[i][k] in lowest lane, others undefined
                                ; MOVSS: Move Scalar Single-precision
    shufps xmm1, xmm1, 0       ; xmm1 = {A[i][k], A[i][k], A[i][k], A[i][k]}
                                ; SHUFPS: Shuffle Packed Singles
                                ; Shuffle control 0 = copy element 0 to all 4 lanes

    ; Load row k of B: r13 + k * 16
    imul rcx, r8, 16           ; rcx = k * 16 (byte offset)
    add  rcx, r13              ; rcx = &B[k][0]
    movaps xmm2, [rcx]          ; xmm2 = {B[k][0], B[k][1], B[k][2], B[k][3]}
                                 ; MOVAPS: Move Aligned Packed Singles (16-byte aligned load)

    ; Multiply and accumulate
    mulps  xmm1, xmm2           ; xmm1 = A[i][k] * {B[k][0], B[k][1], B[k][2], B[k][3]}
                                 ; MULPS: Multiply Packed Singles — 4 multiplications at once
    addps  xmm0, xmm1           ; xmm0 += xmm1 — accumulate 4 products in parallel
                                 ; ADDPS: Add Packed Singles

    inc  r8                ; k++
    jmp  .mm4_k

.mm4_store:
    ; Store the computed row i of C: r14 + i * 16
    imul rdi, rbx, 16          ; rdi = i * 16 (byte offset)
    add  rdi, r14              ; rdi = &C[i][0]
    movaps [rdi], xmm0          ; C[i][0..3] = xmm0 (aligned store)
                                 ; MOVAPS: Move Aligned Packed Singles (store)

    inc  rbx                ; next row
    jmp  .mm4_row

.mm4_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    movsxd rdi, edi
    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13, r13

    test rdi, rdi
    jns  .pi_p
    neg  rdi
    mov  r13, 1

.pi_p:
    mov  rax, rdi
    test rax, rax
    jnz  .pi_d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pi_s

.pi_d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pi_d

.pi_s:
    test r13, r13
    jz   .pi_t
    mov  byte [rbx], '-'
    inc  rbx

.pi_t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pi_r:
    cmp  rsi, rdi
    jge  .pi_w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pi_r

.pi_w:
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

print_float:                ; print xmm0 as integer (float display is approximate)
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    cvttss2si edi, xmm0    ; convert float to int (truncate)
    call print_i32          ; print it
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pcs:
    cmp  byte [rdi+rcx], 0
    je   .pcsw
    inc  rcx
    jmp  .pcs
.pcsw:
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
    ; ── 3×3 integer matrix multiply ──
    mov  rdi, A3            ; rdi = matrix A
    mov  rsi, B3            ; rsi = matrix B
    mov  rdx, C3            ; rdx = output C
    call matmul_3x3_i32

    mov  rdi, lbl_3x3       ; "3x3 Integer matrix multiply result:\n"
    call print_cstr

    ; Print 3×3 result
    xor  rbx, rbx
.p3:
    cmp  rbx, 9
    jge  .do_4x4

    mov  edi, [C3 + rbx*4]
    call print_i32

    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Newline after each row of 3
    lea  rax, [rbx + 1]
    xor  rdx, rdx
    mov  rcx, 3
    div  rcx                ; rax = (rbx+1)/3, rdx = (rbx+1)%3
    test rdx, rdx           ; end of row?
    jnz  .no_nl3
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
.no_nl3:
    inc  rbx
    jmp  .p3

.do_4x4:
    ; ── 4×4 float matrix multiply ──
    mov  rdi, A4
    mov  rsi, B4
    mov  rdx, C4
    call matmul_4x4_f32_sse

    mov  rdi, lbl_4x4
    call print_cstr

    xor  rbx, rbx
.p4:
    cmp  rbx, 16
    jge  .done

    movss xmm0, [C4 + rbx*4]  ; load float result
    call print_float

    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall

    lea  rax, [rbx + 1]
    xor  rdx, rdx
    mov  rcx, 4
    div  rcx
    test rdx, rdx
    jnz  .no_nl4
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
.no_nl4:
    inc  rbx
    jmp  .p4

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall
