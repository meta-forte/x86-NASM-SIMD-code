; =================================================================
; all_programs.asm — x86-64 NASM Learning Collection
;
; WHAT THIS FILE CONTAINS (runs all five demos in order):
;   1. Bubble Sort          — sort a fixed array using adjacent swaps
;   2. Selection Sort       — sort a fixed array by finding minimums
;   3. Quick Sort           — sort a fixed array using pivot partitioning
;   4. Matrix 3x3 (fixed)  — always 3x3; user enters the 9+9 values
;   5. Matrix NxN (dynamic) — user picks N; program does NxN add & multiply
;
; BUILD:
;   nasm -f elf64 all_programs.asm -o all_programs.o
;   gcc  all_programs.o -o all_programs -no-pie
; RUN:
;   ./all_programs
;
; =================================================================
; KEY CONCEPTS (read once — not repeated in code comments below)
; -----------------------------------------------------------------
; SECTIONS:
;   .data  = initialised constants (strings, numbers known at write-time)
;   .bss   = zero-filled runtime storage (arrays filled during the run)
;   .text  = executable instructions (CPU reads and runs these)
;
; REGISTERS (16 general-purpose, 64-bit, on x86-64):
;   rax rbx rcx rdx rsi rdi rsp rbp r8..r15
;   Each has a 32-bit alias: eax ebx ecx edx ...
;   Writing to eXX always zeroes the upper 32 bits of rXX.
;
;   Caller-saved (a called function MAY overwrite freely):
;     rax rcx rdx rsi rdi r8 r9 r10 r11
;   Callee-saved (a called function MUST restore before returning):
;     rbx rbp r12 r13 r14 r15
;
; STACK:
;   Grows DOWNWARD. push = rsp-=8, store. pop = load, rsp+=8.
;   rsp must be a multiple of 16 BEFORE every 'call' instruction.
;   The 'call' instruction itself pushes an 8-byte return address.
;
; CALLING CONVENTION (Linux x86-64 SysV ABI):
;   Arguments: rdi, rsi, rdx, rcx, r8, r9 (then the stack)
;   Return value: rax
;   Before printf/scanf (variadic): set eax = 0 (zero float args)
;
; MEMORY ADDRESSING:
;   [base + index*scale]  —  scale can be 1,2,4,8.
;   e.g. [arr + rcx*4]   reads 4 bytes at arr[rcx] (int array).
;   e.g. [arr + rbx*8]   reads 8 bytes at arr[rbx] (long array).
;   'lea dest, [expr]'   loads the ADDRESS of expr (no memory read).
;
; ROW-MAJOR MATRIX LAYOUT:
;   A[i][j]  stored as flat array.  flat_index = i * N_cols + j.
;   byte_offset = flat_index * element_size.
; =================================================================

global main                 ; tell linker: 'main' is the program entry point
extern printf, scanf        ; C library I/O functions

; =================================================================
; SECTION .data — strings and static arrays (initialised on disk)
; =================================================================
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

    ; ---- Selection Sort ----
    hdr_ss    db "=== SELECTION SORT ===", 10, 0
    ss_before db "Before: ", 0
    ss_after  db "After:  ", 0

    ss_arr    dq 64, 25, 12, 22, 11
    ; Five 64-bit integers for the selection sort demo.

    SS_LEN    equ 5

    ; ---- Quick Sort ----
    hdr_qs    db "=== QUICK SORT ===", 10, 0
    ; Section header. Byte 10 = newline, byte 0 = null terminator.

    qs_before db "Before: ", 0
    ; Printed before showing the unsorted array.

    qs_after  db "After:  ", 0
    ; Printed after sorting.

    qs_arr    dq 3, 6, 8, 10, 1, 2, 1
    ; Seven 64-bit integers stored in .data (writable, sorted in place).
    ; In C: long long qs_arr[] = {3, 6, 8, 10, 1, 2, 1};

    QS_LEN    equ 7
    ; Assembler constant for the quick sort array length.

    ; ---- Shared format strings ----
    fmt_ld    db "%ld ", 0
    ; '%ld' prints a 64-bit signed integer (long). The trailing space
    ; separates elements. In C: printf("%ld ", value);

    newline   db 10, 0
    ; Just a newline character then null terminator.
    ; Used to end a printed line of array elements.

    ; ---- Matrix 3x3 (fixed) ----
    hdr_m3    db "=== MATRIX 3x3 (FIXED DIMENSION) ===", 10, 0

    s_A3      db "Enter 9 numbers for matrix A (row by row): ", 0
    ; Prompt: user must type 9 integers separated by Enter or spaces.

    s_B3      db "Enter 9 numbers for matrix B (row by row): ", 0

    s_add3    db "A + B:", 10, 0
    ; Header printed above the element-wise addition result.

    s_mul3    db "A x B:", 10, 0
    ; Header printed above the matrix multiplication result.

    fmt_d     db "%d", 0
    ; scanf format to read one 32-bit decimal integer.

    fmt_row3  db "%d %d %d", 10, 0
    ; Prints three integers on one line then a newline.
    ; Used to print one row of the 3x3 result matrix.

    ; ---- Matrix NxN (dynamic) ----
    hdr_mn    db "=== MATRIX NxN (DYNAMIC DIMENSION) ===", 10, 0

    s_ndim    db "Enter matrix dimension N (max 8): ", 0
    ; Ask the user for N. We reserve space for up to 8x8 = 64 elements.

    s_AN      db "Enter N*N numbers for matrix A (row by row): ", 0
    s_BN      db "Enter N*N numbers for matrix B (row by row): ", 0
    s_addN    db "A + B:", 10, 0
    s_mulN    db "A x B:", 10, 0

    fmt_int   db "%d ", 0
    ; Prints one 32-bit integer followed by a space.
    ; Used element-by-element when printing the NxN result.

