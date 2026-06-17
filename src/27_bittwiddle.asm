;═══════════════════════════════════════════════════════════════════════════════
; §22  Bit Twiddling
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 22_bittwiddle.asm
;  Description : POPCNT, LZCNT, TZCNT hardware instructions; BSR/BSF fallbacks
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 22_bittwiddle.asm — popcount, clz (count leading zeros), ctz (count trailing zeros)
; Goal: bit manipulation instructions and fallback implementations
;
; Instructions demonstrated:
;   POPCNT dst, src   — count the number of set bits (1s) in src
;                       Requires CPU flag: POPCNT (available since Nehalem 2008)
;   LZCNT  dst, src   — count leading zero bits from the MSB side
;                       Requires CPU flag: LZCNT (available since Haswell 2013)
;   TZCNT  dst, src   — count trailing zero bits from the LSB side
;                       Requires CPU flag: BMI1 (available since Haswell 2013)
;   BSF    dst, src   — Bit Scan Forward — index of lowest set bit
;                       (undefined result when src == 0, unlike TZCNT)
;   BSR    dst, src   — Bit Scan Reverse — index of highest set bit
;
; Scalar fallback: we also implement popcount without the POPCNT instruction
; so you can see the bit-twiddling approach (Brian Kernighan's algorithm).
;
; Build:
;   nasm -f elf64 22_bittwiddle.asm -o bin/22_bittwiddle.o
;   ld bin/22_bittwiddle.o -o bin/22_bittwiddle
; Run:
;   ./bin/22_bittwiddle
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test values
    vals    dq 0, 1, 0xFF, 0x5555555555555555, 0xFFFFFFFFFFFFFFFF, 0x8000000000000000, 42
    vals_n  equ ($ - vals) / 8

    ; Labels for output columns
    hdr     db "Value              popcount  clz  ctz", 10
    hdr_len equ $ - hdr
    sep2    db "---                --------  ---  ---", 10
    sep2_len equ $ - sep2
    col_sep db "  ", 0
    newline db 10

section .bss
    num_buf  resb 24
    hex_buf  resb 20

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; popcount_hw — count set bits using the hardware POPCNT instruction
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits (0 to 64)
;
;   POPCNT is one clock cycle on modern CPUs — very fast.
; ───────────────────────────────────────────────────────────────────────────
popcount_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    popcnt rax, rdi         ; rax = number of 1-bits in rdi
                            ; POPCNT: populates rax with the population count of rdi

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = popcount

; ───────────────────────────────────────────────────────────────────────────
; popcount_scalar — count set bits without POPCNT (Brian Kernighan's trick)
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits
;
;   Trick: n & (n-1) clears the LOWEST set bit of n.
;   Example: n=0b1010, n-1=0b1001, n&(n-1)=0b1000 — cleared the lowest 1-bit.
;   Count iterations until n becomes 0.
; ───────────────────────────────────────────────────────────────────────────
popcount_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — bit counter starts at zero
    test rdi, rdi           ; is rdi zero? (no bits set)
    jz   .pc_done           ; yes — return 0 immediately

.pc_loop:
    mov  rcx, rdi           ; rcx = n — copy current value
    dec  rcx                ; rcx = n - 1
    and  rdi, rcx           ; rdi = n & (n-1) — clears the lowest set bit in n
    inc  rax                ; count this cleared bit
    test rdi, rdi           ; is rdi now zero? (no more set bits)
    jnz  .pc_loop           ; no — loop and clear the next bit

.pc_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = number of set bits

; ───────────────────────────────────────────────────────────────────────────
; clz_hw — count leading zero bits using LZCNT instruction
;   Input:  rdi = 64-bit value (input 0 gives result 64)
;   Output: rax = number of zero bits to the left of the highest set bit
;
;   Example: 0x0000_0001 → 63 leading zeros
;            0x8000_0000_0000_0000 → 0 leading zeros (MSB is set)
;            0 → 64 (special case: all bits are "leading zeros")
; ───────────────────────────────────────────────────────────────────────────
clz_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    lzcnt rax, rdi          ; rax = number of leading (most-significant) zero bits
                            ; LZCNT: well-defined for 0 (returns 64), unlike BSR

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = leading zero count

; ───────────────────────────────────────────────────────────────────────────
; clz_bsr — count leading zeros using BSR (Bit Scan Reverse) — no LZCNT needed
;   Input:  rdi = 64-bit value
;   Output: rax = leading zero count (64 if rdi == 0)
;
;   BSR finds the bit index of the highest set bit.
;   clz = 63 - BSR(x) for non-zero x.
; ───────────────────────────────────────────────────────────────────────────
clz_bsr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdi, rdi           ; is rdi zero?
    jz   .clz_zero          ; special case: return 64

    bsr  rax, rdi           ; rax = index of highest set bit (0-63)
                            ; BSR: scans from bit 63 down to bit 0; undefined for 0
    xor  rax, 63            ; rax = 63 - rax = number of leading zeros
                            ; (XOR with 63 is the same as 63 - rax when rax <= 63)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

.clz_zero:
    mov  rax, 64            ; clz(0) = 64 by convention
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; ctz_hw — count trailing zero bits using TZCNT instruction
;   Input:  rdi = 64-bit value (input 0 gives result 64)
;   Output: rax = number of zero bits below the lowest set bit
;
;   Example: 0b0000_1000 → 3 trailing zeros
;            0b0000_0001 → 0 trailing zeros (bit 0 is set)
; ───────────────────────────────────────────────────────────────────────────
ctz_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    tzcnt rax, rdi          ; rax = number of trailing (least-significant) zero bits
                            ; TZCNT: well-defined for 0 (returns 64)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = trailing zero count

; ───────────────────────────────────────────────────────────────────────────
; ctz_bsf — count trailing zeros using BSF (Bit Scan Forward) — no TZCNT needed
;   Input:  rdi = 64-bit value
;   Output: rax = trailing zero count (64 if rdi == 0)
;
;   BSF finds the bit index of the lowest set bit, which equals ctz for non-zero.
; ───────────────────────────────────────────────────────────────────────────
ctz_bsf:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdi, rdi           ; is rdi zero?
    jz   .ctz_zero          ; special case

    bsf  rax, rdi           ; rax = index of lowest set bit (= number of trailing zeros)
                            ; BSF: scans from bit 0 upward; undefined for 0

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

.ctz_zero:
    mov  rax, 64            ; ctz(0) = 64 by convention
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers (compact versions)
; ───────────────────────────────────────────────────────────────────────────

; print_u64_dec — print unsigned 64-bit integer without newline
;   Input: rdi = number
print_u64_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax           ; zero?
    jnz  .pd_dig            ; no

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .pd_term           ; done

.pd_dig:
    xor  rdx, rdx           ; rdx = 0
    mov  rcx, 10            ; rcx = 10
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'            ; to ASCII
    mov  [rbx], dl          ; store
    inc  rbx                ; advance
    test rax, rax           ; more?
    jnz  .pd_dig            ; yes

.pd_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]     ; last char
    mov  rsi, r12           ; first char
.pd_rev:
    cmp  rsi, rdi           ; crossed?
    jge  .pd_wr             ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance
    dec  rdi                ; advance
    jmp  .pd_rev            ; loop

.pd_wr:
    mov  rsi, r12           ; string start
    mov  rdx, rbx           ; end
    sub  rdx, r12           ; length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; print_u64_hex — print value as "0x<HEX>" with no newline
;   Input: rdi = number
print_u64_hex:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, hex_buf       ; r12 = buffer start
    mov  rbx, hex_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax           ; zero?
    jnz  .hx_dig

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx
    jmp  .hx_term

.hx_dig:
    mov  rcx, rax           ; rcx = current value
    and  rcx, 0xF           ; lowest nibble
    cmp  cl, 10             ; < 10?
    jl   .hx_num
    add  cl, 'A' - 10       ; 'A'-'F'
    jmp  .hx_st
.hx_num:
    add  cl, '0'            ; '0'-'9'
.hx_st:
    mov  [rbx], cl          ; store hex char
    inc  rbx                ; advance
    shr  rax, 4             ; next nibble
    test rax, rax           ; done?
    jnz  .hx_dig

.hx_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]     ; last char
    mov  rsi, r12           ; first char
