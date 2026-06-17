;═══════════════════════════════════════════════════════════════════════════════
; §03  Fibonacci
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 03_fibonacci.asm
;  Description : Iterative F(1)..F(93) — loops, u64_to_dec, 64-bit arithmetic
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 03_fibonacci.asm — Produce the Fibonacci sequence, terms 1 through 93
; Goal: learn iterative loops and 64-bit arithmetic
;
; Fibonacci definition:
;   F(1) = 1
;   F(2) = 1
;   F(n) = F(n-1) + F(n-2)  for n >= 3
;
; Why stop at 93?
;   F(93)  = 12,200,160,415,121,876,738  — fits in an unsigned 64-bit int (max ~1.8e19)
;   F(94)  = 19,740,274,219,868,223,167  — still fits
;   F(95) would overflow 64 bits, so we print up to F(93) for safety.
;
; What we print (one line per term):
;   1
;   1
;   2
;   3
;   5
;   ...
;
; Build:
;   nasm -f elf64 03_fibonacci.asm -o bin/03_fibonacci.o
;   ld bin/03_fibonacci.o -o bin/03_fibonacci
; Run:
;   ./bin/03_fibonacci
; ═══════════════════════════════════════════════════════════════════════════════

section .bss
    ; Buffer for converting a number to decimal string.
    ; A uint64 has at most 20 decimal digits, +1 for null terminator.
    num_buf  resb 22        ; reserve 22 bytes of uninitialised storage

section .data
    newline  db 10          ; ASCII 10 = '\n'

section .text
global _start               ; expose _start to the linker (program entry point)

; ───────────────────────────────────────────────────────────────────────────
; u64_to_dec — convert unsigned 64-bit integer to a decimal ASCII string
;   Input:  rdi = the number
;           rsi = pointer to output buffer (at least 21 bytes)
;   Output: rax = pointer to first character of string in the buffer
;           rdx = length of the string (number of characters, no null)
;
;   Method: divide by 10 repeatedly; each remainder is a digit (0-9).
;   Digits come out least-significant first so we reverse at the end.
; ───────────────────────────────────────────────────────────────────────────
u64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved: must not change)
    mov  rbp, rsp           ; set our own frame pointer to track this function's locals
    push rbx                ; save rbx — we use it as write pointer (callee-saved)
    push r12                ; save r12 — we use it to remember the buffer start (callee-saved)

    mov  rax, rdi           ; rax = the number (dividend — 'div' instruction uses rax)
    mov  rbx, rsi           ; rbx = current write pointer into the buffer
    mov  r12, rsi           ; r12 = fixed start of the buffer (for reversal later)

    ; Special case: number == 0
    test rax, rax           ; bitwise AND of rax with itself; sets ZF if rax == 0
    jnz  .extract_digits    ; if not zero, go extract digits normally

    mov  byte [rbx], '0'    ; write the character '0' into the buffer
    inc  rbx                ; advance write pointer by 1 byte
    jmp  .null_term         ; skip the loop

.extract_digits:
    ; Loop: extract each decimal digit as a remainder from dividing by 10
    xor  rdx, rdx           ; rdx = 0 — 'div' uses rdx:rax as the 128-bit dividend; clear high half
    mov  rcx, 10            ; rcx = 10 — divisor
    div  rcx                ; unsigned divide: rax = rax/10 (quotient), rdx = rax%10 (remainder)
    add  dl, '0'            ; dl = (digit 0-9) + 48 = ASCII character '0' to '9'
    mov  [rbx], dl          ; store this digit character in the buffer
    inc  rbx                ; move write pointer to the next byte
    test rax, rax           ; is the quotient now zero? (all digits extracted?)
    jnz  .extract_digits    ; no — loop again for the next digit

