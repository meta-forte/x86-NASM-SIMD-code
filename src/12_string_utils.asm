;═══════════════════════════════════════════════════════════════════════════════
; §04  String Utils
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 04_string_utils.asm
;  Description : my_strlen / my_strcmp / my_memcpy — pointer arithmetic
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 04_string_utils.asm — strlen, strcmp, memcpy implemented in assembly
; Goal: memory operations, pointer arithmetic, byte-level access
;
; Three key string functions:
;   my_strlen(str)          — count bytes before null terminator
;   my_strcmp(s1, s2)       — compare two strings lexicographically
;   my_memcpy(dst, src, n)  — copy n bytes from src to dst
;
; Each function is compatible with the C calling convention so they could be
; linked with C programs (prototype declared with 'global').
;
; We also include a self-test: each function is called with known inputs and
; the results are printed, so you can verify correctness.
;
; Build:
;   nasm -f elf64 04_string_utils.asm -o bin/04_string_utils.o
;   ld bin/04_string_utils.o -o bin/04_string_utils
; Run:
;   ./bin/04_string_utils
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    s_hello   db "Hello", 0        ; test string — 5 bytes + null
    s_world   db "World", 0        ; test string — 5 bytes + null
    s_abc     db "abc", 0          ; test string — 3 bytes + null
    s_abd     db "abd", 0          ; lexicographically greater than "abc"
    s_empty   db "", 0             ; empty string — just null

    ; Source buffer for memcpy test
    src_buf   db "ABCDEFGHIJ", 0   ; 10 bytes + null

    ; Newline and output labels
    newline   db 10
    lbl_slen  db "strlen('Hello')   = ", 0
    lbl_slen2 db "strlen('')        = ", 0
    lbl_cmp1  db "strcmp(abc,abc)   = ", 0
    lbl_cmp2  db "strcmp(abc,abd)   = ", 0
    lbl_cmp3  db "strcmp(abd,abc)   = ", 0
    lbl_cpy   db "memcpy result     = ", 0

section .bss
    dst_buf   resb 16       ; destination buffer for memcpy test (16 uninitialised bytes)
    num_buf   resb 22       ; scratch for number-to-string

section .text
global _start
global my_strlen            ; expose for potential C linkage
global my_strcmp            ; expose for potential C linkage
global my_memcpy            ; expose for potential C linkage

; ───────────────────────────────────────────────────────────────────────────
; my_strlen — count bytes before null terminator
;   C prototype: size_t my_strlen(const char *s);
;   Input:  rdi = pointer to null-terminated string
;   Output: rax = number of bytes (not counting null terminator)
;
;   Implementation: scan byte-by-byte until we hit a zero byte.
; ───────────────────────────────────────────────────────────────────────────
my_strlen:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — count starts at zero

.sl_loop:
    cmp  byte [rdi + rax], 0   ; is the byte at (base + count) a null terminator?
    je   .sl_ret               ; yes — done counting
    inc  rax                   ; no  — increment count and check next byte
    jmp  .sl_loop              ; go back

.sl_ret:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string length

; ───────────────────────────────────────────────────────────────────────────
; my_strcmp — compare two null-terminated strings
;   C prototype: int my_strcmp(const char *s1, const char *s2);
;   Input:  rdi = pointer to string s1
;           rsi = pointer to string s2
;   Output: rax < 0  if s1 < s2 (s1 comes before s2 alphabetically)
;           rax == 0 if s1 == s2 (strings are identical)
;           rax > 0  if s1 > s2 (s1 comes after s2 alphabetically)
;
;   Implementation: compare bytes one at a time.
;   Stop at the first differing byte or at the null terminator.
;   The return value is (s1[i] - s2[i]) at the point they differ.
; ───────────────────────────────────────────────────────────────────────────
my_strcmp:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

.sc_loop:
    movzx rax, byte [rdi]   ; rax = (unsigned) current byte of s1 (zero-extended: fills upper bytes with 0)
    movzx rcx, byte [rsi]   ; rcx = (unsigned) current byte of s2 (zero-extended)

    ; Test if s1's current byte is null (end of string)
    test  al, al            ; is s1[i] == 0?
    jz    .sc_end           ; yes — both must end here (or s2 has more chars)

    ; Test if the bytes differ
    cmp   al, cl            ; is s1[i] == s2[i]?
    jne   .sc_end           ; no  — we found a difference; rax - rcx is the result

    ; Bytes are equal and non-null — advance both pointers
    inc   rdi               ; move s1 pointer to next character
    inc   rsi               ; move s2 pointer to next character
    jmp   .sc_loop          ; compare the next pair of characters

.sc_end:
    sub   rax, rcx          ; rax = s1[i] - s2[i] — this is the signed comparison result
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax encodes the comparison outcome

; ───────────────────────────────────────────────────────────────────────────
; my_memcpy — copy exactly n bytes from src to dst
;   C prototype: void *my_memcpy(void *dst, const void *src, size_t n);
;   Input:  rdi = destination pointer
;           rsi = source pointer
;           rdx = number of bytes to copy
;   Output: rax = dst (pointer to destination — C convention for memcpy)
;
;   Implementation: copy 8 bytes (qword) at a time for speed, then handle
;   any remaining bytes one at a time.
;
;   Note: behaviour is undefined if [dst, dst+n) overlaps [src, src+n).
;   For overlapping copies, use memmove (which checks the overlap direction).
; ───────────────────────────────────────────────────────────────────────────
my_memcpy:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)

    mov  rax, rdi           ; rax = dst — save for return value
    mov  rbx, rdx           ; rbx = n — total byte count

    ; Fast path: copy 8 bytes at a time
    ; How many full 8-byte chunks? rbx / 8
    mov  rcx, rbx           ; rcx = n
    shr  rcx, 3             ; rcx = n / 8 (number of qword chunks; right-shift by 3 = divide by 8)
    jz   .mc_tail           ; if no full chunks, go directly to byte-by-byte tail

