;═══════════════════════════════════════════════════════════════════════════════
; §18  Reverse String
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 18_reverse_string.asm
;  Description : In-place string reversal; edge cases (empty, single char)
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 18_reverse_string.asm — Reverse a string in place, bytewise
; Goal: pointer arithmetic, memory reads/writes, syscalls for I/O
;
; We reverse the bytes of a string in-place using two pointers:
;   left  → first byte
;   right → last byte (one before the null terminator)
;   Swap bytes while left < right, then advance both pointers inward.
;
; This is a byte-level reverse, which works correctly for pure ASCII text.
; For multi-byte UTF-8 sequences a byte reversal would corrupt the encoding,
; but the problem statement says "handle UTF-8 bytes safely (bytewise)".
; So we reverse bytes only — correct for ASCII and safe (no buffer issues).
;
; Build:
;   nasm -f elf64 18_reverse_string.asm -o bin/18_reverse_string.o
;   ld bin/18_reverse_string.o -o bin/18_reverse_string
; Run:
;   ./bin/18_reverse_string
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    s1      db "Hello, World!", 0   ; test string 1 — null terminated
    s2      db "abcdefghij", 0      ; test string 2
    s3      db "A", 0               ; single character edge case
    s4      db "", 0                ; empty string edge case

    lbl_before  db "Before: ", 0
    lbl_after   db "After:  ", 0
    newline     db 10               ; ASCII 10 = '\n'
    separator   db "--------", 10, 0  ; visual divider

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; str_len — compute length of null-terminated string (no null counted)
;   Input:  rdi = pointer to string
;   Output: rax = length in bytes
; ───────────────────────────────────────────────────────────────────────────
str_len:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — index/counter starts at zero
.sl_loop:
    cmp  byte [rdi + rax], 0   ; is the byte at (rdi + rax) a null terminator?
    je   .sl_done              ; yes — string ends here
    inc  rax                   ; no  — advance the counter
    jmp  .sl_loop              ; check the next byte

.sl_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string length (bytes before null)

; ───────────────────────────────────────────────────────────────────────────
; str_reverse — reverse the bytes of a null-terminated string in place
;   Input:  rdi = pointer to null-terminated string
;   Output: string reversed in place (the null terminator stays at the end)
;
;   Algorithm (two-pointer swap):
;     left  = start of string
;     right = last non-null byte = start + length - 1
;     while left < right:
;         swap *left, *right
;         left++, right--
; ───────────────────────────────────────────────────────────────────────────
str_reverse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — left pointer (callee-saved)
    push r12                ; save r12 — right pointer (callee-saved)

    ; First compute the length of the string
    push rdi                ; save the string pointer (str_len will use rdi)
    call str_len            ; rax = length
    pop  rdi                ; restore the string pointer

    ; Edge case: empty string or single character — nothing to swap
    cmp  rax, 1             ; is length <= 1?
    jle  .sr_done           ; yes — return immediately (nothing to swap)

    ; Set up two pointers
    mov  rbx, rdi           ; rbx = left pointer = start of string
    lea  r12, [rdi + rax - 1]  ; r12 = right pointer = address of LAST character
                               ;   rdi + rax points one past the end (at the null)
                               ;   rdi + rax - 1 points to the last real character

.sr_swap:
    cmp  rbx, r12           ; have the two pointers met or crossed?
    jge  .sr_done           ; yes — all pairs have been swapped; done

    mov  al, [rbx]          ; al = byte at left pointer  (load 1 byte)
    mov  cl, [r12]          ; cl = byte at right pointer (load 1 byte)
    mov  [rbx], cl          ; store right byte at left address  (1-byte write)
    mov  [r12], al          ; store left byte at right address  (1-byte write)

    inc  rbx                ; advance left pointer rightward by one byte
    dec  r12                ; advance right pointer leftward by one byte
    jmp  .sr_swap           ; check again and possibly swap the next pair

.sr_done:
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_cstr — write null-terminated string to stdout
;   Input:  rdi = pointer to string
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer (will be clobbered by str_len)

    call str_len            ; rax = length
    mov  rdx, rax           ; rdx = length (write syscall arg 3)

    pop  rsi                ; rsi = string pointer (restored; write syscall arg 2)
    mov  rdi, 1             ; rdi = 1 — stdout (write syscall arg 1)
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; demo_reverse — print a string, reverse it, then print again
;   Input:  rdi = pointer to null-terminated string
; ───────────────────────────────────────────────────────────────────────────
demo_reverse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — the string pointer (callee-saved)

    mov  r14, rdi           ; r14 = the string pointer

    ; Print "Before: " label
    mov  rdi, lbl_before    ; rdi = pointer to "Before: "
    call print_cstr         ; print the label

    ; Print the original string
    mov  rdi, r14           ; rdi = string pointer
    call print_cstr         ; print the string

    ; Print newline
    mov  rdi, 1             ; rdi = stdout
    mov  rsi, newline       ; rsi = '\n' pointer
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write newline

    ; Reverse the string in place
    mov  rdi, r14           ; rdi = string pointer
    call str_reverse        ; reverse bytes between first and last character

    ; Print "After:  " label
    mov  rdi, lbl_after     ; rdi = pointer to "After:  "
    call print_cstr         ; print the label

    ; Print the reversed string
    mov  rdi, r14           ; rdi = string pointer (same memory, now reversed)
    call print_cstr         ; print it

    ; Print newline
    mov  rdi, 1             ; rdi = stdout
    mov  rsi, newline       ; rsi = '\n' pointer
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write newline

    ; Print separator
    mov  rdi, separator     ; rdi = pointer to "--------\n"
    call print_cstr         ; print it

    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: demonstrate str_reverse on several strings
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Demo 1: "Hello, World!"
    mov  rdi, s1            ; rdi = pointer to "Hello, World!"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 2: "abcdefghij"
    mov  rdi, s2            ; rdi = pointer to "abcdefghij"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 3: single character "A" (should be unchanged)
    mov  rdi, s3            ; rdi = pointer to "A"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 4: empty string (edge case — should be unchanged)
    mov  rdi, s4            ; rdi = pointer to "" (just a null byte)
    call demo_reverse       ; print before/after, reverse in place

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)
