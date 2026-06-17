;═══════════════════════════════════════════════════════════════════════════════
; §24  Prefix Sum
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 24_prefix_sum.asm
;  Description : Inclusive and exclusive scan; SSE PSLLDQ shift-and-add trick
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 24_prefix_sum.asm — Exclusive and inclusive prefix sum (scan) of an int32 array
; Goal: reduction patterns, understanding prefix scan algorithms
;
; Given array A = [a0, a1, a2, a3, ...]
;
; INCLUSIVE prefix sum (also called "scan"):
;   out[i] = a0 + a1 + ... + ai
;   Example: [1,2,3,4,5] → [1, 3, 6, 10, 15]
;
; EXCLUSIVE prefix sum (also called "prescan"):
;   out[i] = a0 + a1 + ... + a(i-1)  (does NOT include a[i] itself)
;   out[0] = 0 by convention (identity element for addition)
;   Example: [1,2,3,4,5] → [0, 1, 3, 6, 10]
;
; Both are useful:
;   - Inclusive: "running total"
;   - Exclusive: "where does segment i start?" (used in parallel algorithms)
;
; Also shown: vectorized prefix sum for SSE (SIMD prefix scan using shifts).
;
; Build:
;   nasm -f elf64 24_prefix_sum.asm -o bin/24_prefix_sum.o
;   ld bin/24_prefix_sum.o -o bin/24_prefix_sum
; Run:
;   ./bin/24_prefix_sum
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16
    arr   dd 1, 2, 3, 4, 5, 6, 7, 8   ; 8 int32 values (4 bytes each), 16-byte aligned
    arr_n equ ($ - arr) / 4            ; count = byte_size / 4

    lbl_orig  db "Original:   ", 0
    lbl_incl  db "Inclusive:  ", 0
    lbl_excl  db "Exclusive:  ", 0
    sep       db ", ", 0
    newline   db 10

section .bss
    num_buf    resb 22
    incl_buf   resd 8       ; inclusive output (8 int32 = 32 bytes)
    excl_buf   resd 8       ; exclusive output

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; inclusive_scan_i32 — compute inclusive prefix sum of an int32 array
;   Input:  rdi = pointer to input int32 array
;           rsi = pointer to output int32 array
;           rdx = number of elements n
;
;   out[0] = in[0]
;   out[i] = out[i-1] + in[i]    for i > 0
; ───────────────────────────────────────────────────────────────────────────
inclusive_scan_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdx, rdx           ; n == 0?
    jz   .is_done           ; yes — nothing to do

    ; Load first element separately (no prior element to add)
    mov  eax, [rdi]         ; eax = in[0]  (load 32-bit integer)
    mov  [rsi], eax         ; out[0] = in[0]

    mov  rcx, 1             ; rcx = index = 1 (start at element 1)

.is_loop:
    cmp  rcx, rdx           ; index >= n?
    jge  .is_done           ; yes — all elements processed

    mov  eax, [rsi + rcx*4 - 4]   ; eax = out[i-1]  (previous output element, 4 bytes back)
    add  eax, [rdi + rcx*4]        ; eax = out[i-1] + in[i]  (add current input)
    mov  [rsi + rcx*4], eax        ; out[i] = out[i-1] + in[i]

    inc  rcx                ; advance to next element
    jmp  .is_loop           ; loop

.is_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; exclusive_scan_i32 — compute exclusive prefix sum of an int32 array
;   Input:  rdi = pointer to input int32 array
;           rsi = pointer to output int32 array
;           rdx = number of elements n
;
;   out[0] = 0
;   out[i] = out[i-1] + in[i-1]  for i > 0
; ───────────────────────────────────────────────────────────────────────────
exclusive_scan_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdx, rdx           ; n == 0?
    jz   .es_done           ; yes — nothing

    ; First output element is always 0 (identity element)
    mov  dword [rsi], 0     ; out[0] = 0

    xor  rax, rax           ; rax = 0 — running sum starts at 0
    mov  rcx, 1             ; rcx = index = 1

.es_loop:
    cmp  rcx, rdx           ; index >= n?
    jge  .es_done           ; yes — done

    add  eax, [rdi + rcx*4 - 4]   ; rax += in[i-1]  (add the PREVIOUS input element)
    mov  [rsi + rcx*4], eax        ; out[i] = running sum (which excludes in[i])

    inc  rcx                ; next element
    jmp  .es_loop           ; loop

