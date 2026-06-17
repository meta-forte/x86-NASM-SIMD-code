; =================================================================
; selection_sort.asm — Selection Sort Demo
;
; BUILD:
;   nasm -f elf64 selection_sort.asm -o selection_sort.o
;   gcc  selection_sort.o -o selection_sort -no-pie
; RUN:
;   ./selection_sort
; =================================================================

global main
extern printf, scanf

section .data

    ; ---- Selection Sort ----
    hdr_ss    db "=== SELECTION SORT ===", 10, 0
    ss_before db "Before: ", 0
    ss_after  db "After:  ", 0

    ss_arr    dq 64, 25, 12, 22, 11
    ; Five 64-bit integers for the selection sort demo.

    SS_LEN    equ 5

    ; ---- Shared format strings ----
    fmt_ld    db "%ld ", 0
    ; '%ld' prints a 64-bit signed integer (long). The trailing space
    ; separates elements. In C: printf("%ld ", value);

    newline   db 10, 0
    ; Just a newline character then null terminator.
    ; Used to end a printed line of array elements.

section .text

; -----------------------------------------------------------------
; SUBROUTINE: print_array_long
;
; WHAT IT DOES:
;   Loops through a 64-bit integer array and prints every element
;   with a trailing space. Prints a newline at the end.
;
; IN C:
;   void print_array_long(long long *arr, long n) {
;       for (long i = 0; i < n; i++) printf("%ld ", arr[i]);
;       printf("\n");
;   }
;
; ARGUMENTS:   rdi = array pointer,  rsi = element count n
; REGISTERS:   rbx = i (loop index), r12 = arr, r13 = n
; WHY rbx/r12/r13: printf may overwrite rdi/rsi (caller-saved).
;   We store our values in callee-saved registers that printf must
;   leave unchanged.
; -----------------------------------------------------------------
print_array_long:

    push    rbp             ; save caller's frame marker onto stack
    mov     rbp, rsp        ; set rbp = rsp to mark our frame's start
    push    rbx             ; save rbx — we will use it as loop index i
    push    r12             ; save r12 — we will use it as array pointer
    push    r13             ; save r13 — we will use it as element count n
    sub     rsp, 8          ; 8-byte padding: (ret_addr 8)+(rbp 8)+(rbx 8)+(r12 8)+(r13 8)+8 = 48 bytes. 48/16=3. Aligned.

    mov     r12, rdi        ; r12 = arr  (copy out of rdi before printf clobbers it)
    mov     r13, rsi        ; r13 = n    (copy out of rsi before printf clobbers it)
    xor     rbx, rbx        ; rbx = 0   ('xor reg,reg' is the fast way to zero a register)

.loop:
    cmp     rbx, r13        ; subtract r13 from rbx, set CPU flags, discard result
    jge     .newline        ; if i >= n, all elements printed — jump to newline

    mov     rsi, [r12 + rbx*8]
    ; rsi = arr[i].
    ; r12 = base address of the array.
    ; rbx*8 = i * 8 bytes (each element is a long long = 8 bytes).
    ; [r12 + rbx*8] = read 8 bytes starting at address (r12 + i*8).
    ; rsi is the 2nd argument to printf (the value to print).

    lea     rdi, [rel fmt_ld]
    ; rdi = address of the format string "%ld ".
    ; 'lea [rel ...]' computes the address relative to the instruction pointer.
    ; rdi is the 1st argument to printf.

    xor     eax, eax        ; eax = 0: we pass zero floating-point args (required for variadic calls)
    call    printf          ; printf("%ld ", arr[i]) — prints the number and a space
    ; After printf: rbx, r12, r13 are unchanged (printf must restore callee-saved regs).
    ; rdi, rsi, rax and other caller-saved registers may now hold garbage.

    inc     rbx             ; rbx = rbx + 1 — move to the next element (i++)
    jmp     .loop           ; go back to the top of the loop

.newline:
    lea     rdi, [rel newline]  ; rdi = address of "\n\0"
    xor     eax, eax            ; 0 float args
    call    printf              ; print a newline character to end the output line

    add     rsp, 8          ; remove the 8-byte padding we added in the prologue
    pop     r13             ; restore r13 — MUST pop in REVERSE order of push (LIFO)
    pop     r12             ; restore r12
    pop     rbx             ; restore rbx
    pop     rbp             ; restore caller's frame marker
    ret                     ; pop return address off stack and jump back to caller


