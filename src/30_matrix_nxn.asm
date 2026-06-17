; =================================================================
; matrix_nxn.asm — N×N Matrix Add and Multiply Demo
;
; BUILD:
;   nasm -f elf64 matrix_nxn.asm -o matrix_nxn.o
;   gcc  matrix_nxn.o -o matrix_nxn -no-pie
; RUN:
;   ./matrix_nxn
; =================================================================

global main
extern printf, scanf

section .data

    fmt_d     db "%d", 0
    ; scanf format to read one 32-bit decimal integer.

    newline   db 10, 0
    ; Just a newline character then null terminator.
    ; Used to end a printed line of array elements.

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

section .bss

    ; ---- NxN matrices (up to 8×8 = 64 elements each) ----
    dimN resd 1     ; N typed by user — In C: int dimN;
    AN   resd 64    ; NxN matrix A    — In C: int AN[64];
    BN   resd 64    ; NxN matrix B    — In C: int BN[64];
    CN   resd 64    ; NxN result      — In C: int CN[64];

section .text

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


main:

    push    rbp             ; save caller's rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; Stack is 16-byte aligned: (ret addr 8) + (rbp 8) = 16. ✓

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
    ; RETURN 0
    ; ================================================================
    xor     eax, eax            ; return 0 (success)
    pop     rbp
    ret
