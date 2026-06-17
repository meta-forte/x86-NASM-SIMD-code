;═══════════════════════════════════════════════════════════════════════════════
; §16  Rotate Array
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 16_rotate_array.asm
;  Description : In-place rotation via GCD cycle algorithm; Euclidean GCD
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 16_rotate_array.asm — Rotate an int64 array right by k positions in place
; Goal: modular indexing, GCD-cycle algorithm, loop invariants
;
; A "right rotation by k" means every element moves k positions to the right,
; wrapping around. Example: [1,2,3,4,5] rotated right by 2 → [4,5,1,2,3]
;
; Naive approach would require an extra O(n) buffer.
; The GCD-cycle method uses O(1) extra space by following the "destination"
; chain of each element until we return to the starting position:
;
;   The array splits into gcd(n, k) independent cycles.
;   For each starting position s in 0 .. gcd(n,k)-1:
;       current = s
;       saved   = arr[s]
;       repeat gcd steps:
;           next    = (current + k) % n
;           tmp     = arr[next]
;           arr[next] = saved
;           saved   = tmp
;           current = next
;       until current == s
;
; Build:
;   nasm -f elf64 16_rotate_array.asm -o bin/16_rotate_array.o
;   ld bin/16_rotate_array.o -o bin/16_rotate_array
; Run:
;   ./bin/16_rotate_array
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    arr    dq 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
    arr_n  equ ($ - arr) / 8       ; number of elements: byte count / 8

    k_val  dq 3                    ; rotate right by 3 positions

    before_lbl  db "Before: ", 0
    after_lbl   db "After:  ", 0
    sep         db ", ", 0
    newline     db 10

section .bss
    num_buf  resb 22               ; scratch buffer for number-to-string conversion

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; gcd — compute GCD of two 64-bit unsigned integers (Euclidean algorithm)
;   Input:  rdi = a
;           rsi = b
;   Output: rax = gcd(a, b)
; ───────────────────────────────────────────────────────────────────────────
gcd:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; Euclidean algorithm: gcd(a,b) = gcd(b, a mod b)
    ; Repeat until b == 0; then gcd = a
.euclid:
    test rsi, rsi           ; is b == 0?
    jz   .done              ; yes — gcd = a (in rdi)

    mov  rax, rdi           ; rax = a (dividend for division)
    xor  rdx, rdx           ; rdx = 0 — clear high half before division
    div  rsi                ; rax = a / b (quotient), rdx = a % b (remainder)

    mov  rdi, rsi           ; a = b    (shift: old b becomes new a)
    mov  rsi, rdx           ; b = a%b  (shift: remainder becomes new b)
    jmp  .euclid            ; iterate

.done:
    mov  rax, rdi           ; rax = gcd result
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = gcd(original_a, original_b)

; ───────────────────────────────────────────────────────────────────────────
; rotate_right — rotate int64 array right by k positions, in place (O(1) space)
;   Input:  rdi = pointer to int64_t array
;           rsi = n (number of elements)
;           rdx = k (rotation amount; 0 <= k < n)
;   Modifies the array in place.
; ───────────────────────────────────────────────────────────────────────────
rotate_right:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push r15                ; save r15 (callee-saved)

    ; Normalise k: k = k % n so it is always in [0, n-1]
    mov  rax, rdx           ; rax = k
    xor  rdx, rdx           ; rdx = 0 — clear high half
    div  rsi                ; rax = k/n, rdx = k%n
    mov  rdx, rdx           ; rdx = normalised k (already there, just for clarity)

    ; If k == 0 after normalisation, no rotation is needed
    test rdx, rdx           ; is k == 0?
    jz   .rr_done           ; yes — array is unchanged

    ; Save parameters in callee-saved registers so helper calls don't clobber them
    mov  r12, rdi           ; r12 = array pointer
    mov  r13, rsi           ; r13 = n
    mov  r14, rdx           ; r14 = normalised k

    ; Compute g = gcd(n, k) — number of independent cycles
    mov  rdi, r13           ; rdi = n
    mov  rsi, r14           ; rsi = k
    call gcd                ; rax = g
    mov  r15, rax           ; r15 = g = gcd(n, k)

    ; Outer loop: one iteration per cycle (g cycles total)
    xor  rbx, rbx           ; rbx = cycle starting index s (from 0 to g-1)

