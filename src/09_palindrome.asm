; =============================================================================
; palindrome.asm — Check whether an integer is a palindrome
;
; Description:
;   Asks the user for a non-negative integer and prints whether its decimal
;   representation reads the same forwards and backwards.
;   e.g.  12321 → palindrome,  12345 → not a palindrome
;
; Algorithm:
;   Extract digits of N one by one (using mod 10) and build the reversed
;   number.  If reversed == original, it is a palindrome.
;   Negative numbers are never palindromes (the leading '-' breaks symmetry).
;
; Concepts:
;   • idiv / cqo for extracting decimal digits
;   • imul to rebuild the reversed number
;   • Conditional branch to print one of two messages
;
; Build:
;   nasm -f elf64 palindrome.asm -o obj/palindrome.o
;   gcc   obj/palindrome.o -o bin/palindrome -no-pie
;
; Run:
;   ./bin/palindrome
; =============================================================================

global main
extern printf, scanf

section .data

    prompt      db "Enter a number: ", 0
    fmt_in      db "%ld", 0
    msg_yes     db "%ld is a palindrome.", 10, 0
    msg_no      db "%ld is NOT a palindrome.", 10, 0
    msg_neg     db "Negative numbers are not palindromes.", 10, 0

section .text

; ── read_int ──────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── print_result ──────────────────────────────────────────────────────────────
; Args: rdi = format string,  rsi = N (the original number)
print_result:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    printf
    pop     rbp
    ret

; ── is_palindrome ─────────────────────────────────────────────────────────────
; Check whether integer N is a decimal palindrome.
; Args   : rdi = N
; Returns: rax = 1 if palindrome,  0 if not,  -1 if negative
; ──────────────────────────────────────────────────────────────────────────────
is_palindrome:
    ; Negative → not a palindrome (return -1 so caller can show special message)
    test    rdi, rdi            ; set flags on N
    js      .negative           ; jump if sign flag set (N < 0)

    ; Special case: 0 is a palindrome
    jz      .yes

    mov     r8, rdi             ; r8  = original N (preserved for final compare)
    xor     r9, r9              ; r9  = reversed = 0
    mov     r10, rdi            ; r10 = working copy of N (we'll destroy it digit by digit)
    mov     r11, 10             ; r11 = 10  (divisor for mod/div)

.digit_loop:
    test    r10, r10            ; is the working copy zero?
    jz      .compare            ; yes → all digits consumed

    mov     rax, r10            ; rax = current value
    cqo                         ; sign-extend into rdx:rax
    idiv    r11                 ; rax = value / 10,  rdx = value mod 10 (= last digit)

    imul    r9, r11             ; reversed = reversed * 10   (shift left one decimal place)
    add     r9, rdx             ; reversed = reversed * 10 + digit  (append digit on right)

    mov     r10, rax            ; value = value / 10  (drop last digit)
    jmp     .digit_loop

.compare:
    cmp     r8, r9              ; original == reversed?
    je      .yes
    xor     rax, rax            ; rax = 0 (not a palindrome)
    ret

.yes:
    mov     rax, 1              ; rax = 1 (palindrome)
    ret

.negative:
    mov     rax, -1             ; rax = -1 (negative number)
    ret

; ── main ──────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16             ; 8 for N, 8 padding  — (ret 8)+(rbp 8)+(16) = 32 ✓

    ; ── Print prompt and read N ───────────────────────────────────────────────
    lea     rdi, [rel prompt]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 8]
    call    read_int

    ; ── Call is_palindrome ────────────────────────────────────────────────────
    mov     rdi, [rbp - 8]      ; rdi = N
    mov     r12, rdi            ; r12 = N  (save for printing after the call)
    call    is_palindrome       ; rax = 1 / 0 / -1

    ; ── Print the appropriate message ─────────────────────────────────────────
    cmp     rax, -1
    je      .print_neg

    cmp     rax, 1
    je      .print_yes

    ; rax == 0  → not a palindrome
    lea     rdi, [rel msg_no]
    mov     rsi, r12
    call    print_result
    jmp     .exit

.print_yes:
    lea     rdi, [rel msg_yes]
    mov     rsi, r12
    call    print_result
    jmp     .exit

.print_neg:
    lea     rdi, [rel msg_neg]
    xor     eax, eax
    call    printf              ; no %ld argument — just print the static string

.exit:
    xor     eax, eax
    leave
    ret
