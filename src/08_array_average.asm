; =============================================================================
; array_average.asm — Compute the average of N integers
;
; Description:
;   Asks the user for N, then reads N integers and prints:
;       Sum = S,  Average = S / N  (integer division)
;
; Concepts:
;   • Stack array: sub rsp, N*8 conceptually; here we use a fixed-size frame
;     with room for up to 64 values (sufficient for the demo)
;   • Running sum accumulated in a callee-saved register
;   • idiv for integer division: quotient in rax, remainder in rdx
;
; Build:
;   nasm -f elf64 array_average.asm -o obj/array_average.o
;   gcc   obj/array_average.o -o bin/array_average -no-pie
;
; Run:
;   ./bin/array_average
; =============================================================================

global main
extern printf, scanf

section .data

    prompt_n    db "How many numbers? ", 0
    prompt_num  db "Enter number %ld: ", 0
    fmt_in      db "%ld", 0
    fmt_sum     db "Sum     = %ld", 10, 0
    fmt_avg     db "Average = %ld", 10, 0

section .text

; ── read_int ──────────────────────────────────────────────────────────────────
; Read one 64-bit integer.  rdi = fmt,  rsi = &dest
; ──────────────────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── print_long ────────────────────────────────────────────────────────────────
; Print a 64-bit integer with a given format string.
; Args: rdi = format,  rsi = value
; ──────────────────────────────────────────────────────────────────────────────
print_long:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    printf
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout:
;   [rbp -  8]         = N
;   [rbp - 16 - i*8]   = numbers[i]
; Max 64 entries ⟹ 8 + 64*8 + padding = 528 bytes reserved.
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 528

    ; ── Read N ────────────────────────────────────────────────────────────────
    lea     rdi, [rel prompt_n]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 8]
    call    read_int

    mov     r12, [rbp - 8]      ; r12 = N (callee-saved)

    ; ── Read N numbers into stack array ───────────────────────────────────────
    xor     r13, r13            ; i = 0

.read_loop:
    cmp     r13, r12
    jge     .read_done

    lea     rdi, [rel prompt_num]
    mov     rsi, r13
    inc     rsi
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    mov     rsi, rbp
    sub     rsi, 16             ; base of array (numbers[0] is at rbp-16)
    mov     rax, r13
    imul    rax, 8
    sub     rsi, rax            ; &numbers[i] = rbp - 16 - i*8
    call    read_int

    inc     r13
    jmp     .read_loop

.read_done:
    ; ── Sum all values ────────────────────────────────────────────────────────
    xor     r14, r14            ; r14 = sum = 0  (callee-saved)
    xor     r13, r13            ; i = 0

.sum_loop:
    cmp     r13, r12
    jge     .sum_done

    mov     rax, r13
    imul    rax, 8
    mov     rcx, rbp
    sub     rcx, 16
    sub     rcx, rax            ; rcx = &numbers[i]
    add     r14, [rcx]          ; sum += numbers[i]

    inc     r13
    jmp     .sum_loop

.sum_done:
    ; ── Print sum ─────────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_sum]
    mov     rsi, r14
    call    print_long

    ; ── Compute integer average = sum / N ─────────────────────────────────────
    mov     rax, r14            ; rax = sum  (dividend for idiv)
    cqo                         ; sign-extend rax into rdx:rax
    idiv    r12                 ; rax = sum / N  (quotient),  rdx = sum mod N (remainder, ignored)

    ; ── Print average ─────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_avg]
    mov     rsi, rax            ; rsi = average
    call    print_long

    xor     eax, eax
    leave
    ret
