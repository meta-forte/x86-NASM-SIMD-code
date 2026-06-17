;═══════════════════════════════════════════════════════════════════════════════
; §08  Endian Swap
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 08_endian_swap.asm
;  Description : 32/64-bit byte reversal: BSWAP instruction vs PSHUFB mask
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 08_endian_swap.asm — Reverse byte order (endian swap) of 32/64-bit words
; Goal: understand shuffle/permutation instructions (pshufb, bswap)
;
; "Big-endian" stores the most significant byte first (e.g., network order).
; "Little-endian" stores the least significant byte first (x86 native order).
; Converting between them requires reversing the bytes of each word.
;
; Example (32-bit): 0x12345678 stored as [12][34][56][78] (big-endian)
;                   in little-endian memory: [78][56][34][12]
;   BSWAP converts between the two:
;   BSWAP 0x12345678 → 0x78563412
;
; We implement:
;   1. SCALAR: use BSWAP instruction on each 32-bit or 64-bit word
;   2. SSE2/SSSE3: use PSHUFB to reverse bytes within multiple words simultaneously
;      PSHUFB can swap bytes within an XMM register based on a shuffle mask.
;
; PSHUFB recap:
;   PSHUFB xmm_data, xmm_mask
;   For each output byte i:
;     if mask[i] bit 7 == 1 → output[i] = 0
;     else output[i] = data[ mask[i] & 0x0F ]  (just the low 4 bits = index 0-15)
;
;   So a mask of [3,2,1,0, 7,6,5,4, 11,10,9,8, 15,14,13,12] reverses each 4-byte word.
;
; Build:
;   nasm -f elf64 08_endian_swap.asm -o bin/08_endian_swap.o
;   ld bin/08_endian_swap.o -o bin/08_endian_swap
; Run:
;   ./bin/08_endian_swap
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16

    ; Test buffer of 4 x 32-bit words
    buf32    dd 0x12345678, 0xDEADBEEF, 0x00010203, 0xCAFEBABE

    ; Test buffer of 2 x 64-bit words
    buf64    dq 0x0102030405060708, 0xDEADBEEFCAFEBABE

    ; PSHUFB mask to reverse bytes within each 4-byte (dword) group
    ; Byte position: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
    ; Source index:  3  2  1  0  7  6  5  4  11 10  9  8 15 14 13 12
    ; Meaning: output byte 0 comes from input byte 3, etc.
    shuf32_mask  db 3, 2, 1, 0,  7, 6, 5, 4,  11, 10, 9, 8,  15, 14, 13, 12

    ; PSHUFB mask to reverse bytes within each 8-byte (qword) group
    ; Byte position: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
    ; Source index:  7  6  5  4  3  2  1  0  15 14 13 12 11 10  9  8
    shuf64_mask  db 7, 6, 5, 4,  3, 2, 1, 0,  15, 14, 13, 12,  11, 10, 9, 8

    lbl_before32  db "Before (32-bit):  ", 0
    lbl_after32   db "After  (32-bit):  ", 0
    lbl_before64  db "Before (64-bit):  ", 0
    lbl_after64   db "After  (64-bit):  ", 0
    lbl_pshufb32  db "PSHUFB (32-bit):  ", 0
    newline       db 10
    space         db " ", 0
    hex_prefix    db "0x", 0

section .bss
    out_bswap   resd 4      ; output from scalar BSWAP on 32-bit values
    out_pshufb  resd 4      ; output from PSHUFB on 32-bit values
    num_buf     resb 20

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; bswap32_buf — reverse bytes of each 32-bit word in a buffer (scalar)
;   Input:  rdi = pointer to uint32_t array
;           rsi = pointer to output uint32_t array
;           rdx = count (number of 32-bit words)
;
;   BSWAP reg32 — reverses the 4 bytes of the 32-bit register
;   0x12345678 → 0x78563412
; ───────────────────────────────────────────────────────────────────────────
bswap32_buf:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rcx, rcx           ; rcx = 0 — index

.bs32_loop:
    cmp  rcx, rdx           ; index >= count?
    jge  .bs32_done         ; yes — done

    mov  eax, [rdi + rcx*4] ; eax = input word (load 32-bit unsigned integer)
    bswap eax               ; reverse the 4 bytes in eax
                            ; BSWAP eax: eax = ((eax & 0xFF) << 24) | ... | ((eax >> 24) & 0xFF)
    mov  [rsi + rcx*4], eax ; store swapped word to output

    inc  rcx                ; next word
    jmp  .bs32_loop         ; loop

.bs32_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; bswap32_pshufb — reverse bytes within each 32-bit word, 4 words at a time (SSE)
;   Input:  rdi = pointer to 4 x uint32_t (16 bytes, ideally 16-byte aligned)
;           rsi = pointer to output (16 bytes)
;
;   PSHUFB xmm_data, xmm_mask:
;     Uses mask bytes as source indices to rearrange data bytes.
;     We use shuf32_mask which maps each dword to its byte-reversed version.
; ───────────────────────────────────────────────────────────────────────────
bswap32_pshufb:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    movdqu xmm0, [rdi]         ; xmm0 = 4 input words (16 bytes, unaligned load)
                                ; MOVDQU: Move Unaligned Double Quadword
    movdqa xmm1, [shuf32_mask] ; xmm1 = our shuffle mask (load the mask array)
                                ; MOVDQA: Move Aligned Double Quadword (aligned because of 'align 16')

    pshufb xmm0, xmm1          ; xmm0 = byte-reversed 4 dwords
                                ; PSHUFB (SSSE3): for each of 16 output bytes:
                                ;   output[i] = input[ mask[i] ]
                                ; With our mask this reverses bytes within each 4-byte group

    movdqu [rsi], xmm0         ; store the 4 byte-swapped words
                                ; MOVDQU: Move Unaligned Double Quadword (store)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; bswap64_scalar — reverse bytes of a 64-bit value (scalar)
