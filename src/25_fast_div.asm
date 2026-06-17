;═══════════════════════════════════════════════════════════════════════════════
; §25  Fast Division
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 25_fast_div.asm
;  Description : Magic-number multiply (Hacker's Delight): div7 and div10
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 25_fast_div.asm — Fast integer division by a constant using "magic number" method
; Goal: understand multiply-shift optimizations that compilers use
;
; Problem: integer division is slow on modern CPUs (20-90 cycles for IDIV).
;          If the divisor is a compile-time constant, compilers replace it with
;          a multiply + shift sequence that takes 3-5 cycles.
;
; Hacker's Delight method (Warren, "Hacker's Delight" chapter 10):
;   To compute n / d for a constant d > 0 and 64-bit unsigned n:
;     1. Compute magic number M = ceil(2^(64+p) / d)
;        where p is chosen so that M fits in 64 bits.
;     2. Division approximation: q = (M * n) >> (64 + p)
;
; In practice, compilers precompute (M, shift) at compile time.
; We hard-code examples for divisors 7 and 10 to illustrate the pattern.
;
; Reference: Henry S. Warren Jr., "Hacker's Delight", 2nd ed., Chapter 10.
;
; Build:
;   nasm -f elf64 25_fast_div.asm -o bin/25_fast_div.o
;   ld bin/25_fast_div.o -o bin/25_fast_div
; Run:
;   ./bin/25_fast_div
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; ── Magic number table ──
    ;
    ; For UNSIGNED 64-bit division by 7:
    ;   M = 0x2492492492492493  (magic multiplier)
    ;   post-shift = 2
    ;   The formula: (mulhi(n, M) >> 2) gives floor(n / 7)
    ;
    ; For UNSIGNED 64-bit division by 10:
    ;   M = 0xCCCCCCCCCCCCCCCD  (magic multiplier)
    ;   post-shift = 3
    ;   The formula: (mulhi(n, M) >> 3) gives floor(n / 10)
    ;
    ; "mulhi" means the UPPER 64 bits of the 128-bit product (n * M).
    ; On x86-64, MUL rax, src gives rdx:rax; we only need rdx (the high part).

    magic7   dq 0x2492492492492493  ; magic multiplier for division by 7
    shift7   dq 2                   ; post-shift amount for division by 7

    magic10  dq 0xCCCCCCCCCCCCCCCD  ; magic multiplier for division by 10
    shift10  dq 3                   ; post-shift amount for division by 10

    ; Test values: n / 7 and n / 10 for several n
    test_vals  dq 0, 1, 7, 14, 63, 100, 1000, 9999999999
    test_n     equ ($ - test_vals) / 8

    hdr_7   db "n           n/7 (magic)  n/7 (div)", 10
    hdr_7_l equ $ - hdr_7
    hdr_10  db "n           n/10 (magic) n/10(div)", 10
    hdr_10_l equ $ - hdr_10
    sep     db "---         -----------  ---------", 10
    sep_l   equ $ - sep
    col2    db "  ", 0
    newline db 10

section .bss
    num_buf  resb 24

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; fast_div7 — compute floor(n / 7) using magic number multiplication
;   Input:  rdi = unsigned 64-bit dividend n
;   Output: rax = floor(n / 7)
;
;   Steps:
;   1. Load magic number M = 0x2492492492492493
;   2. Compute rdx:rax = n * M  (128-bit product) using MUL
;   3. rdx = upper 64 bits of product = mulhi(n, M)
;   4. Average trick for this particular divisor 7:
;      Because 7 is not a power of 2, the magic includes a "+1" correction.
;      We compute: q = ((n - rdx) >> 1) + rdx) >> 2
;      (This handles the case where M > 2^64 was rounded)
;
;   For divisor 7 specifically, the magic 0x2492492492492493 overshoots by 1,
;   so we use: q = (((n - mulhi) >> 1) + mulhi) >> shift
; ───────────────────────────────────────────────────────────────────────────
fast_div7:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — MUL requires one operand in rax
    mul  qword [magic7]     ; rdx:rax = n * M — 128-bit unsigned multiply
                            ; MUL: unsigned multiply rax * operand; high 64 bits → rdx, low → rax
                            ; We only need rdx (the high half = mulhi)

    ; For divisor 7, the magic number requires an "averaging" correction:
    ;   q = (((n - rdx) >> 1) + rdx) >> 2
    sub  rdi, rdx           ; rdi = n - mulhi
    shr  rdi, 1             ; rdi = (n - mulhi) >> 1
    add  rdx, rdi           ; rdx = mulhi + ((n - mulhi) >> 1)
    shr  rdx, 2             ; rdx = quotient = above >> 2  (shift = 2 for divisor 7)

    mov  rax, rdx           ; rax = quotient — move to return register

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = floor(n / 7)