.hx_rev:
    cmp  rsi, rdi
    jge  .hx_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .hx_rev

.hx_wr:
    ; Print "0x" prefix first
    push r12                ; save buffer start
    push rbx                ; save end pointer
    mov  rdi, 1             ; stdout
    mov  rsi, hex_prefix    ; "0x"
    mov  rdx, 2             ; 2 bytes
    mov  rax, 1             ; write
    syscall
    pop  rbx                ; restore end
    pop  r12                ; restore start

    mov  rsi, r12           ; string start
    mov  rdx, rbx           ; end
    sub  rdx, r12           ; length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length
.pcs_l:
    cmp  byte [rdi + rcx], 0
    je   .pcs_w
    inc  rcx
    jmp  .pcs_l
.pcs_w:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  rbp                ; restore caller's frame pointer
    ret

section .data
    hex_prefix  db "0x", 0

section .text

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print table header
    mov  rdi, 1             ; stdout
    mov  rsi, hdr           ; header string
    mov  rdx, hdr_len       ; header length
    mov  rax, 1             ; write
    syscall

    mov  rdi, 1             ; stdout
    mov  rsi, sep2          ; separator line
    mov  rdx, sep2_len      ; separator length
    mov  rax, 1             ; write
    syscall

    ; Loop over test values
    xor  r15, r15           ; r15 = index = 0

.vloop:
    cmp  r15, vals_n        ; done?
    jge  .fin               ; yes

    mov  r14, [vals + r15*8] ; r14 = current value

    ; Print hex value (padded): 0xXXXXXXXXXXXXXXXX
    mov  rdi, r14           ; rdi = value
    call print_u64_hex      ; print hex representation

    ; Spacer
    mov  rdi, col_sep       ; "  "
    call print_cstr

    ; popcount (hardware)
    mov  rdi, r14           ; rdi = value
    call popcount_hw        ; rax = popcount
    push rax                ; save result
    ; Also verify with scalar
    mov  rdi, r14           ; rdi = value
    call popcount_scalar    ; rax = scalar popcount (should match)
    pop  rdi                ; rdi = hw popcount (use hw result)
    call print_u64_dec      ; print it

    ; Spacer
    mov  rdi, col_sep
    call print_cstr
    mov  rdi, col_sep
    call print_cstr

    ; clz (leading zeros)
    mov  rdi, r14           ; rdi = value
    call clz_hw             ; rax = leading zeros
    mov  rdi, rax
    call print_u64_dec      ; print

    ; Spacer
    mov  rdi, col_sep
    call print_cstr
    mov  rdi, col_sep
    call print_cstr

    ; ctz (trailing zeros)
    mov  rdi, r14           ; rdi = value
    call ctz_hw             ; rax = trailing zeros
    mov  rdi, rax
    call print_u64_dec      ; print

    ; Newline
    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write
    syscall

    inc  r15                ; next value
    jmp  .vloop             ; loop

.fin:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)