;   Input:  rdi = uint64_t value
;   Output: rax = byte-reversed value
;
;   BSWAP rdi — reverses all 8 bytes of the 64-bit register
; ───────────────────────────────────────────────────────────────────────────
bswap64_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = input value
    bswap rax               ; reverse the 8 bytes: byte 7 ↔ byte 0, byte 6 ↔ byte 1, etc.
                            ; BSWAP rax: for a 64-bit register, reverses all 8 bytes

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = byte-swapped 64-bit value

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────

; print_hex32 — print 32-bit value as "0xXXXXXXXX" with space after
;   Input: edi = 32-bit value
print_hex32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    ; Convert to 8-char hex string (leading zeros)
    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, 8             ; rbx = digit counter (8 hex digits for 32-bit)
    movzx rdi, edi          ; zero-extend to 64-bit

.ph32_loop:
    ; Extract leftmost 4 bits of the remaining value
    mov  rax, rdi           ; rax = value
    mov  rcx, 8             ; we need to isolate 4 bits = 1 hex digit
    lea  rcx, [rbx - 1]     ; digit position (0=leftmost, 7=rightmost)
    mov  rcx, rbx           ; rcx = remaining digits
    dec  rcx                ; rcx = remaining - 1
    imul rcx, rcx, 4        ; rcx = bit position = (remaining-1) * 4
    mov  rax, rdi
    shr  rax, cl            ; shift to get the nibble at top
    and  rax, 0xF           ; isolate just the 4 bits

    cmp  rax, 10            ; < 10?
    jl   .ph32_num
    add  al, 'A' - 10       ; 'A'-'F'
    jmp  .ph32_store
.ph32_num:
    add  al, '0'            ; '0'-'9'
.ph32_store:
    mov  rcx, 8             ; rcx = 8
    sub  rcx, rbx           ; rcx = 8 - rbx = index into digit buffer
    add  rcx, 2             ; offset by 2 for "0x" prefix
    mov  [r12 + rcx], al

    dec  rbx
    jnz  .ph32_loop

    ; Write "0x" prefix then 8 hex digits
    mov  byte [r12], '0'
    mov  byte [r12 + 1], 'x'
    mov  byte [r12 + 10], ' '

    mov  rdi, 1             ; stdout
    mov  rsi, r12           ; buffer
    mov  rdx, 11            ; "0x" + 8 digits + space = 11 chars
    mov  rax, 1             ; write
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; print_hex64 — print 64-bit value as "0xXXXXXXXXXXXXXXXX"
;   Input: rdi = 64-bit value
print_hex64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf       ; buffer start
    mov  rbx, 16            ; 16 hex digits for 64-bit
    mov  r8, rdi            ; r8 = value

.ph64_loop:
    lea  rcx, [rbx - 1]
    imul rcx, rcx, 4        ; bit position = (remaining-1)*4
    mov  rax, r8
    shr  rax, cl
    and  rax, 0xF
    cmp  rax, 10
    jl   .ph64_num
    add  al, 'A' - 10
    jmp  .ph64_st
.ph64_num:
    add  al, '0'
.ph64_st:
    mov  rcx, 16            ; rcx = 16
    sub  rcx, rbx           ; rcx = 16 - rbx = digit index in buffer
    add  rcx, 2             ; offset by 2 for "0x" prefix
    mov  [r12 + rcx], al
    dec  rbx
    jnz  .ph64_loop

    mov  byte [r12], '0'
    mov  byte [r12 + 1], 'x'
    mov  byte [r12 + 18], 10  ; newline

    mov  rdi, 1
    mov  rsi, r12
    mov  rdx, 19            ; "0x" + 16 + '\n'
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
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
    ; ── 32-bit BSWAP demonstration ──
    mov  rdi, lbl_before32  ; "Before (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_before32:
    cmp  rbx, 4
    jge  .do_bswap32
    mov  edi, [buf32 + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_before32

.do_bswap32:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Scalar BSWAP
    mov  rdi, buf32         ; input
    mov  rsi, out_bswap     ; output
    mov  rdx, 4             ; 4 words
    call bswap32_buf

    mov  rdi, lbl_after32   ; "After  (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_after32:
    cmp  rbx, 4
    jge  .do_pshufb
    mov  edi, [out_bswap + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_after32

.do_pshufb:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; PSHUFB BSWAP
    mov  rdi, buf32         ; input
    mov  rsi, out_pshufb    ; output
    call bswap32_pshufb

    mov  rdi, lbl_pshufb32  ; "PSHUFB (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_pshufb:
    cmp  rbx, 4
    jge  .do_bswap64
    mov  edi, [out_pshufb + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_pshufb

.do_bswap64:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── 64-bit BSWAP demonstration ──
    mov  rdi, lbl_before64  ; "Before (64-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_b64:
    cmp  rbx, 2
    jge  .after64
    mov  rdi, [buf64 + rbx*8]
    call print_hex64
    inc  rbx
    jmp  .p_b64

.after64:
    mov  rdi, lbl_after64   ; "After  (64-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_a64:
    cmp  rbx, 2
    jge  .done
    mov  rdi, [buf64 + rbx*8]
    call bswap64_scalar
    mov  rdi, rax
    call print_hex64
    inc  rbx
    jmp  .p_a64

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi           ; exit code 0
    syscall
