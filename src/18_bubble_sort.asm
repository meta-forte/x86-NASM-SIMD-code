; =================================================================
; bubble_sort.asm — Bubble Sort Demo
;
; BUILD:
;   nasm -f elf64 bubble_sort.asm -o bubble_sort.o
;   gcc  bubble_sort.o -o bubble_sort -no-pie
; RUN:
;   ./bubble_sort
; =================================================================

global main
extern printf, scanf

section .data

    ; ---- Bubble Sort ----
    hdr_bs    db "=== BUBBLE SORT ===", 10, 0
    ; String bytes + 10 (ASCII newline) + 0 (null terminator).
    ; In C: char hdr_bs[] = "=== BUBBLE SORT ===\n";

    bs_before db "Before: ", 0
    ; Printed before showing the original unsorted array.

    bs_after  db "After:  ", 0
    ; Printed after sorting, before showing the sorted array.

    bs_arr    dq 64, 34, 25, 12, 22, 11, 90
    ; 'dq' = Define Quadword = 8 bytes each.
    ; Seven 64-bit signed integers stored in .data — they ARE writable
    ; at runtime, so the sort can modify them in place.
    ; In C: long long bs_arr[] = {64, 34, 25, 12, 22, 11, 90};

    BS_LEN    equ 7
    ; Assembler constant — like #define BS_LEN 7.
    ; NOT stored in memory; the assembler replaces 'BS_LEN' with 7 everywhere.

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


; -----------------------------------------------------------------
; SUBROUTINE: bubble_sort
;
; WHAT IT DOES:
;   Sorts a 64-bit integer array in ascending order using bubble sort.
;   Each pass through the array compares every adjacent pair; if the
;   left element is bigger than the right, they are swapped. After
;   each pass, the largest unsorted element has "bubbled" to the end.
;
; IN C:
;   void bubble_sort(long long *arr, long n) {
;       for (long i = 0; i < n; i++) {            // outer pass number
;           for (long j = 0; j < n-i-1; j++) {   // scan unsorted part
;               if (arr[j] > arr[j+1]) {
;                   long tmp = arr[j];
;                   arr[j]   = arr[j+1];
;                   arr[j+1] = tmp;
;               }
;           }
;       }
;   }
;
; WHY INNER LIMIT IS n-i-1:
;   After pass i, the largest i elements are already correctly placed
;   at the right end. We only need to check pairs in the unsorted left
;   portion: indices 0 through n-i-2 (so j goes up to n-i-2, meaning
;   j+1 goes up to n-i-1 — the last unsorted position).
;
; ARGUMENTS:   rdi = array pointer,  rsi = length n
; REGISTERS:   r12=arr, r13=n, r14=i, rbx=j, rcx=inner_limit,
;              rax=arr[j], rdx=arr[j+1]
; NO CALLS inside this function, so alignment padding not needed.
; -----------------------------------------------------------------
bubble_sort:

    push    rbx             ; save rbx — inner loop counter j
    push    r12             ; save r12 — array base pointer
    push    r13             ; save r13 — array length n
    push    r14             ; save r14 — outer loop counter i

    mov     r12, rdi        ; r12 = arr
    mov     r13, rsi        ; r13 = n
    xor     r14, r14        ; r14 = 0  (i = 0, first outer pass)

.outer:
    cmp     r14, r13        ; compare i with n
    jge     .bs_done        ; if i >= n, all passes done — array is sorted

    xor     rbx, rbx        ; rbx = 0  (j = 0, start inner scan from beginning)

    mov     rcx, r13        ; rcx = n
    sub     rcx, r14        ; rcx = n - i
    dec     rcx             ; rcx = n - i - 1  (inner loop scans 0..rcx-1 pairs)

.inner:
    cmp     rbx, rcx        ; compare j with n-i-1
    jge     .next_outer     ; if j >= n-i-1, this pass is complete

    mov     rax, [r12 + rbx*8]
    ; rax = arr[j]   (the LEFT element of the pair we are comparing)

    mov     rdx, [r12 + rbx*8 + 8]
    ; rdx = arr[j+1] (the RIGHT element).
    ; Adding 8 to the offset is the same as +1 to the index (each element = 8 bytes).

    cmp     rax, rdx        ; compare arr[j] with arr[j+1]
    jle     .no_swap        ; if arr[j] <= arr[j+1], they are in the right order — skip swap
    ; 'jle' = jump if less or equal. We only swap if arr[j] is STRICTLY GREATER.

    ; ---- SWAP arr[j] and arr[j+1] ----
    ; rax already holds old arr[j], rdx holds old arr[j+1].
    mov     [r12 + rbx*8],     rdx  ; arr[j]   = old arr[j+1]  (put bigger on the right)
    mov     [r12 + rbx*8 + 8], rax  ; arr[j+1] = old arr[j]    (put smaller on the left)

.no_swap:
    inc     rbx             ; j++ — advance to the next adjacent pair
    jmp     .inner          ; check this new pair

.next_outer:
    inc     r14             ; i++ — one full pass done
    jmp     .outer          ; start the next pass

.bs_done:
    pop     r14             ; restore registers in reverse push order
    pop     r13
    pop     r12
    pop     rbx
    ret                     ; array is now sorted ascending



main:

    push    rbp             ; save caller's rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; Stack is 16-byte aligned: (ret addr 8) + (rbp 8) = 16. ✓

    ; ================================================================
    ; DEMO 1: BUBBLE SORT
    ; ================================================================

    lea     rdi, [rel hdr_bs]   ; 1st arg = "=== BUBBLE SORT ===\n"
    xor     eax, eax
    call    printf              ; print section header

    lea     rdi, [rel bs_before]    ; "Before: "
    xor     eax, eax
    call    printf

    lea     rdi, [rel bs_arr]   ; rdi = pointer to bs_arr (1st arg to print_array_long)
    mov     rsi, BS_LEN         ; rsi = 7  (2nd arg — element count)
    call    print_array_long    ; prints: 64 34 25 12 22 11 90

    lea     rdi, [rel bs_arr]   ; rdi = array pointer (1st arg to bubble_sort)
    mov     rsi, BS_LEN         ; rsi = 7  (2nd arg — element count)
    call    bubble_sort         ; sorts bs_arr in place — ascending order

    lea     rdi, [rel bs_after]     ; "After:  "
    xor     eax, eax
    call    printf

    lea     rdi, [rel bs_arr]   ; same array, now sorted
    mov     rsi, BS_LEN
    call    print_array_long    ; prints: 11 12 22 25 34 64 90


    ; ================================================================
    ; RETURN 0
    ; ================================================================
    xor     eax, eax            ; return 0 (success)
    pop     rbp
    ret
