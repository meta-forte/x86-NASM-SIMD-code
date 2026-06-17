;═══════════════════════════════════════════════════════════════════════════════
; §12  SAD Motion Estimation
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 12_sad_motion.asm
;  Description : PSADBW + VPSADBW reduction pattern — FFmpeg motion estimation
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 12_sad_motion.asm — SAD for 16×16 block motion estimation with AVX2/C API
; Goal: reduction patterns, vector horizontal sums, FFmpeg motion estimation style
;
; Motion estimation finds which block in the reference frame best matches
; the current block in the new frame. "Best match" = minimum SAD (Sum of
; Absolute Differences). FFmpeg's me_sad functions follow this pattern.
;
; SAD for one candidate block:
;   sad = sum over all (row, col) of |current[row][col] - ref[row+dy][col+dx]|
;
; We expose a C-callable function:
;   uint64_t sad_16x16(const uint8_t *current, const uint8_t *ref, int ref_stride)
;
; Implementations:
;   sad_16x16_scalar — 1 byte per iteration (for understanding)
;   sad_16x16_sse2   — 16 bytes per iteration using PSADBW (SSE2)
;   sad_16x16_avx2   — 32 bytes per iteration using VPSADBW (AVX2)
;
; PSADBW instruction (key to fast SAD in FFmpeg):
;   PSADBW xmm_dst, xmm_src:
;     Computes |byte_i - byte_j| for 8 byte pairs, sums them into one 16-bit word.
;     Result: two 16-bit partial sums in low and high 64-bit halves.
;   VPSADBW ymm (AVX2): same but 32 bytes at a time, 4 partial sums.
;
; Build:
;   nasm -f elf64 12_sad_motion.asm -o bin/12_sad_motion.o
;   ld bin/12_sad_motion.o -o bin/12_sad_motion
; Run:
;   ./bin/12_sad_motion
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 32                ; 32-byte align for AVX2

    ; Simulated 16×16 current frame block (all pixel values = 100)
    current_block:
    %rep 16                 ; repeat 16 times
        db 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100
    %endrep

    ; Simulated 16×16 reference block (pixel values = 90 for first 8 rows, 110 for last 8)
    ref_block:
    %rep 8
        db 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90
    %endrep
    %rep 8
        db 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110
    %endrep
    ; Expected SAD: 8 rows × 16 pixels × |100-90| + 8 rows × 16 pixels × |100-110|
    ;             = 8*16*10 + 8*16*10 = 1280 + 1280 = 2560

    lbl_scal  db "Scalar  SAD = ", 0
    lbl_sse2  db "SSE2    SAD = ", 0
    lbl_avx2  db "AVX2    SAD = ", 0
    newline   db 10

section .bss
    num_buf  resb 22

section .text
global _start
global sad_16x16_scalar    ; expose for C linking
global sad_16x16_sse2      ; expose for C linking
global sad_16x16_avx2      ; expose for C linking

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_scalar — compute SAD of two 16×16 uint8 blocks (scalar)
;   Input:  rdi = pointer to current block (16×16 contiguous bytes)
;           rsi = pointer to reference block (16×16 contiguous bytes)
;           rdx = stride of reference block (bytes per row; use 16 for contiguous)
;   Output: rax = SAD value (unsigned 64-bit sum of absolute differences)
;
;   C prototype: uint64_t sad_16x16_scalar(const uint8_t *cur, const uint8_t *ref, int stride);
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push rbx                ; save rbx — used as SAD accumulator (callee-saved)

    mov  r12, rdi           ; r12 = current block pointer
    mov  r13, rsi           ; r13 = reference block pointer

    xor  rbx, rbx           ; rbx = 0 — accumulator for SAD
                             ; (rax is free for byte-offset scratch use)

    xor  r8, r8             ; r8 = row = 0

.scal_row:
    cmp  r8, 16             ; row >= 16?
    jge  .scal_done

    xor  r9, r9             ; r9 = col = 0

