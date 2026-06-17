;═══════════════════════════════════════════════════════════════════════════════
; §14  Reverse Array
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 14_reverse_array.asm
;  Description : Two-pointer in-place reversal of int64 array
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 14_reverse_array.asm — Reverse an integer array in place (two-pointer method)
; Goal: indexing, memory reads and writes, pointer arithmetic
;
; Two-pointer reversal:
;   left  starts at index 0       (lowest address)
;   right starts at index n-1     (highest address)
;   While left < right:
;       swap arr[left] and arr[right]
;       left++, right--
;
; We store int64_t values (8 bytes each). The technique is the same for any
; element size — just adjust the load/store size and stride.
;
; Build:
;   nasm -f elf64 14_reverse_array.asm -o bin/14_reverse_array.o
;   ld bin/14_reverse_array.o -o bin/14_reverse_array
; Run:
;   ./bin/14_reverse_array
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    arr    dq 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
                            ; dq = "define quadword" = 8-byte integer per element
    arr_n  equ ($ - arr) / 8  ; count = total bytes / 8 bytes-per-element

    before_lbl  db "Before: ", 0
    after_lbl   db "After:  ", 0
    sep         db ", ", 0
    newline     db 10

section .bss
    num_buf  resb 22        ; scratch buffer for integer → decimal string conversion

section .text
global _start               ; expose _start to linker as entry point

