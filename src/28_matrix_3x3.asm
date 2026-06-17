; =================================================================
; matrix_3x3.asm — 3×3 Matrix Add and Multiply Demo
;
; BUILD:
;   nasm -f elf64 matrix_3x3.asm -o matrix_3x3.o
;   gcc  matrix_3x3.o -o matrix_3x3 -no-pie
; RUN:
;   ./matrix_3x3
; =================================================================

global main
extern printf, scanf

section .data

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

section .bss

    ; ---- 3x3 matrices (9 elements each, 32-bit ints) ----
    A3   resd 9     ; matrix A input  — In C: int A3[9];
    B3   resd 9     ; matrix B input  — In C: int B3[9];
    C3   resd 9     ; result matrix   — In C: int C3[9]; (reused for add & mul)

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


main:

    push    rbp             ; save caller's rbp
    mov     rbp, rsp        ; mark main's stack frame
    ; Stack is 16-byte aligned: (ret addr 8) + (rbp 8) = 16. ✓


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
    ; RETURN 0
    ; ================================================================
    xor     eax, eax            ; return 0 (success)
    pop     rbp
    ret
