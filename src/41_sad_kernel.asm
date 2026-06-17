;═══════════════════════════════════════════════════════════════════════════════
; §26  SAD Kernel
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 26_sad_kernel.asm
;  Description : Scalar / SSE2 / AVX2 SAD side-by-side — PSADBW reduction
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 26_sad_kernel.asm — SAD (Sum of Absolute Differences) 16×16 kernel
;                     Scalar, SSE2, and AVX2 versions side by side
; Goal: horizontal reductions, tail handling, FFmpeg microkernel style
;
; This is the definitive SAD reference: three versions in one file so you can
; compare how the same algorithm evolves from scalar to SSE2 to AVX2.
;
; The SAD kernel is one of the most performance-critical functions in video
; codecs. FFmpeg has hand-optimized versions for every x86 SIMD extension.
; In this file we show the progression clearly.
;
; Key instruction differences:
;
;   SCALAR:
;     SUB byte, cmp, negate — 1 pixel per cycle
;
;   SSE2 (128-bit, 16 bytes at a time):
;     PSADBW xmm, xmm — sum |A[i]-B[i]| for 8 byte pairs, 2 results per call
;     One 16-byte row → 2 partial sums → accumulate with PADDQ
;
;   AVX2 (256-bit, 32 bytes at a time):
;     VPSADBW ymm, ymm, ymm — same but 32 bytes → 4 partial sums
;     Process 2 rows of 16 pixels per iteration
;     Extract upper 128 bits with VEXTRACTI128 for final horizontal reduction
;
; Build:
;   nasm -f elf64 26_sad_kernel.asm -o bin/26_sad_kernel.o
;   ld bin/26_sad_kernel.o -o bin/26_sad_kernel
; Run:
;   ./bin/26_sad_kernel
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 32

    ; Current block: 16×16 bytes, gradient pattern
    cur_blk:
    %assign row 0
    %rep 16
        %assign val row
        %rep 16
            db val
            %assign val val+1
        %endrep
        %assign row row+1
    %endrep

    ; Reference block: 16×16 bytes, slightly different gradient
    ref_blk:
    %assign row 0
    %rep 16
        %assign val row+5
        %rep 16
            db val
            %assign val val+1
        %endrep
        %assign row row+1
    %endrep
    ; Each pixel differs by 5 → expected SAD = 16*16*5 = 1280

    lbl_scalar  db "Scalar SAD  = ", 0
    lbl_sse2    db "SSE2   SAD  = ", 0
    lbl_avx2    db "AVX2   SAD  = ", 0
    lbl_expect  db "Expected    = 1280", 10, 0
    newline     db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_scalar — reference scalar implementation
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
; ───────────────────────────────────────────────────────────────────────────
sad16x16_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — used as SAD accumulator (callee-saved)

    xor  rbx, rbx           ; rbx = 0 — total SAD accumulator
                             ; (rax is free scratch for byte-offset arithmetic)
    xor  r8,  r8            ; r8  = row index = 0

.sc_row:
    cmp  r8, 16             ; all 16 rows done?
    jge  .sc_done

    xor  r9, r9             ; r9 = column index = 0

.sc_col:
    cmp  r9, 16             ; all 16 columns done?
    jge  .sc_next_row

    ; Compute byte offset = row*16 + col (SIB can't encode *16 or 3 registers)
    imul rax, r8, 16           ; rax = row * 16 (bytes per row)
    add  rax, r9               ; rax = row*16 + col (byte offset into block)
    movzx r10, byte [rdi + rax]  ; r10 = cur[row][col] (zero-extend)
    movzx r11, byte [rsi + rax]  ; r11 = ref[row][col] (zero-extend)

    sub  r10, r11           ; r10 = cur - ref (signed difference)
    jge  .sc_abs            ; if >= 0, already non-negative
    neg  r10                ; negate to get |cur - ref|

.sc_abs:
    add  rbx, r10           ; rbx += |cur - ref| (accumulate into dedicated register)

    inc  r9                 ; col++
    jmp  .sc_col

.sc_next_row:
    inc  r8                 ; row++
    jmp  .sc_row

.sc_done:
    mov  rax, rbx           ; move final SAD into rax (ABI: return value)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_sse2 — SSE2 implementation using PSADBW
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
;
;   Per-row work:
;     Load 16 bytes from cur and ref.
;     PSADBW produces two 16-bit partial sums (for bytes 0-7 and 8-15).
;     Accumulate with PADDQ (64-bit lane addition into xmm0).
;   Final horizontal reduction: add the two 64-bit lanes of xmm0.
; ───────────────────────────────────────────────────────────────────────────
sad16x16_sse2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    pxor  xmm0, xmm0        ; xmm0 = {0, 0, 0, 0} — 128-bit accumulator, zero
                             ; PXOR: clear by XOR with self

    xor  r8, r8             ; r8 = row = 0

.s2_row:
    cmp  r8, 16             ; all rows done?
    jge  .s2_hsum

    ; Load 16 bytes of cur and ref (*16 is invalid SIB scale; use imul)
    imul rax, r8, 16               ; rax = row * 16 (byte offset)
    movdqu xmm1, [rdi + rax]       ; xmm1 = 16 cur pixels (unaligned load)
                                    ; MOVDQU: Move Unaligned Double Quadword
    movdqu xmm2, [rsi + rax]       ; xmm2 = 16 ref pixels

    psadbw xmm1, xmm2              ; xmm1[15:0]  = sum(|cur[0..7] - ref[0..7]|)
                                    ; xmm1[79:64] = sum(|cur[8..15] - ref[8..15]|)
                                    ; PSADBW: Packed Sum of Absolute Differences of Bytes
                                    ; Other bits of xmm1 become 0.

    paddq  xmm0, xmm1              ; accumulate both 64-bit partial sums
                                    ; PADDQ: Packed ADD Quadwords (independent 64-bit addition)

    inc  r8                 ; next row
    jmp  .s2_row

.s2_hsum:
    ; xmm0 now holds sum of partial sums in two 64-bit halves
    ; lower 64 bits = total for bytes 0-7 of all rows
    ; upper 64 bits = total for bytes 8-15 of all rows
    movq   rax, xmm0        ; rax = lower 64 bits (MOVQ required for 64-bit GP register)
    psrldq xmm0, 8          ; shift xmm0 right by 8 bytes to bring upper sum to low position
                             ; PSRLDQ: Packed Shift Right Logical Double Quadword (byte shift)
    movq   rcx, xmm0        ; rcx = formerly-upper (now lower) partial sum
    add    rax, rcx         ; rax = total SAD

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_avx2 — AVX2 implementation using VPSADBW on 32-byte registers
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
;
;   Process 2 rows at a time (32 bytes = 2 × 16-pixel rows):
;     VINSERTI128 to build a 256-bit value from two 128-bit rows.
;     VPSADBW produces four 16-bit partial sums (2 per 16-byte lane).
;     VPADDQ accumulates into ymm0.
;   Final reduction: fold upper 128 bits of ymm0 down, then sum two 64-bit lanes.
; ───────────────────────────────────────────────────────────────────────────
sad16x16_avx2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    vpxor  ymm0, ymm0, ymm0  ; ymm0 = 0 — 256-bit accumulator, all zeros
                               ; VPXOR: VEX Packed XOR (3-operand form)

    xor  r8, r8               ; r8 = row pair index = 0 (we process 2 rows per iteration)

.a2_row:
    cmp  r8, 16               ; all 16 rows done? (we do pairs, but check individual)
    jge  .a2_hsum

    ; Load row r8 and row r8+1 into the two 128-bit lanes of a YMM register
    ; If r8+1 >= 16, we just process one row (simple boundary handling)
    ; *16 is not a valid SIB scale; use imul to compute byte offset
    imul rax, r8, 16                   ; rax = row r8 * 16 (byte offset)
    vmovdqu xmm1, [rdi + rax]          ; xmm1 = cur row r8 (16 bytes)
    vmovdqu xmm2, [rsi + rax]          ; xmm2 = ref row r8

    inc  r8                            ; advance row (might use row r8+1 next)

    cmp  r8, 16                        ; is row r8 valid?
    jge  .a2_one_row                   ; no — only process one row

    ; Load second row
    imul rax, r8, 16                   ; rax = row r8+1 * 16 (byte offset, after inc)
    vmovdqu xmm3, [rdi + rax]          ; xmm3 = cur row r8+1
    vmovdqu xmm4, [rsi + rax]          ; xmm4 = ref row r8+1

    ; Pack into 256-bit YMM registers
    vinserti128 ymm1, ymm1, xmm3, 1   ; ymm1 = {xmm3 (high 128), xmm1 (low 128)}
                                        ; VINSERTI128: Insert 128-bit into YMM at lane 1
    vinserti128 ymm2, ymm2, xmm4, 1   ; ymm2 = {xmm4, xmm2}

    vpsadbw ymm1, ymm1, ymm2          ; ymm1 = four partial SADs (4 × 16-bit)
                                        ; VPSADBW: VEX Packed Sum of Absolute Differences
                                        ; Lower 128: {sum[8..15], 0, 0, 0, sum[0..7], 0, 0, 0}
                                        ; Upper 128: same for the second pair of rows

    vpaddq  ymm0, ymm0, ymm1          ; accumulate all four partial sums
                                        ; VPADDQ: VEX Packed ADD Quadwords (4 × 64-bit)

    inc  r8                            ; advance to next pair
    jmp  .a2_row

.a2_one_row:
    ; Only one remaining row — use SSE2 path
    psadbw  xmm1, xmm2                ; PSADBW (128-bit): compute partial SADs
    vpaddq  ymm0, ymm0, ymm1          ; accumulate

    inc  r8                            ; advance
    jmp  .a2_row

.a2_hsum:
    ; Horizontal reduction of ymm0:
    ; ymm0 = {partial_3, partial_2, partial_1, partial_0}  (four 64-bit values)
    ; We want: total = partial_0 + partial_1 + partial_2 + partial_3

    ; Step 1: fold upper 128 bits down
    vextracti128 xmm1, ymm0, 1        ; xmm1 = upper 128 bits of ymm0
                                        ; VEXTRACTI128: Extract 128-bit lane 1 from YMM
    vpaddq  xmm0, xmm0, xmm1          ; xmm0 = lower_pair + upper_pair (two 64-bit sums)
                                        ; VPADDQ (128-bit): add two pairs

    ; Step 2: fold 64-bit halves of xmm0
    movq   rax, xmm0                   ; rax = lower 64 bits (MOVQ required for 64-bit GP reg)
    psrldq xmm0, 8                     ; shift to bring upper 64 bits to position 0
    movq   rcx, xmm0                   ; rcx = upper 64 bits
    add    rax, rcx                     ; rax = total SAD

    vzeroupper                          ; clear upper YMM bits (important before calling non-AVX code)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

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
    ; Print expected value
    mov  rdi, lbl_expect    ; "Expected    = 1280\n"
    call print_cstr

    ; ── Scalar ──
    mov  rdi, lbl_scalar    ; "Scalar SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_scalar
    mov  rdi, rax
    call print_u64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE2 ──
    mov  rdi, lbl_sse2      ; "SSE2   SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_sse2
    mov  rdi, rax
    call print_u64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── AVX2 ──
    mov  rdi, lbl_avx2      ; "AVX2   SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_avx2
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