; SUBROUTINE: selection_sort
;
; WHAT IT DOES:
;   Sorts a 64-bit integer array ascending using selection sort.
;   For each position i from left to right, find the MINIMUM element
;   in the unsorted portion (positions i..n-1), then swap it into
;   position i. After each outer step, the sorted left side grows.
;
; IN C:
;   void selection_sort(long long *arr, long n) {
;       for (long i = 0; i < n-1; i++) {
;           long min_idx = i;
;           for (long j = i+1; j < n; j++)
;               if (arr[j] < arr[min_idx]) min_idx = j;
;           if (min_idx != i) {
;               long tmp = arr[i]; arr[i] = arr[min_idx]; arr[min_idx] = tmp;
;           }
;       }
;   }
;
; ARGUMENTS:   rdi = array pointer,  rsi = length n
; REGISTERS:   r12=arr, r13=n, r14=i, r15=min_idx, rbx=j,
;              rax=arr[j], rdx=arr[min_idx]
; -----------------------------------------------------------------
selection_sort:

    push    rbx             ; save rbx — inner scan index j
    push    r12             ; save r12 — array base pointer
    push    r13             ; save r13 — array length n
    push    r14             ; save r14 — outer position i
    push    r15             ; save r15 — min_idx (index of smallest seen so far)

    mov     r12, rdi        ; r12 = arr
    mov     r13, rsi        ; r13 = n
    xor     r14, r14        ; r14 = 0  (i = 0)

.ss_outer:
    mov     rax, r13        ; rax = n
    dec     rax             ; rax = n - 1
    cmp     r14, rax        ; compare i with n-1
    jge     .ss_done        ; if i >= n-1, stop (last element is already placed)
    ; We stop at n-1 because when i = n-2, the last two elements are sorted together.

    mov     r15, r14        ; min_idx = i  (assume position i currently holds the minimum)

    lea     rbx, [r14 + 1]  ; j = i + 1  (start scanning the element AFTER position i)
    ; 'lea rbx, [r14+1]' is arithmetic: rbx = r14 + 1. No memory is read.

.ss_inner:
    cmp     rbx, r13        ; compare j with n
    jge     .do_swap        ; if j >= n, scan is complete — proceed to swap

    mov     rax, [r12 + rbx*8]    ; rax = arr[j]       (element being examined)
    mov     rdx, [r12 + r15*8]   ; rdx = arr[min_idx]  (current minimum value)

    cmp     rax, rdx        ; compare arr[j] with arr[min_idx]
    jge     .no_update      ; if arr[j] >= min, not smaller — keep current min_idx

    mov     r15, rbx        ; min_idx = j  (found a new minimum at position j)

.no_update:
    inc     rbx             ; j++ — scan the next element
    jmp     .ss_inner

.do_swap:
    cmp     r15, r14        ; compare min_idx with i
    je      .ss_next        ; if min_idx == i, minimum is already at position i — no swap needed

    ; ---- SWAP arr[i] and arr[min_idx] ----
    mov     rax, [r12 + r14*8]   ; rax = arr[i]       (value currently at position i)
    mov     rdx, [r12 + r15*8]  ; rdx = arr[min_idx]  (the smallest value found)

    mov     [r12 + r14*8], rdx  ; arr[i]       = arr[min_idx]  (put minimum into position i)
    mov     [r12 + r15*8], rax  ; arr[min_idx] = arr[i]        (move old arr[i] to vacated spot)

.ss_next:
    inc     r14             ; i++ — next position to fill
    jmp     .ss_outer

.ss_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret                     ; array is now sorted ascending


main:

    push    rbp             ; save caller's rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; Stack is 16-byte aligned: (ret addr 8) + (rbp 8) = 16. ✓

    ; ================================================================
    ; DEMO 2: SELECTION SORT
    ; ================================================================

    lea     rdi, [rel hdr_ss]
    xor     eax, eax
    call    printf              ; "=== SELECTION SORT ==="

    lea     rdi, [rel ss_before]
    xor     eax, eax
    call    printf              ; "Before: "

    lea     rdi, [rel ss_arr]
    mov     rsi, SS_LEN         ; rsi = 5
    call    print_array_long    ; prints: 64 25 12 22 11

    lea     rdi, [rel ss_arr]
    mov     rsi, SS_LEN
    call    selection_sort      ; sorts ss_arr in place

    lea     rdi, [rel ss_after]
    xor     eax, eax
    call    printf              ; "After:  "

    lea     rdi, [rel ss_arr]
    mov     rsi, SS_LEN
    call    print_array_long    ; prints: 11 12 22 25 64


    ; ================================================================
    ; RETURN 0
    ; ================================================================
    xor     eax, eax            ; return 0 (success)
    pop     rbp
    ret