.null_term:
    mov  byte [rbx], 0      ; write a null terminator at the end

    ; Compute the string length before we reverse
    mov  rdx, rbx           ; rdx = pointer to just past the last digit
    sub  rdx, r12           ; rdx = length = (end pointer) - (start pointer)

    ; Now reverse the buffer [r12 .. rbx-1] because digits are backwards
    lea  rdi, [rbx - 1]     ; rdi = pointer to the LAST written digit (right end)
    mov  rsi, r12           ; rsi = pointer to the FIRST written digit (left end)
.reverse:
    cmp  rsi, rdi           ; have the two ends met or crossed?
    jge  .rev_done          ; yes — reversal is complete
    mov  al,  [rsi]         ; al = character at left pointer
    mov  cl,  [rdi]         ; cl = character at right pointer
    mov  [rsi], cl          ; swap: write right char to left position
    mov  [rdi], al          ; swap: write left char to right position
    inc  rsi                ; left pointer moves right
    dec  rdi                ; right pointer moves left
    jmp  .reverse           ; check again

.rev_done:
    mov  rax, r12           ; rax = pointer to start of (now correctly ordered) string

    pop  r12                ; restore r12 (callee-saved: must restore before returning)
    pop  rbx                ; restore rbx (callee-saved: must restore before returning)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string start, rdx = length

; ───────────────────────────────────────────────────────────────────────────
; print_u64 — print an unsigned 64-bit integer followed by a newline
;   Input:  rdi = the number to print
;   Clobbers: rax, rdx, rsi (syscall registers — caller must save if needed)
; ───────────────────────────────────────────────────────────────────────────
print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rdi                ; push the number — rdi will be overwritten by u64_to_dec return

    ; Convert the number to a decimal string in num_buf
    ; rdi still holds the number from the push above — restore first
    pop  rdi                ; restore the number into rdi
    mov  rsi, num_buf       ; rsi = pointer to our conversion buffer
    call u64_to_dec         ; rax = string pointer, rdx = string length

    ; Write the decimal string to stdout
    mov  rsi, rax           ; rsi = string pointer (syscall arg 2)
    mov  rdx, rdx           ; rdx = string length (syscall arg 3) — already in rdx from u64_to_dec
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor (syscall arg 1)
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; kernel: write(stdout, string, length)

    ; Write the newline
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor
    mov  rsi, newline       ; rsi = pointer to our '\n' byte
    mov  rdx, 1             ; rdx = 1 byte to write
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; kernel: write(stdout, "\n", 1)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; _start — program entry point
;   Iteratively computes and prints Fibonacci numbers F(1) through F(93)
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; We track the sequence using two registers.
    ; r13 = "previous" term (starts as 0, a virtual F(0) to kick off the recurrence)
    ; r14 = "current"  term (starts as 1, which is F(1))
    ; r15 = loop counter from 1 to 93
    ;
    ; We use r13-r15 because they are callee-saved; calling print_u64 will NOT clobber them.

    mov  r13, 0             ; r13 = previous = 0 (F(0), not printed — just a seed)
    mov  r14, 1             ; r14 = current  = 1 (F(1) — first term to print)
    mov  r15, 1             ; r15 = term index, starts at 1

.loop:
    cmp  r15, 93            ; have we printed all 93 terms?
    jg   .finish            ; if r15 > 93, we are done

    ; Print the current Fibonacci number
    mov  rdi, r14           ; rdi = current term (F(r15)) — argument to print_u64
    call print_u64          ; print the number, followed by a newline

    ; Advance the sequence: next = current + previous
    mov  rax, r14           ; rax = F(n) — save the current value before overwriting r14
    add  r14, r13           ; r14 = F(n) + F(n-1) = F(n+1) — update current to next term
    mov  r13, rax           ; r13 = old F(n) = new F(n-1) — update previous

    inc  r15                ; term_index++ — move to the next term
    jmp  .loop              ; go back and print the next term

.finish:
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success (XOR with self clears to zero)
    syscall                 ; kernel: exit(0) — terminate the process
