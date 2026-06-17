;═══════════════════════════════════════════════════════════════════════════════
; §15  Min / Max
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 15_minmax.asm
;  Description : Branchless CMOVG / CMOVL conditional-move idiom
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 15_minmax.asm — Find maximum and minimum values and their indices in one pass
; Goal: comparisons, conditional moves (CMOV), single-pass algorithms
;
; We scan the array exactly once, keeping running max and min with their indices.
; CMOV (conditional move) lets us avoid branches for the hot comparison path —
; it executes in constant time with no branch-prediction penalty.
;
; CMOV variants used:
;   CMOVG  reg, reg/mem   — Move if Greater (signed)
;   CMOVL  reg, reg/mem   — Move if Less    (signed)
;
; Build:
;   nasm -f elf64 15_minmax.asm -o bin/15_minmax.o
;   ld bin/15_minmax.o -o bin/15_minmax
; Run:
;   ./bin/15_minmax
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    arr    dq -5, 42, 17, -100, 8, 99, 0, -3, 77, 33
    arr_n  equ ($ - arr) / 8

    max_lbl   db "Max value = ", 0
    min_lbl   db "Min value = ", 0
    idx_lbl   db "  at index ", 0
    newline   db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; find_max — find the maximum value and its index (signed int64)
;   Input:  rdi = pointer to int64_t array
;           rsi = count (must be >= 1)
;   Output: rax = maximum value
;           rdx = index of maximum value (0-based)
; ───────────────────────────────────────────────────────────────────────────
find_max:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, [rdi]         ; rax = arr[0] — assume the first element is the initial max
    xor  rdx, rdx           ; rdx = 0 — index of the current max (starts at 0)
    mov  rcx, 1             ; rcx = 1 — loop index (we already "processed" element 0)

.scan:
    cmp  rcx, rsi           ; have we visited all elements?
    jge  .found             ; if index >= count, we are done

    mov  r8, [rdi + rcx*8]  ; r8 = arr[rcx] — load next element (8 bytes each)
    cmp  r8, rax            ; compare candidate with current max
    cmovg rax, r8           ; if arr[rcx] > current_max: rax = arr[rcx]  (CMOV: no branch)
    cmovg rdx, rcx          ; if arr[rcx] > current_max: rdx = rcx       (update index)
    inc  rcx                ; advance to next element
    jmp  .scan              ; loop

.found:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = max value, rdx = max index

; ───────────────────────────────────────────────────────────────────────────
; find_min — find the minimum value and its index (signed int64)
;   Input:  rdi = pointer to int64_t array
;           rsi = count (must be >= 1)
;   Output: rax = minimum value
;           rdx = index of minimum value (0-based)
; ───────────────────────────────────────────────────────────────────────────
find_min:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, [rdi]         ; rax = arr[0] — assume the first element is the initial min
    xor  rdx, rdx           ; rdx = 0 — index of the current min (starts at 0)
    mov  rcx, 1             ; rcx = 1 — loop index (element 0 already "processed")

.scan:
    cmp  rcx, rsi           ; have we visited all elements?
    jge  .found             ; if index >= count, done

    mov  r8, [rdi + rcx*8]  ; r8 = arr[rcx] — load next element
    cmp  r8, rax            ; compare candidate with current min
    cmovl rax, r8           ; if arr[rcx] < current_min: rax = arr[rcx]  (CMOV: no branch)
    cmovl rdx, rcx          ; if arr[rcx] < current_min: rdx = rcx
    inc  rcx                ; advance to next element
    jmp  .scan              ; loop

.found:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = min value, rdx = min index

; ───────────────────────────────────────────────────────────────────────────
; Helper: print_i64 — print signed 64-bit integer (no newline)
;   Input: rdi = number
; ───────────────────────────────────────────────────────────────────────────
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)
    push r13                ; save r13 — sign flag (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = current write position
    xor  r13, r13           ; r13 = 0 — assume positive

    test rdi, rdi           ; is rdi negative?
    jns  .pi_pos            ; no — skip negation
    neg  rdi                ; make positive
    mov  r13, 1             ; set sign flag

.pi_pos:
    mov  rax, rdi           ; rax = magnitude
    test rax, rax           ; zero?
    jnz  .pi_digits         ; no — extract digits

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .pi_sign           ; handle sign

.pi_digits:
    xor  rdx, rdx           ; rdx = 0 — high half of dividend
    mov  rcx, 10            ; rcx = divisor
    div  rcx                ; rax = quotient, rdx = remainder (0-9)
    add  dl, '0'            ; convert to ASCII
    mov  [rbx], dl          ; store digit
    inc  rbx                ; advance write pointer
    test rax, rax           ; quotient zero?
    jnz  .pi_digits         ; no — more digits

.pi_sign:
    test r13, r13           ; was negative?
    jz   .pi_rev            ; no sign needed
    mov  byte [rbx], '-'    ; write minus
    inc  rbx                ; advance

.pi_rev:
    mov  byte [rbx], 0      ; null-terminate

    lea  rdi, [rbx - 1]     ; rdi = last char
    mov  rsi, r12           ; rsi = first char
.pi_rl:
    cmp  rsi, rdi           ; pointers crossed?
    jge  .pi_wr             ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance left
    dec  rdi                ; advance right
    jmp  .pi_rl             ; loop

.pi_wr:
    mov  rsi, r12           ; rsi = string start
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r12           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write string

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length
.pcs:
    cmp  byte [rdi + rcx], 0  ; null byte?
    je   .pcs_w               ; yes
    inc  rcx                  ; no
    jmp  .pcs                 ; loop

.pcs_w:
    pop  rsi                ; rsi = string pointer
    mov  rdx, rcx           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write(1, str, len)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: find and print max and min with their indices
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Find and print maximum ──
    mov  rdi, arr           ; rdi = array pointer
    mov  rsi, arr_n         ; rsi = element count
    call find_max           ; rax = max value, rdx = max index
    push rdx                ; save max index (rdx will be clobbered by print calls)
    push rax                ; save max value

    mov  rdi, max_lbl       ; rdi = "Max value = " string
    call print_cstr         ; print label

    pop  rdi                ; rdi = max value
    push rdi                ; save again (print_i64 doesn't clobber it, but be safe)
    call print_i64          ; print the value

    mov  rdi, idx_lbl       ; rdi = "  at index "
    call print_cstr         ; print

    pop  rax                ; discard (was rdi / max value already printed)
    pop  rdi                ; rdi = max index (restored from stack)
    call print_i64          ; print the index

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write syscall
    syscall                 ; newline

    ; ── Find and print minimum ──
    mov  rdi, arr           ; rdi = array pointer
    mov  rsi, arr_n         ; rsi = element count
    call find_min           ; rax = min value, rdx = min index
    push rdx                ; save min index
    push rax                ; save min value

    mov  rdi, min_lbl       ; rdi = "Min value = "
    call print_cstr         ; print label

    pop  rdi                ; rdi = min value
    push rdi                ; save again
    call print_i64          ; print the value

    mov  rdi, idx_lbl       ; rdi = "  at index "
    call print_cstr         ; print

    pop  rax                ; discard saved value
    pop  rdi                ; rdi = min index
    call print_i64          ; print the index

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write syscall
    syscall                 ; newline

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall
    xor  rdi, rdi           ; rdi = 0 — exit code 0
    syscall                 ; exit(0)