.scal_col:
    cmp  r9, 16             ; col >= 16?
    jge  .scal_next_row

    ; Load one pixel from current (stride = 16, contiguous)
    imul rax, r8, 16            ; rax = row * 16 (byte offset for this row)
    add  rax, r9                ; rax = row*16 + col (byte offset of this pixel)
    movzx r10, byte [r12 + rax] ; r10 = current[row][col]

    ; Load corresponding pixel from reference (stride = rdx)
    ; 3-register IMUL (reg, reg, reg) encodes as EVEX (AVX-512) — use 2-op form
    mov   r11, r8                ; r11 = row
    imul  r11, rdx               ; r11 = row * stride (2-op: r11 *= rdx)
    add   r11, r9                ; r11 = row * stride + col
    movzx r11, byte [r13 + r11]  ; r11 = ref[row*stride + col]

    ; Compute |current - ref|
    sub  r10, r11           ; r10 = current - ref (signed difference)
    jge  .scal_pos          ; if result >= 0, already non-negative
    neg  r10                ; negate to get absolute value

.scal_pos:
    add  rbx, r10           ; rbx += |diff| — accumulate into dedicated register

    inc  r9                 ; col++
    jmp  .scal_col

.scal_next_row:
    inc  r8                 ; row++
    jmp  .scal_row

.scal_done:
    mov  rax, rbx           ; move final SAD into rax (ABI: return value)
    pop  rbx                ; restore rbx (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total SAD

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_sse2 — compute SAD using SSE2 PSADBW (16 bytes per iteration)
;   Input:  rdi = current block pointer
;           rsi = reference block pointer
;           rdx = stride of reference (bytes per row)
;   Output: rax = SAD
;
;   PSADBW xmm_dst, xmm_src:
;     For each 8-byte half: compute sum of |dst[i] - src[i]| for i in 0..7
;     Stores two 16-bit partial sums in bits [15:0] and [79:64] of xmm_dst.
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_sse2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)

    mov  r12, rdi           ; r12 = current
    mov  r13, rsi           ; r13 = reference
    mov  r14, rdx           ; r14 = stride

    pxor  xmm0, xmm0        ; xmm0 = {0,0,0,0} — accumulator for partial PSADBW sums
                             ; PXOR: zeroes xmm0

    xor  r8, r8             ; r8 = row = 0

.sse2_row:
    cmp  r8, 16             ; row >= 16?
    jge  .sse2_hsum         ; yes — compute horizontal sum

    ; Current row: starts at r12 + row * 16 (16-byte row stride)
    ; Reference row: starts at r13 + row * r14 (variable stride)
    imul r9, r8, 16
    add  r9, r12     ; r9 = &current[row][0]
    mov  r10, r8                ; r10 = row
    imul r10, r14               ; r10 = row * stride (2-op: r10 *= r14)
    add  r10, r13               ; r10 = &ref[row][0]

    ; Load 16 bytes from each row
    movdqu xmm1, [r9]          ; xmm1 = 16 current pixels
                                ; MOVDQU: Move Unaligned Double Quadword (16 bytes)
    movdqu xmm2, [r10]         ; xmm2 = 16 reference pixels

    ; PSADBW: compute sum of |xmm1[i] - xmm2[i]| for 8 bytes, store two 16-bit sums
    psadbw xmm1, xmm2          ; xmm1[0..15] = sum(|cur[0..7] - ref[0..7]|)
                                ; xmm1[64..79] = sum(|cur[8..15] - ref[8..15]|)
                                ; PSADBW: Packed Sum of Absolute Differences of Bytes

    ; Accumulate into xmm0
    paddq  xmm0, xmm1          ; xmm0 += partial sums
                                ; PADDQ: Packed ADD Quadwords (64-bit addition of both halves)

    inc  r8                ; row++
    jmp  .sse2_row