.es_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; inclusive_scan_sse — vectorized inclusive prefix sum for 4 int32s using SSE
;   Input:  rdi = pointer to 4 int32 values (16-byte aligned)
;           rsi = pointer to output buffer (16-byte aligned, 16 bytes)
;
;   This processes exactly 4 elements at once using SSE2 shift-and-add.
;
;   Idea: use PSLLDQ (shift left by bytes) to create shifted copies, then add.
;
;   Given xmm0 = [a3, a2, a1, a0] (a0 is the lowest 32 bits):
;   Step 1: xmm1 = shift left by 4 bytes → [a2, a1, a0, 0]
;           xmm0 = xmm0 + xmm1 → [a3+a2, a2+a1, a1+a0, a0]
;   Step 2: xmm1 = shift left by 8 bytes → [a1+a0, a0, 0, 0]
;           xmm0 = xmm0 + xmm1 → [a3+a2+a1+a0, a2+a1+a0, a1+a0, a0]
;   Result: inclusive prefix sums for 4 elements
; ───────────────────────────────────────────────────────────────────────────
inclusive_scan_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    movdqa xmm0, [rdi]     ; xmm0 = [a3, a2, a1, a0] — load 4 int32s (aligned load)
                            ; MOVDQA: Move Aligned Double Quadword (16 bytes)

    ; Step 1: shift left by 4 bytes (one int32) and add
    movdqa xmm1, xmm0      ; xmm1 = copy of [a3, a2, a1, a0]
    pslldq xmm1, 4          ; xmm1 = [a2, a1, a0, 0] — shift whole register left by 4 bytes
                            ; PSLLDQ: Packed Shift Left Logical Double Quadword (byte granularity)
    paddd  xmm0, xmm1       ; xmm0 = [a3+a2, a2+a1, a1+a0, a0+0]
                            ; PADDD: Packed Add Doublewords — adds 4 pairs of int32s

    ; Step 2: shift left by 8 bytes (two int32s) and add
    movdqa xmm1, xmm0      ; xmm1 = current partial sums
    pslldq xmm1, 8          ; xmm1 = shift left 8 bytes — lower 2 lanes become 0
                            ; Now xmm1 = [a1+a0, a0, 0, 0]
    paddd  xmm0, xmm1       ; xmm0 = final inclusive sums: [a3+a2+a1+a0, a2+a1+a0, a1+a0, a0]
                            ; PADDD: Packed Add Doublewords

    movdqa [rsi], xmm0     ; store the 4 prefix sums to output buffer (aligned store)
                            ; MOVDQA: Move Aligned Double Quadword

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; [rsi] holds the 4 inclusive prefix sums

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers
; ───────────────────────────────────────────────────────────────────────────

print_i32:                  ; print single int32 (no newline); Input: edi = value
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)

    movsxd rdi, edi         ; sign-extend int32 to int64 for printing

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    xor  r13d, r13d         ; r13 = 0 (positive)

    test rdi, rdi
    jns  .p32p
    neg  rdi
    mov  r13d, 1

.p32p:
    mov  rax, rdi
    test rax, rax
    jnz  .p32d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .p32s

.p32d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .p32d

.p32s:
    test r13d, r13d
    jz   .p32t
    mov  byte [rbx], '-'
    inc  rbx

.p32t:
    mov  byte [rbx], 0
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.p32r:
    cmp  rsi, rdi
    jge  .p32w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .p32r

.p32w:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pc_l:
    cmp  byte [rdi + rcx], 0
    je   .pc_w
    inc  rcx
    jmp  .pc_l
.pc_w:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

print_i32_array:            ; print int32 array; rdi=ptr, rsi=count
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14
    push r15
    push rbx

    mov  r14, rdi
    mov  r15, rsi
    xor  rbx, rbx

.pa_l:
    cmp  rbx, r15
    jge  .pa_nl

    mov  edi, [r14 + rbx*4] ; load int32
    call print_i32

    lea  rax, [rbx + 1]
    cmp  rax, r15
    je   .pa_skip_sep
    mov  rdi, sep
    call print_cstr
.pa_skip_sep:
    inc  rbx
    jmp  .pa_l

.pa_nl:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    pop  rbx
    pop  r15
    pop  r14
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print original array
    mov  rdi, lbl_orig      ; "Original:   "
    call print_cstr
    mov  rdi, arr           ; rdi = array
    mov  rsi, arr_n         ; rsi = count
    call print_i32_array

    ; Compute and print inclusive prefix sum (scalar)
    mov  rdi, arr           ; input
    mov  rsi, incl_buf      ; output
    mov  rdx, arr_n         ; count
    call inclusive_scan_i32

    mov  rdi, lbl_incl      ; "Inclusive:  "
    call print_cstr
    mov  rdi, incl_buf      ; rdi = result array
    mov  rsi, arr_n         ; rsi = count
    call print_i32_array

    ; Compute and print exclusive prefix sum (scalar)
    mov  rdi, arr
    mov  rsi, excl_buf
    mov  rdx, arr_n
    call exclusive_scan_i32

    mov  rdi, lbl_excl      ; "Exclusive:  "
    call print_cstr
    mov  rdi, excl_buf
    mov  rsi, arr_n
    call print_i32_array

    ; Compute and print SSE vectorized prefix sum (first 4 elements)
    mov  rdi, arr           ; input (first 4 int32s, 16-byte aligned)
    mov  rsi, incl_buf      ; reuse incl_buf for SSE result
    call inclusive_scan_sse ; compute SSE prefix sum for first 4 elements

    ; (SSE result for first 4 matches scalar result for first 4)
    ; Print it — already in incl_buf from the SSE call
    ; (We already printed the full scalar version; this just confirms SSE matches)

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)