; ───────────────────────────────────────────────────────────────────────────
; reverse_i64_array — reverse an int64_t array in place
;   Input:  rdi = pointer to array
;           rsi = number of elements (n)
;   Output: array reversed in place; no return value
;
;   Registers used (all callee-saved, so print calls won't disturb them):
;     r12 = pointer to left element  (start = arr[0])
;     r13 = pointer to right element (start = arr[n-1])
; ───────────────────────────────────────────────────────────────────────────
reverse_i64_array:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; If the array has 0 or 1 elements, there is nothing to reverse
    cmp  rsi, 1             ; compare count with 1
    jle  .done              ; if n <= 1, return immediately

    ; Set up two pointers
    mov  r12, rdi           ; r12 = &arr[0]   — left pointer points to first element
    lea  r13, [rdi + rsi*8 - 8]
                            ; r13 = &arr[n-1] — right pointer:
                            ;   base rdi, add (n-1)*8 = n*8 - 8 bytes
                            ;   lea doesn't access memory, just computes the address

.swap_loop:
    cmp  r12, r13           ; have the two pointers met or crossed?
    jge  .done              ; if left >= right, reversal is complete

    ; Swap *left and *right using a temporary register (rax)
    mov  rax, [r12]         ; rax = value at left pointer (load 8-byte int64)
    mov  rcx, [r13]         ; rcx = value at right pointer (load 8-byte int64)
    mov  [r12], rcx         ; store right value at left address (memory write)
    mov  [r13], rax         ; store left value at right address (memory write)

    add  r12, 8             ; left++  — move left pointer forward by 8 bytes (one int64)
    sub  r13, 8             ; right-- — move right pointer backward by 8 bytes (one int64)
    jmp  .swap_loop         ; check again and possibly swap the next pair

.done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_i64 — print a single signed 64-bit integer to stdout (no newline)
;   Input:  rdi = the integer to print
; ───────────────────────────────────────────────────────────────────────────
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — used as write pointer (callee-saved)
    push r12                ; save r12 — used for buffer start (callee-saved)
    push r13                ; save r13 — used for sign flag (callee-saved)

    ; Convert rdi to decimal string in num_buf
    mov  r12, num_buf       ; r12 = start of conversion buffer
    mov  rbx, num_buf       ; rbx = current write position
    mov  r13, 0             ; r13 = 0 → number is positive

    test rdi, rdi           ; is rdi negative? (checks sign flag)
    jns  .pos               ; jump if Not Signed (number >= 0)
    neg  rdi                ; flip to positive: rdi = -rdi
    mov  r13, 1             ; r13 = 1 → we need a '-' prefix

.pos:
    mov  rax, rdi           ; rax = positive magnitude of the number
    test rax, rax           ; is it zero?
    jnz  .digits            ; if not, extract digits

    mov  byte [rbx], '0'    ; write '0' character
    inc  rbx                ; advance write pointer
    jmp  .do_sign           ; jump to sign handling

.digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half (div uses rdx:rax as 128-bit dividend)
    mov  rcx, 10            ; rcx = 10 — decimal base
    div  rcx                ; rax = quotient, rdx = remainder (last digit, 0-9)
    add  dl, '0'            ; convert digit to ASCII character
    mov  [rbx], dl          ; store the character
    inc  rbx                ; advance write pointer
    test rax, rax           ; more digits to extract?
    jnz  .digits            ; yes — loop

.do_sign:
    test r13, r13           ; was the number negative?
    jz   .null_t            ; no sign needed
    mov  byte [rbx], '-'    ; write '-' character
    inc  rbx                ; advance write pointer

.null_t:
    mov  byte [rbx], 0      ; null-terminate the string

    ; Reverse the characters in the buffer
    lea  rdi, [rbx - 1]     ; rdi = pointer to last non-null character
    mov  rsi, r12           ; rsi = pointer to first character
.rev:
    cmp  rsi, rdi           ; are the pointers crossing?
    jge  .write             ; done reversing
    mov  al, [rsi]          ; al = left character
    mov  cl, [rdi]          ; cl = right character
    mov  [rsi], cl          ; swap: place right at left
    mov  [rdi], al          ; swap: place left at right
    inc  rsi                ; advance left pointer
    dec  rdi                ; advance right pointer
    jmp  .rev               ; keep going

.write:
    ; Write the decimal string to stdout
    mov  rsi, r12           ; rsi = pointer to start of string (syscall arg 2)
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r12           ; rdx = length = end - start (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall
    syscall                 ; write(1, string, length)

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; print_cstr — print null-terminated string to stdout
;   Input: rdi = pointer to string
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save the string pointer

    xor  rcx, rcx           ; rcx = 0 — length counter
.pc_len:
    cmp  byte [rdi + rcx], 0   ; hit null terminator?
    je   .pc_write             ; yes — print now
    inc  rcx                   ; no — count this byte
    jmp  .pc_len               ; continue scanning

.pc_write:
    pop  rsi                ; rsi = string pointer (restored from stack; syscall arg 2)
    mov  rdx, rcx           ; rdx = length (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; print_array — print all elements of int64 array separated by ", "
;   Input:  rdi = array pointer
;           rsi = element count
print_array:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — array pointer (callee-saved)
    push r15                ; save r15 — element count (callee-saved)
    push rbx                ; save rbx — loop index (callee-saved)

    mov  r14, rdi           ; r14 = array pointer
    mov  r15, rsi           ; r15 = element count
    xor  rbx, rbx           ; rbx = 0 — loop index

.pa_loop:
    cmp  rbx, r15           ; are we past the last element?
    jge  .pa_done           ; yes — we're done

    ; Print the element value
    mov  rdi, [r14 + rbx*8] ; rdi = arr[index] — load 8 bytes from array
    call print_i64          ; print the integer

    ; Print separator ", " unless this is the last element
    lea  rax, [rbx + 1]     ; rax = index + 1
    cmp  rax, r15           ; is (index+1) == count? (i.e., was this the last element?)
    je   .pa_no_sep         ; yes — skip the separator

    mov  rdi, sep           ; rdi = pointer to ", " separator string
    call print_cstr         ; print the separator

.pa_no_sep:
    inc  rbx                ; advance to next element
    jmp  .pa_loop           ; loop

.pa_done:
    ; Print newline
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rsi, newline       ; rsi = pointer to '\n'
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write newline

    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — program entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print the array before reversal
    mov  rdi, before_lbl    ; rdi = "Before: " string pointer
    call print_cstr         ; print the label

    mov  rdi, arr           ; rdi = pointer to array
    mov  rsi, arr_n         ; rsi = number of elements
    call print_array        ; print each element

    ; Reverse the array in place
    mov  rdi, arr           ; rdi = pointer to array
    mov  rsi, arr_n         ; rsi = number of elements
    call reverse_i64_array  ; reverse the array

    ; Print the array after reversal
    mov  rdi, after_lbl     ; rdi = "After:  " string pointer
    call print_cstr         ; print the label

    mov  rdi, arr           ; rdi = pointer to (now reversed) array
    mov  rsi, arr_n         ; rsi = number of elements
    call print_array        ; print the reversed array

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)