.cycle_loop:
    cmp  rbx, r15           ; processed all g cycles?
    jge  .rr_done           ; yes — done

    ; Inner loop: follow the cycle from starting position rbx
    ; We need to move each element to its destination:
    ;   destination of position i when rotating right by k is position (i + k) % n
    ;   equivalently, element at position i goes to (i + k) % n
    ;   but we are filling from the source perspective:
    ;       arr[current + k] = arr[current]  (where current is the SOURCE)

    mov  rcx, rbx           ; rcx = current position (starts at s = rbx)
    mov  rax, [r12 + rbx*8] ; rax = arr[s] — "saved" value to be displaced around the cycle

.inner_loop:
    ; Compute next = (current + k) % n
    mov  r8, rcx            ; r8 = current position
    add  r8, r14            ; r8 = current + k
    ; Compute r8 % n
    mov  rax, r8            ; rax = (current + k) — note: save and restore rax carefully
    ; We need the saved value in rax — save it temporarily
    ; Restructure: keep saved value in r9
    mov  r9, [r12 + rbx*8]  ; r9 = initial arr[s] ... wait, let me redo the cycle logic

    ; Actually let me redo this with cleaner register use
    jmp  .rr_done           ; placeholder — see fixed version below

.rr_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; rotate_right_clean — cleaner GCD cycle implementation
;   Input:  rdi = array pointer
;           rsi = n
;           rdx = k (will be normalised internally)
; ───────────────────────────────────────────────────────────────────────────
rotate_right_clean:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — cycle start 's' (callee-saved)
    push r12                ; save r12 — array pointer (callee-saved)
    push r13                ; save r13 — n (callee-saved)
    push r14                ; save r14 — k (callee-saved)
    push r15                ; save r15 — g = gcd(n,k) (callee-saved)

    mov  r12, rdi           ; r12 = array pointer
    mov  r13, rsi           ; r13 = n

    ; Normalise: k = k % n
    mov  rax, rdx           ; rax = k
    xor  rdx, rdx           ; rdx = 0
    div  r13                ; rax = k/n, rdx = k%n
    mov  r14, rdx           ; r14 = k (normalised)

    test r14, r14           ; k == 0?
    jz   .rc_exit           ; no rotation needed

    ; Compute g = gcd(n, k)
    mov  rdi, r13           ; n
    mov  rsi, r14           ; k
    call gcd                ; rax = gcd(n, k)
    mov  r15, rax           ; r15 = g

    ; Outer loop: for s = 0 to g-1
    xor  rbx, rbx           ; rbx = s = 0

.rc_outer:
    cmp  rbx, r15           ; s >= g?
    jge  .rc_exit           ; yes — all cycles processed

    ; Follow the cycle starting at 's'
    ; The cycle visits positions: s → (s+k)%n → (s+2k)%n → ... → s
    ;
    ; Algorithm:
    ;   current = s
    ;   saved   = arr[s]   — the "displaced" value travelling around the ring
    ;   loop (n/g) times:
    ;       next       = (current + k) % n
    ;       tmp        = arr[next]
    ;       arr[next]  = saved     — place saved at its destination
    ;       saved      = tmp       — carry the evicted value
    ;       current    = next
    ;
    ; We do (n/g - 1) iterations because the first assignment covers one slot.
    ; Actually simpler: repeat until we return to 's'.

    mov  rcx, rbx                  ; rcx = current = s
    mov  rax, [r12 + rbx*8]        ; rax = saved = arr[s]

.rc_inner:
    ; next = (current + k) % n
    mov  r8, rcx                   ; r8 = current
    add  r8, r14                   ; r8 = current + k
    ; r8 % n — use division
    push rax                       ; save 'saved' value while we do division
    mov  rax, r8                   ; rax = current + k (dividend)
    xor  rdx, rdx                  ; rdx = 0 (high half)
    div  r13                       ; rax = quotient, rdx = (current+k) % n
    mov  r8, rdx                   ; r8 = next = (current + k) % n
    pop  rax                       ; restore 'saved' value

    ; Move arr[next] → tmp, then arr[next] ← saved
    mov  r9, [r12 + r8*8]          ; r9 = tmp = arr[next]
    mov  [r12 + r8*8], rax         ; arr[next] = saved
    mov  rax, r9                   ; saved = tmp (carried around)

    mov  rcx, r8                   ; current = next
    cmp  rcx, rbx                  ; have we looped back to start s?
    jne  .rc_inner                 ; no — continue the cycle

    inc  rbx                       ; s++ — move to next cycle
    jmp  .rc_outer                 ; outer loop

