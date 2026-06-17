; =============================================================================
; transpose.asm — Transpose an N×N integer matrix
;
; Description:
;   Asks the user for the dimension N (max 8), reads an N×N matrix of
;   32-bit integers row by row, computes its transpose, and prints both
;   the original and the transposed matrix.
;
;   Transpose rule:  T[i][j] = A[j][i]
;
;   Row-major flat indexing:
;     A[i][j]  at flat index i*N + j
;     T[i][j] = A[j][i]  at flat index j*N + i
;
; Concepts:
;   • Stack-allocated 8×8 int32 matrices (no .bss): 8*8*4 = 256 bytes each
;   • Triple-nested loop pattern for matrix transposition
;   • printf with variable number of elements per row (inner loop)
;
; Build:
;   nasm -f elf64 transpose.asm -o obj/transpose.o
;   gcc   obj/transpose.o -o bin/transpose -no-pie
;
; Run:
;   ./bin/transpose
; =============================================================================

global main
extern printf, scanf

section .data

    prompt_n    db "Enter matrix dimension N (1-8): ", 0
    prompt_row  db "Enter row %d (space-separated): ", 0
    fmt_in_n    db "%d", 0          ; read int32 for N
    fmt_in_val  db "%d", 0          ; read int32 element
    hdr_orig    db "Original matrix:", 10, 0
    hdr_trans   db "Transposed matrix:", 10, 0
    fmt_elem    db "%5d", 0         ; print one element right-aligned in 5 chars
    fmt_newline db 10, 0            ; newline after each row

section .text

; ── read_n ────────────────────────────────────────────────────────────────────
; Read an int32 into *rsi.  rdi = format string.
; ──────────────────────────────────────────────────────────────────────────────
read_n:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── print_matrix ──────────────────────────────────────────────────────────────
; Print an N×N int32 matrix stored row-major in memory.
; Args: rdi = pointer to matrix (int32 array), rsi = N
; Uses callee-saved r12 (pointer), r13 (N), r14 (row), r15 (col).
; ──────────────────────────────────────────────────────────────────────────────
print_matrix:
    push    rbp
    mov     rbp, rsp
    push    r12
    push    r13
    push    r14
    push    r15
    ; (ret 8)+(rbp 8)+4*8 = 48. 48/16=3. ✓  No sub rsp needed.

    mov     r12, rdi            ; r12 = matrix base pointer
    mov     r13d, esi           ; r13d = N (32-bit)

    xor     r14d, r14d          ; row = 0

.row_loop:
    cmp     r14d, r13d          ; row < N ?
    jge     .row_done

    xor     r15d, r15d          ; col = 0

.col_loop:
    cmp     r15d, r13d          ; col < N ?
    jge     .col_done

    ; Flat index = row*N + col;  byte offset = (row*N + col) * 4
    mov     eax, r14d           ; eax = row
    imul    eax, r13d           ; eax = row * N
    add     eax, r15d           ; eax = row*N + col
    ; Load element: matrix[row*N + col]
    movsx   rsi, dword [r12 + rax*4]
    ; 'movsx' sign-extends the 32-bit int to 64-bit for printf's %d

    lea     rdi, [rel fmt_elem]
    xor     eax, eax
    call    printf              ; print one element

    inc     r15d                ; col++
    jmp     .col_loop

.col_done:
    ; Print newline after each row
    lea     rdi, [rel fmt_newline]
    xor     eax, eax
    call    printf

    inc     r14d                ; row++
    jmp     .row_loop

.row_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout:
;   [rbp -   4]    = N  (int32)
;   [rbp -   8]    = padding
;   [rbp - 264]    = matrix A  (8×8 int32 = 256 bytes, at [rbp-264]..[rbp-8])
;   [rbp - 520]    = matrix T  (8×8 int32 = 256 bytes, transposed)
;   padding: (ret 8)+(rbp 8)+(520) = 536. 536/8=67. 536 % 16 = 8 → add 8 → 544.
;   sub rsp, 544  (544/16=34 ✓)
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 544

    ; ── Read N ────────────────────────────────────────────────────────────────
    lea     rdi, [rel prompt_n]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in_n]
    lea     rsi, [rbp - 4]          ; &N  (int32, only 4 bytes used)
    call    read_n

    movsx   r12, dword [rbp - 4]    ; r12 = N (sign-extended to 64-bit, callee-saved)

    ; Clamp N to [1, 8] for safety
    cmp     r12, 1
    jl      .clamp_low
    cmp     r12, 8
    jle     .read_matrix
    mov     r12, 8              ; clamp to 8
    jmp     .read_matrix
.clamp_low:
    mov     r12, 1

.read_matrix:
    ; ── Read N rows of N integers into matrix A ────────────────────────────────
    xor     r13, r13            ; row = 0

.read_row_loop:
    cmp     r13, r12
    jge     .read_done

    lea     rdi, [rel prompt_row]
    mov     rsi, r13
    inc     rsi                 ; display 1-based row number
    xor     eax, eax
    call    printf

    xor     r14, r14            ; col = 0

.read_col_loop:
    cmp     r14, r12
    jge     .read_col_done

    ; Flat index = row*N + col
    mov     rax, r13
    imul    rax, r12            ; rax = row * N
    add     rax, r14            ; rax = row*N + col

    lea     rdi, [rel fmt_in_val]
    lea     rsi, [rbp - 264]    ; base of matrix A
    lea     rcx, [rax*4]        ; byte offset = flat_index * 4
    add     rsi, rcx            ; rsi = &A[row][col]
    call    read_n

    inc     r14                 ; col++
    jmp     .read_col_loop

.read_col_done:
    inc     r13                 ; row++
    jmp     .read_row_loop

.read_done:
    ; ── Compute transpose: T[i][j] = A[j][i] ─────────────────────────────────
    xor     r13, r13            ; i = 0

.trans_row:
    cmp     r13, r12
    jge     .trans_done

    xor     r14, r14            ; j = 0

.trans_col:
    cmp     r14, r12
    jge     .trans_col_done

    ; A[j][i] = flat index j*N + i
    mov     rax, r14            ; rax = j
    imul    rax, r12            ; rax = j*N
    add     rax, r13            ; rax = j*N + i
    mov     ecx, [rbp - 264 + rax*4]   ; ecx = A[j][i]

    ; T[i][j] = flat index i*N + j
    mov     rax, r13
    imul    rax, r12
    add     rax, r14            ; rax = i*N + j
    mov     [rbp - 520 + rax*4], ecx   ; T[i][j] = A[j][i]

    inc     r14
    jmp     .trans_col

.trans_col_done:
    inc     r13
    jmp     .trans_row

.trans_done:
    ; ── Print original matrix ─────────────────────────────────────────────────
    lea     rdi, [rel hdr_orig]
    xor     eax, eax
    call    printf

    lea     rdi, [rbp - 264]    ; rdi = &A[0][0]
    mov     rsi, r12            ; rsi = N
    call    print_matrix

    ; ── Print transposed matrix ───────────────────────────────────────────────
    lea     rdi, [rel hdr_trans]
    xor     eax, eax
    call    printf

    lea     rdi, [rbp - 520]    ; rdi = &T[0][0]
    mov     rsi, r12
    call    print_matrix

    xor     eax, eax
    leave
    ret
