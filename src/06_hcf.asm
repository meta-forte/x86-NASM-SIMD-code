; =============================================================================
; hcf.asm — Highest Common Factor (GCD) of N numbers
;
; Description:
;   Asks the user how many numbers to enter, reads them one by one, then
;   computes the HCF (= GCD) of all of them using the Euclidean algorithm.
;
;   The Euclidean algorithm:
;       GCD(a, 0) = a
;       GCD(a, b) = GCD(b, a mod b)
;   Folded over N numbers: HCF = GCD(GCD(GCD(a1, a2), a3), ...)
;
; Concepts:
;   • Euclidean algorithm implemented with cqo + idiv
;   • Stack array for the input numbers (no .bss)
;   • Loop fold over a stack-allocated array
;
; Build:
;   nasm -f elf64 hcf.asm -o obj/hcf.o
;   gcc   obj/hcf.o -o bin/hcf -no-pie
;
; Run:
;   ./bin/hcf
; =============================================================================

global main
extern printf, scanf

section .data

    prompt_n    db "How many numbers? ", 0
    prompt_num  db "Enter number %ld: ", 0  ; printf with loop index
    fmt_in      db "%ld", 0
    fmt_out     db "HCF = %ld", 10, 0

section .text

; ── gcd ───────────────────────────────────────────────────────────────────────
; Compute GCD(a, b) using the iterative Euclidean algorithm.
; Args   : rdi = a,  rsi = b
; Returns: rax = GCD(a, b)
; Uses   : rax, rdx (both caller-saved — no push/pop needed)
; ──────────────────────────────────────────────────────────────────────────────
gcd:
    ; Iterative: while b != 0: (a, b) = (b, a mod b)
.loop:
    test    rsi, rsi            ; set flags on b (= rsi)
    jz      .done               ; if b == 0, a is the GCD
    mov     rax, rdi            ; rax = a  (dividend for idiv)
    cqo                         ; sign-extend rax into rdx:rax (required before idiv)
    idiv    rsi                 ; rdx:rax / rsi → quotient in rax, remainder in rdx
    ; After idiv: rax = a / b,  rdx = a mod b
    mov     rdi, rsi            ; a = old b
    mov     rsi, rdx            ; b = old a mod b
    jmp     .loop
.done:
    mov     rax, rdi            ; return value: a (the GCD)
    ret

; ── read_int ──────────────────────────────────────────────────────────────────
; Read one signed 64-bit integer into *rsi using scanf.
; Args: rdi = format string, rsi = destination pointer
; ──────────────────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout:
;   [rbp -  8]       = N (count of numbers)
;   [rbp - 8 - 8*i]  = numbers[i]  (N values, max 64 for 512 bytes of stack space)
;
; We reserve 8 + 64*8 = 520 → rounded up to 528 (multiple of 16).
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 528            ; 8 (N) + 64*8 (array) + 8 (pad) = 528, /16=33 ✓

    ; ── Ask how many numbers ──────────────────────────────────────────────────
    lea     rdi, [rel prompt_n]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 8]      ; &N
    call    read_int

    mov     r12, [rbp - 8]      ; r12 = N  (callee-saved: survives all calls below)

    ; ── Read N numbers into the stack array ───────────────────────────────────
    xor     r13, r13            ; r13 = i = 0  (loop index, callee-saved)

.read_loop:
    cmp     r13, r12            ; i < N ?
    jge     .read_done

    ; Print "Enter number i+1: "
    lea     rdi, [rel prompt_num]
    mov     rsi, r13            ; rsi = i (0-based, printed as-is; adjust to 1-based below)
    inc     rsi                 ; rsi = i + 1  (1-based display)
    xor     eax, eax
    call    printf

    ; Compute address of numbers[i] = rbp - 8 - 8 - 8*i = rbp - 16 - 8*i
    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 16]     ; base = &numbers[0]
    lea     rax, [r13 * 8]      ; rax = i * 8  (byte offset)
    add     rsi, rax            ; rsi = &numbers[i]  — wait, we want rbp-16 - 8*i

    ; numbers[i] is stored downward from rbp-16:
    ;   numbers[0] at rbp-16, numbers[1] at rbp-24, ...
    ; Address = rbp - 16 - i*8
    mov     rsi, rbp            ; rsi = rbp
    sub     rsi, 16             ; rsi = rbp - 16  (address of numbers[0])
    mov     rax, r13            ; rax = i
    imul    rax, 8              ; rax = i * 8
    sub     rsi, rax            ; rsi = rbp - 16 - i*8 = &numbers[i]

    call    read_int

    inc     r13                 ; i++
    jmp     .read_loop

.read_done:
    ; ── Fold GCD over the array ───────────────────────────────────────────────
    ; Start with numbers[0] as the running GCD
    mov     rdi, [rbp - 16]     ; rdi = numbers[0]

    mov     r13, 1              ; i = 1

.gcd_loop:
    cmp     r13, r12            ; i < N ?
    jge     .gcd_done

    ; Load numbers[i]
    mov     rax, r13            ; rax = i
    imul    rax, 8              ; rax = i * 8
    mov     r14, rbp            ; r14 = rbp
    sub     r14, 16             ; r14 = base of array
    sub     r14, rax            ; r14 = &numbers[i]
    mov     rsi, [r14]          ; rsi = numbers[i]

    call    gcd                 ; rax = GCD(running, numbers[i])
    mov     rdi, rax            ; running GCD = result

    inc     r13
    jmp     .gcd_loop

.gcd_done:
    ; ── Print result ──────────────────────────────────────────────────────────
    mov     r12, rdi            ; save final GCD (rdi may be clobbered by printf setup)
    lea     rdi, [rel fmt_out]
    mov     rsi, r12            ; rsi = HCF
    xor     eax, eax
    call    printf

    xor     eax, eax
    leave
    ret
