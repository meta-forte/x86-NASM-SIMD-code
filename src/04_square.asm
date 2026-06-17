; =============================================================================
; square.asm — Compute and print the square of a number
;
; Description:
;   Asks the user for an integer N and prints N² = N * N.
;
; Concepts:
;   • imul rax, rax — squaring via self-multiply
;   • Stack slot for a single integer variable (no .bss)
;   • Minimal IO subroutines: read_int, print_result
;
; Build:
;   nasm -f elf64 square.asm -o obj/square.o
;   gcc   obj/square.o -o bin/square -no-pie
;
; Run:
;   ./bin/square
; =============================================================================

global main
extern printf, scanf

section .data

    prompt  db "Enter a number: ", 0
    fmt_in  db "%ld", 0                 ; scanf: read 64-bit signed integer
    fmt_out db "%ld squared = %ld", 10, 0
    ; Output: "N squared = N*N\n"

section .text

; ── read_int ──────────────────────────────────────────────────────────────────
; Read one 64-bit signed integer.
; Args: rdi = scanf format string, rsi = address of destination variable
; ──────────────────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax            ; variadic: 0 float args
    call    scanf
    pop     rbp
    ret

; ── print_result ──────────────────────────────────────────────────────────────
; Print the result line.
; Args: rdi = format, rsi = N, rdx = N²
; ──────────────────────────────────────────────────────────────────────────────
print_result:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    printf
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout:
;   [rbp - 8]  = N  (user input, 64-bit)
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16             ; 16-byte aligned: (ret 8)+(rbp 8)+(sub 16) = 32 ✓

    ; ── Print prompt ──────────────────────────────────────────────────────────
    lea     rdi, [rel prompt]
    xor     eax, eax
    call    printf

    ; ── Read N ────────────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 8]      ; rsi = &N (stack slot)
    call    read_int

    ; ── Compute N² ────────────────────────────────────────────────────────────
    mov     rax, [rbp - 8]      ; rax = N
    imul    rax, rax            ; rax = N * N  (signed 64-bit self-multiply)
    ; imul with two identical operands squares the value.
    ; Result fits in 64 bits for values up to ~3 billion.

    ; ── Print result ──────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_out]
    mov     rsi, [rbp - 8]      ; rsi = N
    mov     rdx, rax            ; rdx = N²
    call    print_result

    xor     eax, eax
    leave
    ret
