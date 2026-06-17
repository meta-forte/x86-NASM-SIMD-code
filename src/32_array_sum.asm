;═══════════════════════════════════════════════════════════════════════════════
; §13  Array Sum
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 13_array_sum.asm
;  Description : 4× unrolled loop over int32 array; MOVSXD sign extension
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 13_array_sum.asm — Sum an int32_t array and return a 64-bit result
; Goal: pointer increments, loop unrolling, 64-bit arithmetic with 32-bit data
;
; Key concepts:
;   - Accessing array elements through a base pointer + offset
;   - Sign-extending 32-bit values to 64-bit before accumulating (MOVSXD)
;   - Loop unrolling: process 4 elements per iteration to reduce branch overhead
;   - Handling the "tail" (remaining elements when count isn't divisible by 4)
;
; The array is defined in .data for demonstration. In real use the array would
; be passed from C (pointer in rdi, count in rsi).
;
; Build:
;   nasm -f elf64 13_array_sum.asm -o bin/13_array_sum.o
;   ld bin/13_array_sum.o -o bin/13_array_sum
; Run:
;   ./bin/13_array_sum
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test array of int32_t values
    ; Mix of positive and negative to test sign extension
    arr   dd 10, -3, 7, 25, -8, 100, 42, -15, 0, 99
    arr_n equ ($ - arr) / 4   ; number of elements: (bytes used) / (bytes per int32)
                               ; $ is current address; subtracting arr gives byte count

    ; Expected sum: 10-3+7+25-8+100+42-15+0+99 = 257
    result_lbl  db "Sum = ", 0     ; label to print before the result
    newline     db 10              ; ASCII 10 = newline character '\n'

section .bss
    num_buf  resb 22        ; buffer for number→string conversion (max 20 digits + null)

section .text
global _start               ; program entry point exposed to the linker

; ───────────────────────────────────────────────────────────────────────────
; array_sum_i32 — sum an array of int32_t, return int64_t
;   Input:  rdi = pointer to int32_t array
;           rsi = number of elements (count)
;   Output: rax = sum as a signed 64-bit integer
;
;   We process 4 elements per loop iteration (unrolling by 4) to reduce the
;   number of branch/compare instructions relative to useful work.
; ───────────────────────────────────────────────────────────────────────────
array_sum_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer

    xor  rax, rax           ; rax = 0 — accumulator starts at zero
    test rsi, rsi           ; is count zero? (AND rsi with itself, sets ZF if zero)
    jz   .done              ; if count == 0, return 0 immediately

    ; Set up loop bounds
    mov  rcx, rsi           ; rcx = total number of elements
    xor  rdx, rdx           ; rdx = 0 — index into the array (byte offset = rdx * 4)

    ; Compute how many full groups of 4 we can process
    mov  r8, rcx            ; r8 = total count
    shr  r8, 2              ; r8 = count / 4 — number of 4-element groups (right-shift by 2)
    test r8, r8             ; are there any complete groups of 4?
    jz   .tail              ; if not, go straight to the scalar tail

.unroll_loop:
    ; Load and accumulate 4 int32_t values per iteration
    ; Each int32_t is 4 bytes, so element[i] is at address rdi + i*4

    movsxd r9,  dword [rdi + rdx*4 + 0]   ; sign-extend arr[rdx+0] from 32→64 bits into r9
    add    rax, r9                          ; rax += arr[rdx+0]

    movsxd r9,  dword [rdi + rdx*4 + 4]   ; sign-extend arr[rdx+1] (offset 4 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+1]

    movsxd r9,  dword [rdi + rdx*4 + 8]   ; sign-extend arr[rdx+2] (offset 8 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+2]

    movsxd r9,  dword [rdi + rdx*4 + 12]  ; sign-extend arr[rdx+3] (offset 12 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+3]

    add    rdx, 4           ; advance index by 4 elements
    dec    r8               ; decrement group counter
    jnz    .unroll_loop     ; if groups remain, iterate

.tail:
    ; Handle remaining elements (count % 4 of them)
    ; rcx still holds total count; rdx holds number of elements processed so far
    ; remaining = rcx - rdx
.tail_loop:
    cmp  rdx, rcx           ; have we processed all elements?
    jge  .done              ; if index >= count, we are done

    movsxd r9, dword [rdi + rdx*4]   ; sign-extend the next remaining element
    add    rax, r9                    ; rax += element
    inc    rdx                        ; advance to next element
    jmp    .tail_loop                 ; check again

.done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax holds the 64-bit sum

; ───────────────────────────────────────────────────────────────────────────
; Helper functions for printing
; ───────────────────────────────────────────────────────────────────────────

; i64_to_dec — convert signed 64-bit integer to decimal string
;   Input:  rdi = signed 64-bit integer
;           rsi = pointer to output buffer (>= 22 bytes for sign + 20 digits + null)
;   Output: rax = pointer to start of string, rdx = length
i64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rbx                ; save rbx (callee-saved — we use it as write pointer)
    push r12                ; save r12 (callee-saved — we use it for buffer start)
    push r13                ; save r13 (callee-saved — we use it to remember sign)

    mov  r12, rsi           ; r12 = fixed buffer start address
    mov  rbx, rsi           ; rbx = current write pointer
    mov  r13, 0             ; r13 = 0 means positive (no minus sign needed)

    ; Check for negative
    test rdi, rdi           ; is the number negative? (test checks the sign bit via SF)
    jns  .positive          ; jump if Not Signed (i.e., number >= 0)
    neg  rdi                ; rdi = -rdi (make it positive for digit extraction)
    mov  r13, 1             ; r13 = 1 means we need to prepend a '-' sign

.positive:
    mov  rax, rdi           ; rax = the (now positive) number
    test rax, rax           ; is it zero?
    jnz  .digits            ; if not zero, extract digits

    mov  byte [rbx], '0'    ; write '0' for the zero case
    inc  rbx                ; advance write pointer
    jmp  .sign              ; handle sign (will be no-op since r13 == 0)

.digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half of dividend before DIV
    mov  rcx, 10            ; rcx = 10 — divisor for decimal extraction
    div  rcx                ; rax = rax / 10 (quotient), rdx = rax % 10 (last digit)
    add  dl, '0'            ; convert remainder 0-9 to ASCII '0'-'9'
    mov  [rbx], dl          ; store ASCII digit in buffer
    inc  rbx                ; advance write pointer
    test rax, rax           ; is quotient zero? (all digits extracted?)
    jnz  .digits            ; no — keep extracting

.sign:
    ; Prepend '-' if the original number was negative
    test r13, r13           ; was the sign flag set?
    jz   .null_term         ; no — skip minus sign
    mov  byte [rbx], '-'    ; write '-' character
    inc  rbx                ; advance write pointer

.null_term:
    mov  byte [rbx], 0      ; null-terminate the string

    ; Compute length before reversing
    mov  rdx, rbx           ; rdx = pointer to one past last char
    sub  rdx, r12           ; rdx = length = end - start

    ; Reverse the characters (digits are backwards from extraction)
    lea  rdi, [rbx - 1]     ; rdi = pointer to last non-null char
    mov  rsi, r12           ; rsi = pointer to first char

.rev:
    cmp  rsi, rdi           ; have the two pointers crossed?
    jge  .rev_done          ; yes — done reversing
    mov  al, [rsi]          ; al = character at left pointer
    mov  cl, [rdi]          ; cl = character at right pointer
    mov  [rsi], cl          ; place right char at left position
    mov  [rdi], al          ; place left char at right position
    inc  rsi                ; move left pointer rightward
    dec  rdi                ; move right pointer leftward
    jmp  .rev               ; check again

.rev_done:
    mov  rax, r12           ; rax = pointer to the correctly ordered string

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string pointer, rdx = length

; print_cstr — print null-terminated string to stdout
;   Input: rdi = pointer to string
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rdi                ; save string pointer (will be clobbered)

    ; Compute length
    xor  rcx, rcx           ; rcx = 0 — byte counter
.cs_len:
    cmp  byte [rdi + rcx], 0  ; is current byte null?
    je   .cs_print            ; yes — stop counting
    inc  rcx                  ; no — count it
    jmp  .cs_len              ; continue

.cs_print:
    pop  rsi                ; rsi = string pointer (syscall arg 2)
    mov  rdx, rcx           ; rdx = length (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall number
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Call array_sum_i32 with our test array
    mov  rdi, arr           ; rdi = pointer to array (argument 1)
    mov  rsi, arr_n         ; rsi = number of elements (argument 2)
    call array_sum_i32      ; rax = 64-bit sum

    ; Save the result — rax will be clobbered by print calls
    push rax                ; push sum onto stack to save it

    ; Print the label "Sum = "
    mov  rdi, result_lbl    ; rdi = pointer to "Sum = " string
    call print_cstr         ; print the label

    ; Convert and print the sum
    pop  rdi                ; rdi = the sum we saved
    mov  rsi, num_buf       ; rsi = pointer to conversion buffer
    call i64_to_dec         ; rax = string pointer, rdx = length

    ; Write the decimal string
    mov  rsi, rax           ; rsi = string pointer
    ; rdx already holds length from i64_to_dec
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write(1, number_string, length)

    ; Write newline
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rsi, newline       ; rsi = pointer to newline byte
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write(1, "\n", 1)

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)