; ───────────────────────────────────────────────────────────────────────────
; fast_div10 — compute floor(n / 10) using magic number multiplication
;   Input:  rdi = unsigned 64-bit dividend n
;   Output: rax = floor(n / 10)
;
;   For divisor 10, the magic 0xCCCCCCCCCCCCCCCD works cleanly:
;   q = mulhi(n, M) >> 3
;   No correction needed because M/2^68 approximates 1/10 exactly enough.
; ───────────────────────────────────────────────────────────────────────────
fast_div10:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend into rax for MUL
    mul  qword [magic10]    ; rdx:rax = n * M — 128-bit unsigned multiply
                            ; rdx = upper 64 bits = mulhi(n, M)

    shr  rdx, 3             ; rdx = mulhi >> 3 — post-shift (shift = 3 for divisor 10)
                            ; SHR: Shift Logical Right — divides by 2^3 = 8

    mov  rax, rdx           ; rax = quotient

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = floor(n / 10)

; ───────────────────────────────────────────────────────────────────────────
; exact_div7 — compute floor(n / 7) using the actual DIV instruction
;   Input:  rdi = unsigned 64-bit n
;   Output: rax = floor(n / 7)
;   This is the "slow" reference version for comparison.
; ───────────────────────────────────────────────────────────────────────────
exact_div7:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend
    xor  rdx, rdx           ; rdx = 0 — clear high half of 128-bit dividend
    mov  rcx, 7             ; rcx = 7 — divisor
    div  rcx                ; rax = n / 7 (quotient), rdx = n % 7 (remainder)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = n / 7

; ───────────────────────────────────────────────────────────────────────────
; exact_div10 — compute floor(n / 10) using the actual DIV instruction
;   Input:  rdi = unsigned 64-bit n
;   Output: rax = floor(n / 10)
; ───────────────────────────────────────────────────────────────────────────
exact_div10:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend
    xor  rdx, rdx           ; rdx = 0 — clear high half
    mov  rcx, 10            ; rcx = 10 — divisor
    div  rcx                ; rax = n / 10, rdx = n % 10

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = n / 10

; ───────────────────────────────────────────────────────────────────────────
; print_u64_padded — print unsigned 64-bit integer, space-padded to width 12
;   Input: rdi = number
; ───────────────────────────────────────────────────────────────────────────
print_u64_padded:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax
    jnz  .pp_dig

    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pp_term

.pp_dig:
    xor  rdx, rdx           ; rdx = 0
    mov  rcx, 10            ; divisor
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'            ; to ASCII
    mov  [rbx], dl          ; store
    inc  rbx
    test rax, rax
    jnz  .pp_dig

.pp_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pp_rev:
    cmp  rsi, rdi
    jge  .pp_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pp_rev

.pp_wr:
    ; Print the digits
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12           ; actual length

    ; Pad with spaces on the right to width 12
    push rdx                ; save actual length
    mov  rdi, 1
    mov  rax, 1
    syscall

    ; Print spaces to fill to 12
    pop  rdx                ; actual length
    mov  rcx, 12
    sub  rcx, rdx           ; spaces needed = 12 - actual_length
    jle  .pp_done           ; no spaces needed

.pp_spaces:
    push rcx
    mov  rdi, 1
    mov  rsi, space_char
    mov  rdx, 1
    mov  rax, 1
    syscall
    pop  rcx
    dec  rcx
    jnz  .pp_spaces

.pp_done:
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

section .data
    space_char  db " "

section .text

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print table header for /7 column
    mov  rdi, 1             ; stdout
    mov  rsi, hdr_7         ; header
    mov  rdx, hdr_7_l       ; length
    mov  rax, 1             ; write
    syscall

    mov  rdi, 1             ; stdout
    mov  rsi, sep           ; separator
    mov  rdx, sep_l         ; length
    mov  rax, 1             ; write
    syscall

    ; Loop: print n, n/7(magic), n/7(exact) for each test value
    xor  r15, r15           ; r15 = index = 0

.loop7:
    cmp  r15, test_n        ; done?
    jge  .print_10_header   ; yes

    mov  r14, [test_vals + r15*8]  ; r14 = n

    mov  rdi, r14           ; rdi = n
    call print_u64_padded   ; print n

    mov  rdi, r14           ; rdi = n
    call fast_div7          ; rax = n/7 via magic
    mov  rdi, rax
    call print_u64_padded   ; print magic result

    mov  rdi, r14           ; rdi = n
    call exact_div7         ; rax = n/7 via DIV
    mov  rdi, rax
    call print_u64_padded   ; print exact result

    mov  rdi, 1             ; newline
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  r15
    jmp  .loop7

.print_10_header:
    ; Blank line
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    mov  rdi, 1
    mov  rsi, hdr_10
    mov  rdx, hdr_10_l
    mov  rax, 1
    syscall

    mov  rdi, 1
    mov  rsi, sep
    mov  rdx, sep_l
    mov  rax, 1
    syscall

    xor  r15, r15           ; r15 = index = 0
.loop10:
    cmp  r15, test_n
    jge  .done

    mov  r14, [test_vals + r15*8]  ; r14 = n

    mov  rdi, r14
    call print_u64_padded

    mov  rdi, r14
    call fast_div10
    mov  rdi, rax
    call print_u64_padded

    mov  rdi, r14
    call exact_div10
    mov  rdi, rax
    call print_u64_padded

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  r15
    jmp  .loop10

.done:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)
