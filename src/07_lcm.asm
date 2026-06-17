; =============================================================================
; lcm.asm — Least Common Multiple of N numbers
;
; Description:
;   Asks the user how many numbers to enter, reads them, then computes
;   the LCM of all of them.
;
;   Key identity:
;       LCM(a, b) = |a * b| / GCD(a, b)
;   Folded:  LCM = LCM(LCM(a1, a2), a3) ...
;
;   To avoid overflow in a * b, we compute: (a / GCD(a,b)) * b
;   This keeps intermediate values smaller.
;
; Concepts:
;   • LCM via GCD: avoids computing a*b by dividing first
;   • Euclidean GCD reused from hcf pattern (idiv / cqo)
;   • Stack array for inputs (no .bss)
;
; Build:
;   nasm -f elf64 lcm.asm -o obj/lcm.o
;   gcc   obj/lcm.o -o bin/lcm -no-pie
;
; Run:
;   ./bin/lcm
; =============================================================================

global main
extern printf, scanf

section .data

    prompt_n    db "How many numbers? ", 0
    prompt_num  db "Enter number %ld: ", 0
    fmt_in      db "%ld", 0
    fmt_out     db "LCM = %ld", 10, 0

section .text

; ── gcd ───────────────────────────────────────────────────────────────────────
; Iterative Euclidean GCD.
; Args   : rdi = a,  rsi = b  (both positive)
; Returns: rax = GCD(a, b)
; ──────────────────────────────────────────────────────────────────────────────
gcd:
.loop:
    test    rsi, rsi
    jz      .done
    mov     rax, rdi
    cqo                         ; sign-extend rax → rdx:rax for idiv
    idiv    rsi                 ; rax = a/b, rdx = a mod b
    mov     rdi, rsi            ; a = b
    mov     rsi, rdx            ; b = a mod b
    jmp     .loop
.done:
    mov     rax, rdi
    ret

; ── lcm_pair ──────────────────────────────────────────────────────────────────
; Compute LCM(a, b) = (a / GCD(a,b)) * b
; Args   : rdi = a,  rsi = b
; Returns: rax = LCM(a, b)
; Uses callee-saved r12/r13 to preserve a and b across the gcd call.
; ──────────────────────────────────────────────────────────────────────────────
lcm_pair:
    push    rbp
    mov     rbp, rsp
    push    r12                 ; save r12 — we will use it for 'a'
    push    r13                 ; save r13 — we will use it for 'b'
    ; (ret 8)+(rbp 8)+(r12 8)+(r13 8) = 32. 32/16=2. ✓

    mov     r12, rdi            ; r12 = a
    mov     r13, rsi            ; r13 = b

    call    gcd                 ; rax = GCD(a, b)
    mov     rcx, rax            ; rcx = GCD — save before we clobber rax below

    ; Compute LCM = (a / GCD) * b  — divide first to keep values smaller
    mov     rax, r12            ; rax = a  (dividend)
    cqo                         ; sign-extend rax into rdx:rax for idiv
    idiv    rcx                 ; rax = a / GCD  (exact division, no remainder)
    imul    rax, r13            ; rax = (a / GCD) * b = LCM(a, b)

    pop     r13
    pop     r12
    pop     rbp
    ret

; ── read_int ──────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout:
;   [rbp -  8]               = N
;   [rbp - 16 - i*8]         = numbers[i]  (up to 64 entries)
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 528            ; N(8) + array(64*8=512) + pad(8) = 528 ✓

    ; ── Prompt and read N ─────────────────────────────────────────────────────
    lea     rdi, [rel prompt_n]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 8]
    call    read_int

    mov     r12, [rbp - 8]      ; r12 = N

    ; ── Read N numbers ────────────────────────────────────────────────────────
    xor     r13, r13            ; i = 0

.read_loop:
    cmp     r13, r12
    jge     .read_done

    lea     rdi, [rel prompt_num]
    mov     rsi, r13
    inc     rsi                 ; display 1-based index
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    mov     rsi, rbp
    sub     rsi, 16             ; base of numbers[]
    mov     rax, r13
    imul    rax, 8
    sub     rsi, rax            ; &numbers[i]
    call    read_int

    inc     r13
    jmp     .read_loop

.read_done:
    ; ── Fold LCM over the array ───────────────────────────────────────────────
    mov     r12, [rbp - 16]     ; running LCM = numbers[0]
    mov     r13, 1              ; i = 1

.lcm_loop:
    cmp     r13, [rbp - 8]      ; i < N?
    jge     .lcm_done

    mov     rdi, r12            ; rdi = running LCM
    mov     rax, r13
    imul    rax, 8
    mov     r14, rbp
    sub     r14, 16
    sub     r14, rax            ; r14 = &numbers[i]
    mov     rsi, [r14]          ; rsi = numbers[i]

    call    lcm_pair            ; rax = LCM(running, numbers[i])
    mov     r12, rax            ; update running LCM

    inc     r13
    jmp     .lcm_loop

.lcm_done:
    ; ── Print result ──────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_out]
    mov     rsi, r12
    xor     eax, eax
    call    printf

    xor     eax, eax
    leave
    ret