.sse2_hsum:
    ; Extract both 64-bit partial sums and add them
    movq   rax, xmm0           ; rax = xmm0[63:0] = sum of lower-half partial sums
                                ; MOVD (64-bit): Move Doubleword/Quadword from XMM
    psrldq xmm0, 8             ; shift xmm0 right by 8 bytes to access upper partial sum
                                ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movq   rcx, xmm0           ; rcx = xmm0[63:0] = sum of upper-half partial sums
    add    rax, rcx             ; rax = total SAD = lower + upper

    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_avx2 — compute SAD using AVX2 VPSADBW (32 bytes per iteration)
;   Input:  rdi = current block (16×16 = 256 bytes contiguous)
;           rsi = reference block (16×16 bytes, stride = rdx)
;           rdx = stride
;   Output: rax = SAD
;
;   VPSADBW ymm_dst, ymm_src1, ymm_src2:
;     Same as PSADBW but operates on 32 bytes.
;     Produces four 16-bit partial sums in the four 64-bit lanes.
;     For a 16-pixel row: process 2 rows at once (32 bytes) if stride = 16.
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_avx2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)

    mov  r12, rdi           ; r12 = current
    mov  r13, rsi           ; r13 = reference
    mov  r14, rdx           ; r14 = stride

    vpxor ymm0, ymm0, ymm0 ; ymm0 = 0 — 256-bit accumulator, all zeros
                            ; VPXOR: zeroes ymm0 via XOR with itself

    xor  r8, r8             ; r8 = row = 0

.avx2_row:
    cmp  r8, 16             ; row >= 16?
    jge  .avx2_hsum

    ; Load 16 current pixels (one row)
    imul r9, r8, 16
    add  r9, r12
    vmovdqu xmm1, [r9]          ; xmm1 = current row (16 bytes)
                                 ; VMOVDQU: VEX-coded Move Unaligned Double Quadword

    ; Load 16 reference pixels
    mov  r10, r8                ; r10 = row
    imul r10, r14               ; r10 = row * stride (2-op avoids EVEX/AVX-512 encoding)
    add  r10, r13
    vmovdqu xmm2, [r10]         ; xmm2 = reference row (16 bytes)

    ; Expand to 256-bit by inserting into lower half of YMM
    ; (Simple approach: use VPSADBW on 16 bytes via XMM)
    vpsadbw xmm1, xmm1, xmm2   ; xmm1 = partial SADs (two 16-bit values)
                                 ; VPSADBW (128-bit form): Packed SAD Bytes

    vpaddq  ymm0, ymm0, ymm1   ; ymm0 += partial sums (zero-extend xmm1 to 256-bit)
                                ; VPADDQ: VEX Packed ADD Quadwords

    inc  r8
    jmp  .avx2_row

.avx2_hsum:
    ; Sum all 4 quadword lanes of ymm0
    vextracti128 xmm1, ymm0, 1  ; xmm1 = upper 128 bits of ymm0
                                  ; VEXTRACTI128: Extract 128-bit from YMM
    vpaddq  xmm0, xmm0, xmm1   ; xmm0 = lower + upper

    ; Sum the two 64-bit halves of xmm0
    movq   rax, xmm0            ; rax = lower 64 bits
    psrldq xmm0, 8              ; shift right 8 bytes
    movq   rcx, xmm0            ; rcx = upper 64 bits
    add    rax, rcx             ; rax = total SAD

    vzeroupper                  ; clear upper YMM bits (required after AVX2)

    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
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

print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pd
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pt

.pd:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pd

.pt:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pr:
    cmp  rsi, rdi
    jge  .pw
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pr

.pw:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Scalar SAD ──
    mov  rdi, lbl_scal      ; "Scalar  SAD = "
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16            ; stride = 16 (contiguous 16x16 block)
    call sad_16x16_scalar   ; rax = SAD

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE2 SAD ──
    mov  rdi, lbl_sse2
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16
    call sad_16x16_sse2

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── AVX2 SAD ──
    mov  rdi, lbl_avx2
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16
    call sad_16x16_avx2

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall
