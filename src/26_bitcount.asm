;═══════════════════════════════════════════════════════════════════════════════
; §05  Bit Count (Popcount)
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 05_bitcount.asm
;  Description : Kernighan n&(n-1) trick, SSSE3 PSHUFB nibble-LUT, PSADBW
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 05_bitcount.asm — Count set bits (popcount) using scalar and SSE2 methods
; Goal: learn SIMD data layout and lane operations
;
; We implement popcount in two ways:
;
; 1. SCALAR — Brian Kernighan's algorithm (n & (n-1) trick), one bit per iteration
;    Simple but O(k) where k = number of set bits
;
; 2. SSE2 lookup table (pshufb/psadbw trick):
;    This is the vectorized approach used in FFmpeg and other high-performance code.
;    Idea: split each byte into two nibbles (4-bit pieces), look up the popcount
;    of each nibble in a 16-entry table, then sum.
;
;    NOTE: PSHUFB is part of SSSE3 (Supplemental SSE3), not SSE2.
;    The technique is often called the "SSE2 popcount" but uses PSHUFB (SSSE3).
;    We handle this by providing the scalar fallback and using the SSSE3 version.
;
;    Steps for the vectorized popcount over 16 bytes at a time:
;    a) Load 16 bytes into xmm0
;    b) Create low nibble mask: xmm_mask = {0x0F x 16}
;    c) Extract low nibbles:  lo = xmm0 & mask
;    d) Extract high nibbles: hi = (xmm0 >> 4) & mask  (PSRLW then AND)
;    e) PSHUFB lo_lut, lo   — look up popcount of each low nibble
;    f) PSHUFB hi_lut, hi   — look up popcount of each high nibble
;    g) PADDB result = lo_lut + hi_lut  — sum nibble popcounts per byte
;    h) PSADBW result, zeros — sum 8 bytes at a time into 16-bit accumulators
;    i) Sum the two 16-bit accumulators for total popcount of the 16 bytes
;
; Build:
;   nasm -f elf64 05_bitcount.asm -o bin/05_bitcount.o
;   ld bin/05_bitcount.o -o bin/05_bitcount
; Run:
;   ./bin/05_bitcount
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16                ; 16-byte align for SSE loads (unaligned loads work too but are slower)

    ; 16-entry lookup table: popcount_lut[i] = number of 1-bits in the nibble i (0-15)
    ; nibble:     0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    popcount_lut  db 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4

    ; Test data: 16 bytes whose bitcounts we want to sum
    ; The test buffer has known content so we can verify the result
    test_buf db 0xFF, 0x00, 0xAA, 0x55, 0x0F, 0xF0, 0x01, 0x80
             db 0xFE, 0x7F, 0x0E, 0x70, 0xFF, 0xFF, 0x00, 0x00
    ; Popcount per byte:
    ;   FF=8, 00=0, AA=4, 55=4, 0F=4, F0=4, 01=1, 80=1
    ;   FE=7, 7F=7, 0E=3, 70=3, FF=8, FF=8, 00=0, 00=0
    ; Total = 8+0+4+4+4+4+1+1+7+7+3+3+8+8+0+0 = 62

    lbl_scalar   db "Scalar popcount of test_buf = ", 0
    lbl_ssse3    db "SSSE3  popcount of test_buf = ", 0
    lbl_val      db "popcount(0xDEADBEEF12345678) = ", 0
    newline      db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; popcount_kernighan — count set bits in a 64-bit value (scalar)
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits
;
;   Key insight: n & (n-1) always clears the LOWEST set bit.
;   Example: n=0b1100, n-1=0b1011, n&(n-1)=0b1000 (cleared bit 2, which was lowest)
;   Count how many times we can do this before n reaches 0.
; ───────────────────────────────────────────────────────────────────────────
popcount_kernighan:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — counter starts at zero

.pk_loop:
    test rdi, rdi           ; is rdi == 0? (AND with itself, sets ZF if zero)
    jz   .pk_done           ; yes — no more set bits to count

    mov  rcx, rdi           ; rcx = n — copy current value
    dec  rcx                ; rcx = n - 1
    and  rdi, rcx           ; rdi = n & (n-1) — clears the lowest set bit
    inc  rax                ; we just eliminated one set bit — count it

    jmp  .pk_loop           ; check again

.pk_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total number of set bits

; ───────────────────────────────────────────────────────────────────────────
; popcount_buf_scalar — popcount of a byte buffer using scalar method
;   Input:  rdi = pointer to byte buffer
;           rsi = number of bytes
;   Output: rax = total number of set bits across all bytes
; ───────────────────────────────────────────────────────────────────────────
popcount_buf_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — buffer pointer (callee-saved)
    push r15                ; save r15 — total count (callee-saved)
    push rbx                ; save rbx — index (callee-saved)

    mov  r14, rdi           ; r14 = buffer pointer
    xor  r15, r15           ; r15 = total = 0
    xor  rbx, rbx           ; rbx = index = 0

.pbs_loop:
    cmp  rbx, rsi           ; index >= byte count?
    jge  .pbs_done          ; yes — done

    movzx rdi, byte [r14 + rbx]   ; rdi = current byte (zero-extended to 64 bits)
    call popcount_kernighan         ; rax = popcount of this byte

    add  r15, rax           ; r15 += popcount(byte)
    inc  rbx                ; advance to next byte
    jmp  .pbs_loop          ; loop

.pbs_done:
    mov  rax, r15           ; rax = total popcount (return value)

    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; popcount_buf_ssse3 — vectorized popcount of 16 bytes using SSSE3 pshufb trick