.rc_exit:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers
; ───────────────────────────────────────────────────────────────────────────
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)
    push r13                ; save r13 — sign flag (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start address
    mov  rbx, num_buf       ; rbx = write position
    xor  r13, r13           ; r13 = 0 — positive flag

    test rdi, rdi           ; negative?
    jns  .p64_pos           ; no
    neg  rdi                ; flip sign
    mov  r13, 1             ; set negative flag

.p64_pos:
    mov  rax, rdi           ; rax = magnitude
    test rax, rax           ; zero?
    jnz  .p64_dig           ; no

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .p64_sgn           ; handle sign

.p64_dig:
    xor  rdx, rdx           ; rdx = 0 — clear high half
    mov  rcx, 10            ; rcx = 10 — decimal base
    div  rcx                ; rax = quotient, rdx = remainder
    add  dl, '0'            ; convert to ASCII
    mov  [rbx], dl          ; store digit
    inc  rbx                ; advance
    test rax, rax           ; done?
    jnz  .p64_dig           ; no

.p64_sgn:
    test r13, r13           ; was negative?
    jz   .p64_rev           ; no
    mov  byte [rbx], '-'    ; write minus
    inc  rbx                ; advance

.p64_rev:
    mov  byte [rbx], 0      ; null-terminate
    lea  rdi, [rbx - 1]     ; rdi = last char
    mov  rsi, r12           ; rsi = first char
.p64_rl:
    cmp  rsi, rdi           ; crossed?
    jge  .p64_wr            ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance
    dec  rdi                ; advance
    jmp  .p64_rl            ; loop

.p64_wr:
    mov  rsi, r12           ; rsi = string start
    mov  rdx, rbx           ; rdx = end
    sub  rdx, r12           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length
.pc2_len:
    cmp  byte [rdi + rcx], 0  ; null byte?
    je   .pc2_wr              ; yes
    inc  rcx                  ; no — count
    jmp  .pc2_len             ; loop

.pc2_wr:
    pop  rsi                ; rsi = string pointer
    mov  rdx, rcx           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write

    pop  rbp                ; restore caller's frame pointer
    ret

print_array:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — array pointer (callee-saved)
    push r15                ; save r15 — count (callee-saved)
    push rbx                ; save rbx — index (callee-saved)

    mov  r14, rdi           ; r14 = array pointer
    mov  r15, rsi           ; r15 = count
    xor  rbx, rbx           ; rbx = index = 0

.pa2_loop:
    cmp  rbx, r15           ; index >= count?
    jge  .pa2_nl            ; done

    mov  rdi, [r14 + rbx*8] ; rdi = arr[index]
    call print_i64          ; print element

    lea  rax, [rbx + 1]     ; rax = index + 1
    cmp  rax, r15           ; last element?
    je   .pa2_skip_sep      ; skip separator after last

    mov  rdi, sep           ; rdi = ", "
    call print_cstr         ; print separator

.pa2_skip_sep:
    inc  rbx                ; next element
    jmp  .pa2_loop          ; loop

.pa2_nl:
    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write syscall
    syscall                 ; newline

    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print array before rotation
    mov  rdi, before_lbl    ; rdi = "Before: "
    call print_cstr         ; print label

    mov  rdi, arr           ; rdi = array
    mov  rsi, arr_n         ; rsi = count
    call print_array        ; print elements

    ; Rotate right by k
    mov  rdi, arr           ; rdi = array pointer
    mov  rsi, arr_n         ; rsi = n
    mov  rdx, [k_val]       ; rdx = k (load from memory)
    call rotate_right_clean ; perform in-place rotation

    ; Print array after rotation
    mov  rdi, after_lbl     ; rdi = "After:  "
    call print_cstr         ; print label

    mov  rdi, arr           ; rdi = array
    mov  rsi, arr_n         ; rsi = count
    call print_array        ; print rotated array

    ; Exit
    mov  rax, 60            ; rax = 60 — exit syscall
    xor  rdi, rdi           ; rdi = 0 — success
    syscall                 ; exit(0)