; =================================================================
; SECTION .bss — zero-filled runtime storage
; The OS sets every byte to 0 when the program starts.
; 'resd N' = Reserve N Doublewords = N x 4 bytes (for 32-bit ints).
; =================================================================
section .bss

    ; ---- 3x3 matrices (9 elements each, 32-bit ints) ----
    A3   resd 9     ; matrix A input  — In C: int A3[9];
    B3   resd 9     ; matrix B input  — In C: int B3[9];
    C3   resd 9     ; result matrix   — In C: int C3[9]; (reused for add & mul)

    ; ---- NxN matrices (up to 8x8 = 64 elements each) ----
    dimN resd 1     ; N typed by user — In C: int dimN;
    AN   resd 64    ; NxN matrix A    — In C: int AN[64];
    BN   resd 64    ; NxN matrix B    — In C: int BN[64];
    CN   resd 64    ; NxN result      — In C: int CN[64];

; =================================================================
; SECTION .text — all executable code lives here
; =================================================================
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


; -----------------------------------------------------------------
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


; -----------------------------------------------------------------
; SUBROUTINE: partition   (helper for quicksort — not called directly)
;
; WHAT IT DOES:
;   Rearranges arr[lo..hi] so that all elements <= pivot are on the
;   left and all elements > pivot are on the right. Places the pivot
;   in its final correct position and returns that position.
;
;   This uses the LOMUTO PARTITION SCHEME:
;     - Pick arr[hi] as the pivot (the last element of the range).
;     - Keep a boundary 'i' starting just before lo.
;     - Scan every element arr[j] from lo to hi-1:
;         if arr[j] <= pivot:  advance i, then swap arr[i] and arr[j].
;     - After the scan: swap arr[i+1] and arr[hi] to place the pivot.
;     - Return i+1 (the pivot's final index).
;
; WHY THIS WORKS:
;   After partitioning:
;     arr[lo .. i]   — elements <= pivot  (the "left partition")
;     arr[i+1]       — the pivot itself   (already in its sorted slot)
;     arr[i+2 .. hi] — elements > pivot   (the "right partition")
;   We never need to touch arr[i+1] again — it is permanently placed.
;
; IN C:
;   long partition(long long *arr, long lo, long hi) {
;       long long pivot = arr[hi];
;       long i = lo - 1;
;       for (long j = lo; j < hi; j++) {
;           if (arr[j] <= pivot) {
;               i++;
;               long tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
;           }
;       }
;       long tmp = arr[i+1]; arr[i+1] = arr[hi]; arr[hi] = tmp;
;       return i + 1;
;   }
;
; ARGUMENTS:   rdi = arr,  rsi = lo,  rdx = hi
; RETURNS:     rax = pivot's final index (= i + 1 after the loop)
;
; NO FUNCTION CALLS INSIDE — all registers used are caller-saved
; (r8, r9, r10, rcx, rax), so no push/pop or stack frame needed.
;
; REGISTER MAP:
;   rdi = arr      (unchanged throughout — used as array base address)
;   rsi = lo       (unchanged — used as the starting value of j)
;   rdx = hi       (unchanged — loop upper bound and pivot index)
;   r8  = pivot    (arr[hi] — loaded once, compared against every arr[j])
;   rcx = i        (boundary: last index of the "left partition", starts at lo-1)
;   r9  = j        (scan index, starts at lo, goes up to hi-1)
;   rax = arr[j]   (current element being compared against pivot)
;   r10 = scratch  (temporary during the swap of arr[i] and arr[j])
; -----------------------------------------------------------------
partition:

    mov     r8, [rdi + rdx*8]
    ; r8 = pivot = arr[hi].
    ; rdi = array base address.
    ; rdx = hi (the last index of the current subarray).
    ; rdx*8 = hi * 8 bytes (each element is a long long = 8 bytes).
    ; [rdi + rdx*8] reads 8 bytes from memory at arr[hi].
    ; In C: long long pivot = arr[hi];

    mov     rcx, rsi        ; rcx = lo  (copy lo into rcx before we adjust it)
    dec     rcx             ; rcx = lo - 1  (i starts one position before the subarray)
    ; 'i' marks the rightmost element known to be <= pivot.
    ; It begins at lo-1 meaning "no left-partition elements yet".
    ; In C: long i = lo - 1;

    mov     r9, rsi         ; r9 = j = lo  (scan starts at the first element of the subarray)
    ; In C: long j = lo;

.part_loop:
    cmp     r9, rdx         ; compare j with hi
    jge     .part_done      ; if j >= hi, scan is complete (we do NOT compare arr[hi] with itself)
    ; The pivot at arr[hi] is excluded from the scan — it will be placed at the end.

    mov     rax, [rdi + r9*8]
    ; rax = arr[j] — the current element being examined.
    ; r9*8 = j * 8 bytes.
    ; In C: long long cur = arr[j];

    cmp     rax, r8         ; compare arr[j] with pivot
    jg      .part_no_swap   ; if arr[j] > pivot, leave it on the right side — skip the swap
    ; 'jg' = jump if greater (signed). Only elements <= pivot join the left partition.

    ; ---- arr[j] <= pivot: expand the left partition by one slot, then swap ----
    inc     rcx             ; i++  — advance the left-partition boundary
    ; After this, arr[i] is the slot we are about to fill with arr[j].

    mov     r10, [rdi + rcx*8]
    ; r10 = arr[i]  (the value currently sitting at the new left-partition slot).
    ; We need to save it so we can put it where arr[j] was.

    mov     [rdi + rcx*8], rax
    ; arr[i] = arr[j]  (move the small element into the left partition).
    ; rax still holds the old arr[j] value.
    ; In C: arr[i] = arr[j];

    mov     [rdi + r9*8], r10
    ; arr[j] = old arr[i]  (put the displaced element where arr[j] was).
    ; In C: arr[j] = tmp;
    ; After these two writes: arr[i] and arr[j] have been swapped.

.part_no_swap:
    inc     r9              ; j++  — move to the next element in the scan
    jmp     .part_loop      ; go back to the top and check j < hi

.part_done:
    ; ---- Place the pivot in its final sorted position ----
    ; At this point: arr[lo..i] <= pivot and arr[i+1..hi-1] > pivot.
    ; The pivot is still sitting at arr[hi].
    ; We swap arr[i+1] with arr[hi] to put the pivot in between the two partitions.

    inc     rcx             ; rcx = i + 1  (the final index where the pivot belongs)

    mov     rax, [rdi + rcx*8]
    ; rax = arr[i+1]  (the element currently at the pivot's destination slot).

    mov     r10, [rdi + rdx*8]
    ; r10 = arr[hi]  (the pivot — reading it from memory again to be safe).

    mov     [rdi + rcx*8], r10
    ; arr[i+1] = pivot  (place the pivot in its final sorted position).
    ; In C: arr[i+1] = arr[hi];

    mov     [rdi + rdx*8], rax
    ; arr[hi] = old arr[i+1]  (move the displaced element to where the pivot was).
    ; In C: arr[hi] = tmp;

    ; rcx = i + 1 = the pivot's final index.
    ; We return this value in rax (the SysV convention return register).
    mov     rax, rcx        ; rax = pivot index (return value)
    ret                     ; return; the pivot is now permanently placed


; -----------------------------------------------------------------
; SUBROUTINE: quicksort
;
; WHAT IT DOES:
;   Sorts arr[lo..hi] in ascending order using the quicksort algorithm.
;   Repeatedly partitions the subarray around a pivot, then recursively
;   sorts the left and right halves.
;
;   WHY QUICKSORT IS FAST:
;     Each call to partition does O(n) work and places ONE element
;     permanently. On average, the pivot splits the array roughly in
;     half each time, giving O(n log n) total work. Worst case is
;     O(n²) when the array is already sorted and we always pick the
;     last element as pivot (but this is rare on random data).
;
; IN C:
;   void quicksort(long long *arr, long lo, long hi) {
;       if (lo >= hi) return;                 // base case: 0 or 1 element
;       long p = partition(arr, lo, hi);      // place one pivot
;       quicksort(arr, lo, p - 1);            // sort left half
;       quicksort(arr, p + 1, hi);            // sort right half
;   }
;
; ARGUMENTS:   rdi = arr,  rsi = lo,  rdx = hi
;              The initial call is quicksort(arr, 0, len-1).
;
; RECURSIVE CALLS:
;   quicksort calls partition and itself recursively. We must save
;   arr, lo, hi, and p across each call because the call may overwrite
;   the caller-saved registers (rdi, rsi, rdx).
;   We use callee-saved registers r12..r15 so they survive every call.
;
; ALIGNMENT:
;   5 pushes (rbp + r12 + r13 + r14 + r15) × 8 + 8 (ret addr) = 48.
;   48 / 16 = 3. ✓ Aligned before every call — no sub rsp needed.
;
; REGISTER MAP:
;   r12 = arr   (base pointer, unchanged through all recursive levels)
;   r13 = lo    (left boundary of the current subarray being sorted)
;   r14 = hi    (right boundary of the current subarray being sorted)
;   r15 = p     (pivot index returned by partition)
; -----------------------------------------------------------------
quicksort:

    push    rbp
    mov     rbp, rsp        ; set up stack frame
    push    r12             ; save r12 — we will use it for arr
    push    r13             ; save r13 — we will use it for lo
    push    r14             ; save r14 — we will use it for hi
    push    r15             ; save r15 — we will use it for p (pivot index)
    ; Stack used: (ret 8) + (rbp 8) + (r12 8) + (r13 8) + (r14 8) + (r15 8) = 48 bytes.
    ; 48 / 16 = 3. ✓ rsp is 16-byte aligned before every 'call' below.

    mov     r12, rdi        ; r12 = arr  (save before rdi is overwritten)
    mov     r13, rsi        ; r13 = lo   (save before rsi is overwritten)
    mov     r14, rdx        ; r14 = hi   (save before rdx is overwritten)

    cmp     r13, r14        ; compare lo with hi  (signed comparison)
    jge     .qs_done        ; if lo >= hi, the subarray has 0 or 1 element — already sorted
    ; BASE CASE: a subarray of size 0 (lo > hi) or 1 (lo == hi) needs no sorting.
    ; lo > hi can happen when p = lo (pivot was already the leftmost element),
    ; making the left recursive call quicksort(arr, lo, lo-1) with lo-1 < lo.
    ; The signed jge handles this correctly (lo - 1 is negative only if lo = 0,
    ; and 0 >= -1 is true in signed arithmetic → base case triggered). ✓

    ; ---- Step 1: Partition arr[lo..hi] and get the pivot's index ----
    mov     rdi, r12        ; rdi = arr   (1st argument to partition)
    mov     rsi, r13        ; rsi = lo    (2nd argument)
    mov     rdx, r14        ; rdx = hi    (3rd argument)
    call    partition       ; rax = p (index where the pivot landed)
    ; After partition returns:
    ;   arr[lo .. p-1]  are all <= pivot  (left partition)
    ;   arr[p]          is the pivot itself, permanently sorted
    ;   arr[p+1 .. hi]  are all > pivot   (right partition)
    ; r12, r13, r14 are unchanged (callee-saved, partition did not touch them).

    mov     r15, rax        ; r15 = p  (save the pivot index for the two recursive calls)

    ; ---- Step 2: Recursively sort the LEFT partition arr[lo .. p-1] ----
    mov     rdi, r12        ; rdi = arr
    mov     rsi, r13        ; rsi = lo
    lea     rdx, [r15 - 1] ; rdx = p - 1  (right boundary of the left partition)
    ; 'lea rdx, [r15-1]' computes p-1 without reading memory.
    ; If p == lo, then p-1 = lo-1 < lo, and the recursive call hits the base case.
    call    quicksort       ; sort arr[lo .. p-1]
    ; r12, r13, r14, r15 survive this call (callee-saved).

    ; ---- Step 3: Recursively sort the RIGHT partition arr[p+1 .. hi] ----
    mov     rdi, r12        ; rdi = arr
    lea     rsi, [r15 + 1] ; rsi = p + 1  (left boundary of the right partition)
    mov     rdx, r14        ; rdx = hi
    call    quicksort       ; sort arr[p+1 .. hi]

.qs_done:
    pop     r15             ; restore registers in reverse push order
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret                     ; return; arr[lo..hi] is now sorted ascending


; -----------------------------------------------------------------
; SUBROUTINE: read_ints
;
; WHAT IT DOES:
;   Reads 'count' integers from the keyboard one by one using scanf,
;   storing each into the given int (32-bit) array.
;
; IN C:
;   void read_ints(int *arr, int count) {
;       for (int i = 0; i < count; i++)
;           scanf("%d", &arr[i]);
;   }
;
; ARGUMENTS:   rdi = array pointer (int*, 32-bit elements)
;              esi = count (how many integers to read)
; REGISTERS:   rbx=arr, r12=count, r13=i
; WHY CALLEE-SAVED: scanf overwrites rdi/rsi each call, so we
;   keep arr, count, i in rbx/r12/r13 which scanf must preserve.
; -----------------------------------------------------------------
read_ints:

    push    rbp
    mov     rbp, rsp
    push    rbx             ; array pointer
    push    r12             ; count
    push    r13             ; loop index i
    sub     rsp, 8          ; alignment: (ret 8)+(rbp 8)+(rbx 8)+(r12 8)+(r13 8)+8 = 48. ✓

    mov     rbx, rdi        ; rbx = arr  (save before rdi is overwritten)
    mov     r12d, esi       ; r12d = count  (32-bit; writing r12d zeroes upper 32 bits of r12)
    xor     r13d, r13d      ; r13d = 0  (i starts at 0)

.ri_loop:
    cmp     r13d, r12d      ; compare i with count
    jge     .ri_done        ; if i >= count, all integers read — return

    lea     rdi, [rel fmt_d]
    ; rdi = address of "%d\0". 1st argument to scanf. scanf uses this to know what type to read.

    lea     rsi, [rbx + r13*4]
    ; rsi = &arr[i] = base + i * 4  (each int = 4 bytes, so element i is 4*i bytes from base).
    ; 'lea' computes the address (no memory read). In C: rsi = &arr[i];
    ; rsi is the 2nd argument to scanf — the destination address where scanf will write the value.

    xor     eax, eax        ; 0 float args
    call    scanf           ; reads one decimal integer from keyboard, writes it to arr[i]
    ; After scanf: arr[i] holds whatever number the user typed.

    inc     r13d            ; i++
    jmp     .ri_loop

.ri_done:
    add     rsp, 8
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; -----------------------------------------------------------------
; SUBROUTINE: mat_add_3x3
;
; WHAT IT DOES:
;   Adds matrices A3 and B3 element-by-element. Stores result in C3.
;   Loops over all 9 elements (a 3x3 matrix flattened to a 1D array).
;
; IN C:
;   void mat_add_3x3() {
;       for (int i = 0; i < 9; i++) C3[i] = A3[i] + B3[i];
;   }
;
; No arguments — A3, B3, C3 are global .bss arrays.
; No calls made inside — no alignment padding or callee-save needed.
; Uses only caller-saved ecx (loop index) and eax (scratch).
; -----------------------------------------------------------------
mat_add_3x3:

    xor     ecx, ecx        ; ecx = 0  (loop index i)

.ma3_loop:
    cmp     ecx, 9          ; compare i with 9 (total elements in a 3x3 matrix)
    jge     .ma3_done       ; if i >= 9, all elements processed

    mov     eax, [A3 + rcx*4]
    ; eax = A3[i].
    ; A3 = absolute address of the first element of matrix A3.
    ; rcx*4 = i * 4 bytes (each int = 4 bytes). We use rcx (64-bit) for the address arithmetic.
    ; [A3 + rcx*4] reads 4 bytes (one int) from memory at address A3 + i*4.
    ; In C: eax = A3[i];

    add     eax, [B3 + rcx*4]
    ; eax = eax + B3[i] = A3[i] + B3[i].
    ; Reads 4 bytes from B3[i] and adds them to eax in a single instruction.
    ; In C: eax += B3[i];

    mov     [C3 + rcx*4], eax
    ; C3[i] = eax = A3[i] + B3[i].
    ; Writes 4 bytes (eax) to memory at address C3 + i*4.
    ; In C: C3[i] = eax;

    inc     ecx             ; i++
    jmp     .ma3_loop

.ma3_done:
    ret


; -----------------------------------------------------------------
; SUBROUTINE: mat_mul_3x3
;
; WHAT IT DOES:
;   Multiplies 3x3 matrices A3 and B3. Result in C3.
;
;   Matrix multiplication formula:
;     C3[i][j] = A3[i][0]*B3[0][j] + A3[i][1]*B3[1][j] + A3[i][2]*B3[2][j]
;
;   In flat array terms (row-major, stride=3):
;     A3[i][k]  at flat index i*3+k
;     B3[k][j]  at flat index k*3+j
;     C3[i][j]  at flat index i*3+j
;
; IN C:
;   void mat_mul_3x3() {
;       for (int i=0;i<3;i++)
;           for (int j=0;j<3;j++) {
;               int sum=0;
;               for (int k=0;k<3;k++) sum += A3[i*3+k] * B3[k*3+j];
;               C3[i*3+j] = sum;
;           }
;   }
;
; REGISTERS: r13=i, r14=j, r15=k, eax=sum, r12=scratch index, ebx=A3[i][k] temp
; -----------------------------------------------------------------
mat_mul_3x3:

    push    rbp
    mov     rbp, rsp
    push    rbx             ; A3[i][k] temporary
    push    r12             ; scratch for flat index calculations
    push    r13             ; outer loop i (row of A3 and C3)
    push    r14             ; middle loop j (column of B3 and C3)
    push    r15             ; inner loop k (dot-product index)
    sub     rsp, 8          ; (ret 8)+(rbp 8)+5*8+8 = 64. 64/16=4. Aligned. ✓

    xor     r13d, r13d      ; i = 0

.mm3_row:
    cmp     r13d, 3         ; if i >= 3, all rows done
    jge     .mm3_done

    xor     r14d, r14d      ; j = 0  (reset column counter for each new row)

.mm3_col:
    cmp     r14d, 3         ; if j >= 3, all columns for this row done
    jge     .mm3_next_row

    xor     eax, eax        ; sum = 0  (reset accumulator for each new output element)

    xor     r15d, r15d      ; k = 0

.mm3_inner:
    cmp     r15d, 3         ; if k >= 3, dot product is complete
    jge     .mm3_store

    ; ---- Load A3[i][k] ----
    mov     r12d, r13d      ; r12 = i
    imul    r12d, 3         ; r12 = i * 3   (row stride is 3 for a 3-column matrix)
    add     r12d, r15d      ; r12 = i*3 + k  (flat index of A3[i][k])

    mov     ebx, [A3 + r12*4]
    ; ebx = A3[i*3 + k] = A3[i][k].
    ; r12*4 converts the element index to a byte offset.

    ; ---- Load B3[k][j] and multiply ----
    mov     r12d, r15d      ; r12 = k
    imul    r12d, 3         ; r12 = k * 3
    add     r12d, r14d      ; r12 = k*3 + j  (flat index of B3[k][j])

    imul    ebx, [B3 + r12*4]
    ; ebx = ebx * B3[k*3+j] = A3[i][k] * B3[k][j].
    ; 'imul reg, mem' multiplies reg by the 32-bit value at the memory address.
    ; Result stays in ebx. In C: ebx = A3[i*3+k] * B3[k*3+j];

    add     eax, ebx        ; sum += A3[i][k] * B3[k][j]

    inc     r15d            ; k++
    jmp     .mm3_inner

.mm3_store:
    ; ---- Write completed dot product to C3[i][j] ----
    mov     r12d, r13d      ; r12 = i
    imul    r12d, 3         ; r12 = i * 3
    add     r12d, r14d      ; r12 = i*3 + j  (flat index of C3[i][j])

    mov     [C3 + r12*4], eax
    ; C3[i*3+j] = sum. In C: C3[i*3+j] = sum;

    inc     r14d            ; j++
    jmp     .mm3_col

.mm3_next_row:
    inc     r13d            ; i++
    jmp     .mm3_row

.mm3_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; -----------------------------------------------------------------
; SUBROUTINE: print_mat_3x3
;
; WHAT IT DOES:
;   Prints C3 (the 3x3 result) as 3 rows of 3 integers each.
;   Calls printf once per row with format "%d %d %d\n".
;
; IN C:
;   void print_mat_3x3() {
;       for (int row=0; row<3; row++)
;           printf("%d %d %d\n", C3[row*3], C3[row*3+1], C3[row*3+2]);
;   }
;
; printf takes 4 arguments here: rdi=format, rsi=1st val, rdx=2nd val, rcx=3rd val.
; We use 'movsx' to sign-extend 32-bit ints to 64-bit before passing to printf.
;
; REGISTERS: r12=row, rbx=row*3 (base flat index for current row)
; -----------------------------------------------------------------
print_mat_3x3:

    push    rbp
    mov     rbp, rsp
    push    rbx             ; row*3 (precomputed base index for current row)
    push    r12             ; row counter (0, 1, 2)
    ; (ret 8)+(rbp 8)+(rbx 8)+(r12 8) = 32. 32/16=2. Aligned. ✓  No sub needed.

    xor     r12d, r12d      ; row = 0

.pm3_loop:
    cmp     r12d, 3         ; if row >= 3, all rows printed
    jge     .pm3_done

    mov     rbx, r12        ; rbx = row  (copy to 64-bit for address arithmetic below)
    imul    rbx, 3          ; rbx = row * 3  (flat index of first element in this row)
    ; e.g. row=0 → rbx=0, row=1 → rbx=3, row=2 → rbx=6.

    lea     rdi, [rel fmt_row3]
    ; rdi = address of "%d %d %d\n". 1st argument to printf.

    movsx   rsi, dword [C3 + rbx*4]
    ; rsi = C3[row*3 + 0] sign-extended from 32 bits to 64 bits.
    ; rbx*4 = (row*3)*4 = byte offset of the first element in this row.
    ; 'dword' tells the assembler to read 4 bytes. 'movsx' fills the upper 32 bits of rsi
    ; with the sign bit of the 32-bit value (correct for negative numbers).
    ; rsi is the 2nd argument to printf (the first %d value).

    lea     rcx, [rbx + 1]  ; rcx = row*3 + 1  (flat index of the 2nd element)

    movsx   rdx, dword [C3 + rcx*4]
    ; rdx = C3[row*3 + 1] sign-extended to 64 bits.
    ; rdx is the 3rd argument to printf (the second %d value).

    lea     rcx, [rbx + 2]  ; rcx = row*3 + 2  (flat index of the 3rd element)

    movsx   rcx, dword [C3 + rcx*4]
    ; rcx = C3[row*3 + 2] sign-extended to 64 bits.
    ; SUBTLE: [C3 + rcx*4] computes the SOURCE address using the OLD value of rcx (row*3+2).
    ; The CPU calculates the address, reads 4 bytes, THEN writes the result into rcx.
    ; So the address calculation uses the index value, not the eventual new value — this is safe.
    ; rcx is the 4th argument to printf (the third %d value).

    xor     eax, eax        ; 0 float args
    call    printf          ; prints one row: "v1 v2 v3\n"

    inc     r12d            ; row++
    jmp     .pm3_loop

.pm3_done:
    pop     r12
    pop     rbx
    pop     rbp
    ret


; -----------------------------------------------------------------
; SUBROUTINE: mat_add_nxn
;
; WHAT IT DOES:
;   Adds AN and BN element-by-element. Stores result in CN.
;   Uses dimN to know how many elements (N*N total).
;
; IN C:
;   void mat_add_nxn() {
;       int total = dimN * dimN;
;       for (int i = 0; i < total; i++) CN[i] = AN[i] + BN[i];
;   }
;
; No arguments — uses globals dimN, AN, BN, CN.
; No calls — only caller-saved regs used (ecx, edx, eax). No pushes needed.
; -----------------------------------------------------------------
mat_add_nxn:

    mov     ecx, [dimN]     ; ecx = N  (load the dimension)
    imul    ecx, ecx        ; ecx = N * N  (total number of elements)
    ; 'imul ecx, ecx' = ecx = ecx * ecx (signed 32-bit multiply, result in ecx).

    xor     edx, edx        ; edx = 0  (loop index i)
    ; Writing edx zeroes the upper 32 bits of rdx, so rdx = edx throughout.

.man_loop:
    cmp     edx, ecx        ; compare i with N*N
    jge     .man_done       ; if i >= N*N, all elements processed

    mov     eax, [AN + rdx*4]
    ; eax = AN[i].  rdx is the 64-bit form of edx — same value, needed for addressing.

    add     eax, [BN + rdx*4]
    ; eax = AN[i] + BN[i].

    mov     [CN + rdx*4], eax
    ; CN[i] = AN[i] + BN[i].

    inc     edx             ; i++  (inc edx also zeroes upper 32 bits of rdx automatically)
    jmp     .man_loop

.man_done:
    ret


; -----------------------------------------------------------------
; SUBROUTINE: mat_mul_nxn
;
; WHAT IT DOES:
;   Multiplies NxN matrices AN and BN. Result in CN.
;   Dimension N is read from dimN at the start and kept in rbx.
;
;   Formula: CN[i][j] = sum_{k=0}^{N-1} AN[i*N+k] * BN[k*N+j]
;
; IN C:
;   void mat_mul_nxn() {
;       int N = dimN;
;       for (int i=0;i<N;i++)
;           for (int j=0;j<N;j++) {
;               int sum=0;
;               for (int k=0;k<N;k++) sum += AN[i*N+k] * BN[k*N+j];
;               CN[i*N+j] = sum;
;           }
;   }
;
; REGISTERS: rbx=N, r12=scratch index, r13=i, r14=j, r15=k,
;            eax=sum, ecx=AN[i][k] temp
; -----------------------------------------------------------------
mat_mul_nxn:

    push    rbp
    mov     rbp, rsp
    push    rbx             ; N (dimension — loaded once and held here)
    push    r12             ; scratch register for computing flat indices
    push    r13             ; outer loop i (row)
    push    r14             ; middle loop j (column)
    push    r15             ; inner loop k (dot-product index)
    sub     rsp, 8          ; (ret 8)+(rbp 8)+5*8+8 = 64. Aligned. ✓

    mov     ebx, [dimN]     ; ebx = N  (load dimension once; writing ebx zeroes upper rbx bits)
    ; We keep N in rbx so every loop comparison and index computation can use it directly.

    xor     r13d, r13d      ; i = 0

.mmn_row:
    cmp     r13d, ebx       ; if i >= N, all rows done
    jge     .mmn_done

    xor     r14d, r14d      ; j = 0  (reset for each new row i)

.mmn_col:
    cmp     r14d, ebx       ; if j >= N, all columns for this row done
    jge     .mmn_next_row

    xor     eax, eax        ; sum = 0  (fresh accumulator for CN[i][j])

    xor     r15d, r15d      ; k = 0

.mmn_inner:
    cmp     r15d, ebx       ; if k >= N, dot product complete
    jge     .mmn_store

    ; ---- Compute flat index of AN[i][k] = i*N + k ----
    mov     r12d, r13d      ; r12 = i
    imul    r12d, ebx       ; r12 = i * N   (N is the row stride for an N-column matrix)
    add     r12d, r15d      ; r12 = i*N + k  (flat index)

    mov     ecx, [AN + r12*4]
    ; ecx = AN[i*N + k] = AN[i][k].
    ; Writing to r12d zeroes upper bits of r12, so r12*4 is correct as a 64-bit address offset.

    ; ---- Compute flat index of BN[k][j] = k*N + j ----
    mov     r12d, r15d      ; r12 = k
    imul    r12d, ebx       ; r12 = k * N
    add     r12d, r14d      ; r12 = k*N + j  (flat index)

    imul    ecx, [BN + r12*4]
    ; ecx = AN[i][k] * BN[k][j].
    ; 'imul reg, mem' multiplies ecx by the 32-bit value at memory address (BN + r12*4).
    ; In C: ecx = AN[i*N+k] * BN[k*N+j];

    add     eax, ecx        ; sum += AN[i][k] * BN[k][j]

    inc     r15d            ; k++
    jmp     .mmn_inner

.mmn_store:
    ; ---- Write CN[i][j] = sum ----
    mov     r12d, r13d      ; r12 = i
    imul    r12d, ebx       ; r12 = i * N
    add     r12d, r14d      ; r12 = i*N + j  (flat index of CN[i][j])

    mov     [CN + r12*4], eax
    ; CN[i*N+j] = sum. In C: CN[i*N+j] = sum;

    inc     r14d            ; j++
    jmp     .mmn_col

.mmn_next_row:
    inc     r13d            ; i++
    jmp     .mmn_row

.mmn_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; -----------------------------------------------------------------
; SUBROUTINE: print_mat_nxn
;
; WHAT IT DOES:
;   Prints CN as an N-row by N-column grid. For each row, prints N
;   integers separated by spaces, then a newline.
;
; IN C:
;   void print_mat_nxn() {
;       int N = dimN;
;       for (int row=0; row<N; row++) {
;           for (int col=0; col<N; col++)
;               printf("%d ", CN[row*N+col]);
;           printf("\n");
;       }
;   }
;
; REGISTERS: r12=row, r13=N, r14=row*N (precomputed per row), rbx=col
; -----------------------------------------------------------------
print_mat_nxn:

    push    rbp
    mov     rbp, rsp
    push    rbx             ; column counter col
    push    r12             ; row counter row
    push    r13             ; N (dimension)
    push    r14             ; row * N (precomputed once per row to avoid repeated imul)
    ; (ret 8)+(rbp 8)+4*8 = 48. 48/16=3. Aligned. ✓  No sub needed.

    mov     r13d, [dimN]    ; r13d = N  (load dimension; upper r13 bits are zeroed)

    xor     r12d, r12d      ; row = 0

.pmn_row:
    cmp     r12d, r13d      ; if row >= N, all rows printed
    jge     .pmn_done

    mov     r14, r12        ; r14 = row  (64-bit, for use in imul and address arithmetic)
    imul    r14, r13        ; r14 = row * N  (flat index of the first element in this row)
    ; We precompute row*N once here so the inner loop only needs to add col to r14.

    xor     rbx, rbx        ; col = 0  (64-bit so we can use rbx directly in address math)

.pmn_col:
    cmp     rbx, r13        ; compare col with N  (r13 holds N as a 64-bit zero-extended value)
    jge     .pmn_newline    ; if col >= N, this row is fully printed — print newline

    lea     rax, [r14 + rbx]
    ; rax = row*N + col  (flat index of CN[row][col]).
    ; 'lea' computes the arithmetic without reading memory. rax = r14 + rbx.

    movsx   rsi, dword [CN + rax*4]
    ; rsi = CN[row*N + col] sign-extended from 32 bits to 64 bits.
    ; rax*4 converts element index to byte offset.
    ; rsi is the 2nd argument to printf (the element value for %d).

    lea     rdi, [rel fmt_int]
    ; rdi = address of "%d ". 1st argument to printf.

    xor     eax, eax        ; 0 float args
    call    printf          ; prints this one element followed by a space
    ; rbx, r12, r13, r14 are callee-saved — printf will not change them.

    inc     rbx             ; col++
    jmp     .pmn_col        ; print the next element in this row

.pmn_newline:
    lea     rdi, [rel newline]  ; rdi = "\n\0"
    xor     eax, eax
    call    printf          ; print newline after all N elements in this row

    inc     r12d            ; row++
    jmp     .pmn_row        ; start the next row

.pmn_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; =================================================================
; SUBROUTINE: main
;
; WHAT IT DOES:
;   Entry point. Runs all five demos in order:
;     1. Print, sort (bubble), print array.
;     2. Print, sort (selection), print array.
;     3. Print, sort (quicksort), print array.
;     4. Read two 3x3 matrices, add them, print, multiply them, print.
;     5. Ask for N, read two NxN matrices, add, print, multiply, print.
; =================================================================
main:

    push    rbp             ; save caller's (C runtime's) rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; After push rbp: (ret addr 8) + (rbp 8) = 16 bytes. 16/16=1. Aligned. ✓
    ; Every 'call' from here pushes 8 bytes, and each called function's
    ; first 'push rbp' brings rsp back to 16-byte alignment — no extra padding needed.

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
    ; DEMO 3: QUICK SORT
    ; ================================================================

    lea     rdi, [rel hdr_qs]   ; rdi = "=== QUICK SORT ===\n"
    xor     eax, eax
    call    printf              ; print section header

    lea     rdi, [rel qs_before]    ; "Before: "
    xor     eax, eax
    call    printf

    lea     rdi, [rel qs_arr]   ; rdi = pointer to qs_arr (1st arg to print_array_long)
    mov     rsi, QS_LEN         ; rsi = 7  (element count — 2nd arg)
    call    print_array_long    ; prints the original unsorted array

    lea     rdi, [rel qs_arr]   ; rdi = array pointer (1st arg to quicksort)
    mov     rsi, 0              ; rsi = lo = 0  (start of the array — 2nd arg)
    mov     rdx, QS_LEN - 1    ; rdx = hi = 6  (last index = len-1 — 3rd arg)
    ; QS_LEN-1 is computed by the assembler at assemble-time (7-1=6). Not a runtime subtract.
    call    quicksort           ; sorts qs_arr[0..6] in place — ascending order

    lea     rdi, [rel qs_after]     ; "After:  "
    xor     eax, eax
    call    printf

    lea     rdi, [rel qs_arr]   ; same array, now sorted
    mov     rsi, QS_LEN
    call    print_array_long    ; prints the sorted array

    ; ================================================================
    ; DEMO 4: MATRIX 3x3 (FIXED DIMENSION)
    ; ================================================================

    lea     rdi, [rel hdr_m3]
    xor     eax, eax
    call    printf              ; "=== MATRIX 3x3 (FIXED DIMENSION) ==="

    ; ---- Read matrix A3 (9 integers) ----
    lea     rdi, [rel s_A3]
    xor     eax, eax
    call    printf              ; "Enter 9 numbers for matrix A (row by row): "

    lea     rdi, [rel A3]       ; rdi = pointer to A3 array
    mov     esi, 9              ; esi = 9 elements
    call    read_ints           ; reads 9 integers from keyboard into A3[0..8]

    ; ---- Read matrix B3 (9 integers) ----
    lea     rdi, [rel s_B3]
    xor     eax, eax
    call    printf

    lea     rdi, [rel B3]
    mov     esi, 9
    call    read_ints           ; reads 9 integers into B3[0..8]

    ; ---- Compute and print A3 + B3 ----
    call    mat_add_3x3         ; C3[i] = A3[i] + B3[i] for all 9 elements

    lea     rdi, [rel s_add3]
    xor     eax, eax
    call    printf              ; "A + B:"

    call    print_mat_3x3       ; prints C3 as a 3-row grid

    ; ---- Compute and print A3 x B3 ----
    call    mat_mul_3x3         ; C3 = A3 * B3 (matrix product, overwrites C3)

    lea     rdi, [rel s_mul3]
    xor     eax, eax
    call    printf              ; "A x B:"

    call    print_mat_3x3       ; prints the new C3

    ; ================================================================
    ; DEMO 5: MATRIX NxN (DYNAMIC DIMENSION)
    ; ================================================================

    lea     rdi, [rel hdr_mn]
    xor     eax, eax
    call    printf              ; "=== MATRIX NxN (DYNAMIC DIMENSION) ==="

    ; ---- Ask user for N ----
    lea     rdi, [rel s_ndim]
    xor     eax, eax
    call    printf              ; "Enter matrix dimension N (max 8): "

    lea     rdi, [rel fmt_d]    ; scanf format "%d"
    lea     rsi, [rel dimN]     ; rsi = &dimN  (where to write the typed integer)
    xor     eax, eax
    call    scanf               ; reads N from keyboard into dimN

    ; ---- Compute count = N*N for read_ints ----
    mov     eax, [dimN]         ; eax = N
    imul    eax, eax            ; eax = N * N  (total elements in one NxN matrix)

    ; ---- Read matrix AN (N*N integers) ----
    lea     rdi, [rel s_AN]
    xor     ecx, ecx            ; ecx = 0 (clear before printf — needed as variadic call)
    call    printf              ; "Enter N*N numbers for matrix A (row by row): "
    ; NOTE: printf may clobber eax. We must reload N*N after this call.

    mov     eax, [dimN]         ; reload N
    imul    eax, eax            ; eax = N*N again  (printf may have overwritten eax)

    lea     rdi, [rel AN]       ; rdi = pointer to AN array
    mov     esi, eax            ; esi = N*N  (count for read_ints)
    call    read_ints           ; reads N*N integers into AN

    ; ---- Read matrix BN (N*N integers) ----
    lea     rdi, [rel s_BN]
    xor     eax, eax
    call    printf

    mov     eax, [dimN]
    imul    eax, eax            ; eax = N*N

    lea     rdi, [rel BN]
    mov     esi, eax
    call    read_ints           ; reads N*N integers into BN

    ; ---- Compute and print AN + BN ----
    call    mat_add_nxn         ; CN[i] = AN[i] + BN[i] for i in 0..N*N-1

    lea     rdi, [rel s_addN]
    xor     eax, eax
    call    printf              ; "A + B:"

    call    print_mat_nxn       ; prints CN as an N-row grid

    ; ---- Compute and print AN x BN ----
    call    mat_mul_nxn         ; CN = AN * BN (matrix product, overwrites CN)

    lea     rdi, [rel s_mulN]
    xor     eax, eax
    call    printf              ; "A x B:"

    call    print_mat_nxn       ; prints the new CN

    ; ================================================================
    ; RETURN 0 — program finished successfully
    ; ================================================================
    xor     eax, eax            ; eax = 0  (return value of main; 0 = success)
    pop     rbp                 ; restore caller's frame pointer
    ret                         ; return to C runtime; exit code = eax = 0