;   Input:  rdi = pointer to 16-byte buffer (need not be aligned)
;   Output: rax = total number of set bits in the 16 bytes
;
;   The pshufb instruction uses one register as a SHUFFLE CONTROL mask:
;   PSHUFB xmm_dst, xmm_src:
;     For each byte i of xmm_dst:
;       if xmm_src[i] has bit 7 set → result byte i = 0
;       else result byte i = xmm_dst[ xmm_src[i] & 0x0F ]
;   So we can use the nibble value (0-15) as an index into a lookup table!
; ───────────────────────────────────────────────────────────────────────────
popcount_buf_ssse3:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; Load the lookup table into xmm_lut (stays constant across all bytes)
    movdqu xmm5, [popcount_lut]   ; xmm5 = LUT: {4,3,3,2,...,1,0} for nibbles 15..0
                                   ; MOVDQU: Move Unaligned Double Quadword (16 bytes, any alignment)

    ; Create a mask of 0x0F in all 16 byte lanes
    ; We do this by loading the LUT bytes which happen to fit, then we PCMPeq or just use an immediate
    ; Easiest: use PCMPEQB to create all-0xFF, then shift right arithmetically
    ; Simpler: use a constant in .data
    movdqu xmm6, [nibble_mask]    ; xmm6 = {0x0F, 0x0F, ..., 0x0F} — 16 copies of 0x0F

    ; Load the 16 bytes to count
    movdqu xmm0, [rdi]            ; xmm0 = the 16 input bytes

    ; Extract LOW nibbles: lo = xmm0 & 0x0F (per byte)
    movdqa xmm1, xmm0             ; xmm1 = copy of input (MOVDQA: move aligned — valid since xmm1 is a register)
    pand   xmm1, xmm6             ; xmm1 = xmm0 & 0x0F — keep only the lower 4 bits of each byte
                                   ; PAND: Packed AND — bitwise AND all 16 bytes

    ; Extract HIGH nibbles: hi = (xmm0 >> 4) & 0x0F (per byte)
    movdqa xmm2, xmm0             ; xmm2 = copy of input
    psrlw  xmm2, 4                ; xmm2 = xmm0 >> 4 (shift all 16-bit words right by 4 bits)
                                   ; PSRLW: Packed Shift Right Logical Word (16-bit granularity)
                                   ; This shifts high nibble into low position (and contaminates the high bit of
                                   ; each byte with the high bit of the high nibble, which we clear next)
    pand   xmm2, xmm6             ; xmm2 = hi & 0x0F — clear any contamination from the shift
                                   ; PAND: Packed AND

    ; Look up popcount for each nibble
    ; PSHUFB uses each byte of xmm1/xmm2 as an INDEX into xmm5 (the LUT)
    pshufb xmm5, xmm1             ; xmm5 = LUT[lo_nibble] for each byte — popcount of low nibble
                                   ; PSHUFB (SSSE3): Packed Shuffle Bytes

    movdqu xmm4, [popcount_lut]   ; reload the LUT (pshufb modified xmm5)
    pshufb xmm4, xmm2             ; xmm4 = LUT[hi_nibble] for each byte — popcount of high nibble
                                   ; PSHUFB: uses xmm2 as index, xmm4 as table

    ; Sum nibble popcounts per byte: popcount(byte) = pop(lo nibble) + pop(hi nibble)
    paddb  xmm5, xmm4             ; xmm5 = per-byte popcount (add the two nibble counts)
                                   ; PADDB: Packed Add Bytes — adds 16 pairs of bytes

    ; Sum all 16 byte popcounts
    ; PSADBW computes: for each group of 8 bytes, compute sum of absolute differences with 0
    ; Since all values are positive, |x - 0| = x, so PSADBW with zero simply sums groups of 8.
    pxor   xmm0, xmm0             ; xmm0 = {0 x 16} — all zeros (XOR with self)
                                   ; PXOR: Packed XOR — fastest way to zero an XMM register
    psadbw xmm5, xmm0             ; xmm5 = sum of bytes 0-7 in low 64 bits, sum of bytes 8-15 in high 64 bits
                                   ; PSADBW: Packed Sum of Absolute Differences of Bytes against zero

    ; Extract the two 64-bit halves and sum them
    movq   rax, xmm5              ; rax = lower 64 bits = sum of bytes 0-7
                                   ; MOVQ: move quadword from XMM to 64-bit general register
    psrldq xmm5, 8                ; shift xmm5 right by 8 bytes to move upper sum to lower position
                                   ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movq   rcx, xmm5              ; rcx = sum of bytes 8-15

    add    rax, rcx               ; rax = total popcount = sum_low + sum_high

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total set bits in the 16 bytes

section .data
    align 16
    nibble_mask  db 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F
                 db 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F

section .text

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers
; ───────────────────────────────────────────────────────────────────────────
print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pu_d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pu_t

.pu_d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pu_d

.pu_t:
    mov  byte [rbx], 0
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pu_r:
    cmp  rsi, rdi
    jge  .pu_w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pu_r
.pu_w:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pc:
    cmp  byte [rdi + rcx], 0
    je   .pc_w
    inc  rcx
    jmp  .pc
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
    ; Scalar popcount of the 16-byte test buffer
    mov  rdi, lbl_scalar
    call print_cstr

    mov  rdi, test_buf      ; rdi = buffer pointer
    mov  rsi, 16            ; rsi = 16 bytes
    call popcount_buf_scalar ; rax = total set bits

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; SSSE3 vectorized popcount of the same buffer
    mov  rdi, lbl_ssse3
    call print_cstr

    mov  rdi, test_buf      ; rdi = buffer pointer (16 bytes)
    call popcount_buf_ssse3 ; rax = total set bits

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Single 64-bit value popcount
    mov  rdi, lbl_val
    call print_cstr

    mov  rdi, 0xDEADBEEF12345678   ; rdi = 64-bit test value
    call popcount_kernighan         ; rax = popcount

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
