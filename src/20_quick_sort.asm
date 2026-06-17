; =================================================================
; quick_sort.asm — Quick Sort Demo
;
; BUILD:
;   nasm -f elf64 quick_sort.asm -o quick_sort.o
;   gcc  quick_sort.o -o quick_sort -no-pie
; RUN:
;   ./quick_sort
; =================================================================

global main
extern printf, scanf

section .data

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


main:

    push    rbp             ; save caller's rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; Stack is 16-byte aligned: (ret addr 8) + (rbp 8) = 16. ✓

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
    ; RETURN 0
    ; ================================================================
    xor     eax, eax            ; return 0 (success)
    pop     rbp
    ret
