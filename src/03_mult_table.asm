; =============================================================================
; mult_table.asm — Print the multiplication table for a user-supplied number
;
; Description:
;   Asks the user for a number N and prints its multiplication table from
;   1 to 10 in the format:
;       N x 1  = N
;       N x 2  = 2N
;       ...
;       N x 10 = 10N
;
; Concepts:
;   • Stack-based local storage (no .bss)
;   • Loop with a counter held in a callee-saved register
;   • imul — signed 64-bit multiply
;   • Separate IO subroutines (read_int, print_row)
;
; Build:
;   nasm -f elf64 mult_table.asm -o obj/mult_table.o
;   gcc   obj/mult_table.o -o bin/mult_table -no-pie
;
; Run:
;   ./bin/mult_table
; =============================================================================

global main
extern printf, scanf

; -----------------------------------------------------------------------------
; SECTION .data — string constants
; -----------------------------------------------------------------------------
section .data

    prompt      db "Enter a number: ", 0
    fmt_in      db "%ld", 0             ; scanf format: read a 64-bit signed int
    fmt_row     db "%ld x %ld = %ld", 10, 0
    ; Row format: "N x i = product\n"
    ; Three %ld placeholders: N, i, N*i

; -----------------------------------------------------------------------------
; SECTION .text
; -----------------------------------------------------------------------------
section .text

; ── print_prompt ──────────────────────────────────────────────────────────────
; Print the prompt string to stdout.
; Args: rdi = pointer to null-terminated string
; ──────────────────────────────────────────────────────────────────────────────
print_prompt:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax            ; 0 floating-point args
    call    printf
    pop     rbp
    ret

; ── read_int ──────────────────────────────────────────────────────────────────
; Read one 64-bit signed integer from stdin using scanf.
; Args   : rdi = format string, rsi = pointer to destination (int64 on stack)
; Returns: the value written into *rsi (caller reads it)
; ──────────────────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax            ; 0 floating-point args
    call    scanf               ; scanf(fmt, &dest) — writes integer to *rsi
    pop     rbp
    ret

; ── print_row ─────────────────────────────────────────────────────────────────
; Print one row of the table: "N x i = product\n"
; Args: rdi = format string
;       rsi = N
;       rdx = i (multiplier, 1..10)
;       rcx = product (N * i)
; ──────────────────────────────────────────────────────────────────────────────
print_row:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax            ; 0 floating-point args
    call    printf              ; printf(fmt, N, i, product)
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout inside main:
;   [rbp - 8]  = N   (the number entered by the user, 64-bit)
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16             ; reserve 16 bytes on the stack (8 for N, 8 padding for alignment)
    ; Total frame: (ret 8) + (rbp 8) + (sub 16) = 32 bytes. 32/16 = 2 ✓

    ; ── Print prompt ──────────────────────────────────────────────────────────
    lea     rdi, [rel prompt]   ; rdi = "Enter a number: "
    call    print_prompt

    ; ── Read N from the user ──────────────────────────────────────────────────
    lea     rdi, [rel fmt_in]   ; rdi = "%ld"  (format for scanf)
    lea     rsi, [rbp - 8]      ; rsi = &N     (scanf writes into this stack slot)
    call    read_int

    ; ── Loop i = 1 .. 10 ──────────────────────────────────────────────────────
    mov     r12, [rbp - 8]      ; r12 = N  (callee-saved — survives printf calls)
    mov     r13, 1              ; r13 = i = 1  (loop counter, callee-saved)

.loop:
    cmp     r13, 10             ; compare i with 10
    jg      .done               ; if i > 10, we've printed all rows

    mov     rax, r12            ; rax = N
    imul    rax, r13            ; rax = N * i  (signed 64-bit multiply; result in rax)

    lea     rdi, [rel fmt_row]  ; rdi = "%ld x %ld = %ld\n"
    mov     rsi, r12            ; rsi = N   (1st %ld)
    mov     rdx, r13            ; rdx = i   (2nd %ld)
    mov     rcx, rax            ; rcx = N*i (3rd %ld)
    call    print_row

    inc     r13                 ; i++
    jmp     .loop               ; next row

.done:
    ; ── Restore stack and return ───────────────────────────────────────────────
    xor     eax, eax            ; return 0
    leave                       ; mov rsp, rbp / pop rbp
    ret