.mc_qword:
    mov  r8, [rsi]          ; r8 = 8 bytes from source (load 64-bit quadword)
    mov  [rdi], r8          ; store 8 bytes to destination
    add  rdi, 8             ; advance destination pointer by 8 bytes
    add  rsi, 8             ; advance source pointer by 8 bytes
    dec  rcx                ; decrement chunk counter
    jnz  .mc_qword          ; if more chunks remain, continue

.mc_tail:
    ; Handle remaining 0-7 bytes
    mov  rcx, rbx           ; rcx = n
    and  rcx, 7             ; rcx = n % 8 — number of leftover bytes (AND with 7 = mod 8)
    jz   .mc_done           ; if no leftover bytes, we're done

.mc_byte:
    mov  r8b, [rsi]         ; r8b = 1 byte from source (byte-sized register)
    mov  [rdi], r8b         ; store 1 byte to destination
    inc  rdi                ; advance destination by 1
    inc  rsi                ; advance source by 1
    dec  rcx                ; decrement remaining byte counter
    jnz  .mc_byte           ; if more bytes remain, continue

.mc_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = original dst pointer

; ───────────────────────────────────────────────────────────────────────────
; Helper: print_cstr — write null-terminated string to stdout
;   Input: rdi = string pointer
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    call my_strlen          ; rax = length (uses rdi — that's why we saved it)
    mov  rdx, rax           ; rdx = length (write arg 3)

    pop  rsi                ; rsi = string pointer (restored; write arg 2)
    mov  rdi, 1             ; rdi = 1 — stdout (write arg 1)
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write(1, str, len)

    pop  rbp                ; restore caller's frame pointer
    ret

; print_i64 — print a signed 64-bit integer without newline
;   Input: rdi = number
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)
    push r13                ; save r13 — sign flag (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    xor  r13, r13           ; r13 = 0 — positive

    test rdi, rdi           ; negative?
    jns  .p64p              ; no
    neg  rdi                ; flip sign
    mov  r13, 1             ; set sign flag

.p64p:
    mov  rax, rdi           ; rax = magnitude
    test rax, rax
    jnz  .p64d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .p64s

.p64d:
    xor  rdx, rdx           ; rdx = 0 — high half for division
    mov  rcx, 10            ; rcx = divisor
    div  rcx                ; rax = quotient, rdx = remainder
    add  dl, '0'            ; to ASCII
    mov  [rbx], dl          ; store
    inc  rbx
    test rax, rax
    jnz  .p64d

.p64s:
    test r13, r13
    jz   .p64t
    mov  byte [rbx], '-'
    inc  rbx

.p64t:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]     ; last char
    mov  rsi, r12           ; first char
.p64r:
    cmp  rsi, rdi
    jge  .p64w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .p64r

.p64w:
    mov  rsi, r12           ; string start
    mov  rdx, rbx           ; end
    sub  rdx, r12           ; length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: test each string utility function
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── strlen tests ──

    ; strlen("Hello") should be 5
    mov  rdi, lbl_slen      ; "strlen('Hello')   = "
    call print_cstr

    mov  rdi, s_hello       ; rdi = "Hello"
    call my_strlen          ; rax = 5
    mov  rdi, rax           ; rdi = 5
    call print_i64          ; print 5

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; strlen("") should be 0
    mov  rdi, lbl_slen2     ; "strlen('')        = "
    call print_cstr

    mov  rdi, s_empty       ; rdi = ""
    call my_strlen          ; rax = 0
    mov  rdi, rax
    call print_i64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── strcmp tests ──

    ; strcmp("abc", "abc") should be 0
    mov  rdi, lbl_cmp1      ; "strcmp(abc,abc)   = "
    call print_cstr

    mov  rdi, s_abc         ; s1 = "abc"
    mov  rsi, s_abc         ; s2 = "abc"
    call my_strcmp          ; rax = 0
    mov  rdi, rax
    call print_i64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; strcmp("abc", "abd") should be < 0  ('c' - 'd' = -1)
    mov  rdi, lbl_cmp2      ; "strcmp(abc,abd)   = "
    call print_cstr

    mov  rdi, s_abc         ; s1 = "abc"
    mov  rsi, s_abd         ; s2 = "abd"
    call my_strcmp          ; rax = 'c' - 'd' = -1
    mov  rdi, rax
    call print_i64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; strcmp("abd", "abc") should be > 0
    mov  rdi, lbl_cmp3      ; "strcmp(abd,abc)   = "
    call print_cstr

    mov  rdi, s_abd         ; s1 = "abd"
    mov  rsi, s_abc         ; s2 = "abc"
    call my_strcmp          ; rax = 'd' - 'c' = 1
    mov  rdi, rax
    call print_i64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── memcpy test ──

    ; Copy "ABCDEFGHIJ\0" into dst_buf
    mov  rdi, dst_buf       ; rdi = destination
    mov  rsi, src_buf       ; rsi = source
    mov  rdx, 11            ; rdx = 10 bytes of data + 1 null terminator
    call my_memcpy          ; rax = dst_buf

    ; Print "memcpy result     = " then the content of dst_buf
    mov  rdi, lbl_cpy       ; label
    call print_cstr

    mov  rdi, dst_buf       ; rdi = copied string
    call print_cstr         ; print it

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)
