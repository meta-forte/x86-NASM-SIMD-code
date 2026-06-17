;═══════════════════════════════════════════════════════════════════════════════
; §19  Substring Search
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 19_substring_search.asm
;  Description : Naive O(nm) search and KMP O(n+m) with failure table
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 19_substring_search.asm — Naive strstr + Knuth-Morris-Pratt (KMP) algorithm
; Goal: state machine implementation, failure table, pointer arithmetic
;
; NAIVE ALGORITHM:
;   Try aligning the pattern at each position in the haystack.
;   At each position, compare character by character.
;   Time complexity: O(n * m) worst case (n = haystack length, m = pattern length)
;
; KMP ALGORITHM (Knuth-Morris-Pratt):
;   Precomputes a "failure function" (also called "partial match table").
;   When a mismatch occurs, instead of restarting from the beginning of the pattern,
;   the failure function tells us how far back to jump in the pattern.
;   Time complexity: O(n + m) — never re-examines characters in the haystack
;
;   The failure table fail[i] = length of the longest proper prefix of pattern[0..i]
;   that is also a suffix of pattern[0..i].
;   Example: pattern = "ABCABD"
;     fail[0] = 0 (no proper prefix)
;     fail[1] = 0 ("B" has no prefix that's also a suffix)
;     fail[2] = 0 ("C" same)
;     fail[3] = 1 ("A" is a prefix and suffix of "ABCA")
;     fail[4] = 2 ("AB" is both prefix and suffix of "ABCAB")
;     fail[5] = 0 ("D" doesn't match "A")
;
; Build:
;   nasm -f elf64 19_substring_search.asm -o bin/19_substring_search.o
;   ld bin/19_substring_search.o -o bin/19_substring_search
; Run:
;   ./bin/19_substring_search
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    haystack  db "AABAACAADAABAABAABAAB", 0
    pattern   db "AABAA", 0

    lbl_hay   db "Haystack: ", 0
    lbl_pat   db "Pattern:  ", 0
    lbl_naive db "Naive  found at index: ", 0
    lbl_kmp   db "KMP    found at index: ", 0
    lbl_none  db "(not found)", 10, 0
    newline   db 10

section .bss
    fail_table  resq 256    ; failure table for KMP (up to 256 chars pattern length)
    num_buf     resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; str_len_local — length of null-terminated string
;   Input:  rdi = string pointer
;   Output: rax = length
; ───────────────────────────────────────────────────────────────────────────
str_len_local:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    xor  rax, rax           ; rax = 0 — counter
.sl:
    cmp  byte [rdi + rax], 0   ; null byte?
    je   .sl_done              ; yes
    inc  rax                   ; no
    jmp  .sl                   ; continue
.sl_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = length

; ───────────────────────────────────────────────────────────────────────────
; strstr_naive — find first occurrence of pattern in haystack (naive algorithm)
;   Input:  rdi = pointer to null-terminated haystack string
;           rsi = pointer to null-terminated pattern string
;   Output: rax = index of first match (0-based), or -1 if not found
; ───────────────────────────────────────────────────────────────────────────
strstr_naive:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 — haystack pointer (callee-saved)
    push r13                ; save r13 — pattern pointer (callee-saved)
    push r14                ; save r14 — haystack length (callee-saved)
    push r15                ; save r15 — pattern length (callee-saved)
    push rbx                ; save rbx — outer loop index i (callee-saved)

    mov  r12, rdi           ; r12 = haystack
    mov  r13, rsi           ; r13 = pattern

    ; Compute haystack length
    mov  rdi, r12
    call str_len_local      ; rax = length of haystack
    mov  r14, rax           ; r14 = n (haystack length)

    ; Compute pattern length
    mov  rdi, r13
    call str_len_local      ; rax = length of pattern
    mov  r15, rax           ; r15 = m (pattern length)

    ; Special case: empty pattern matches at index 0
    test r15, r15           ; m == 0?
    jz   .naive_found_zero  ; yes — return 0

    ; Try each starting position in haystack
    xor  rbx, rbx           ; rbx = i = 0 (starting position in haystack)

.naive_outer:
    ; Can pattern still fit starting at i? Need: i + m <= n
    lea  rax, [rbx + r15]   ; rax = i + m
    cmp  rax, r14           ; i + m > n? (pattern would extend past end)
    jg   .naive_not_found   ; yes — no match possible

    ; Inner loop: compare pattern[j] with haystack[i+j] for j = 0..m-1
    xor  rcx, rcx           ; rcx = j = 0 (pattern index)

.naive_inner:
    cmp  rcx, r15           ; j >= m?
    jge  .naive_match       ; yes — all m characters matched!

    lea  rax, [rbx + rcx]          ; rax = i + j (byte offset into haystack)
    mov  al, [r12 + rax]           ; al = haystack[i + j]
    cmp  al, [r13 + rcx]          ; haystack[i+j] == pattern[j]?
    jne  .naive_mismatch           ; no — mismatch

    inc  rcx                ; j++ — matched one character
    jmp  .naive_inner       ; check next character

.naive_mismatch:
    inc  rbx                ; i++ — try next starting position
    jmp  .naive_outer       ; outer loop

.naive_match:
    mov  rax, rbx           ; rax = i — return match position
    jmp  .naive_done

.naive_found_zero:
    xor  rax, rax           ; rax = 0 — empty pattern found at 0
    jmp  .naive_done

.naive_not_found:
    mov  rax, -1            ; rax = -1 — not found

.naive_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = match index or -1

; ───────────────────────────────────────────────────────────────────────────
; build_kmp_table — build the KMP failure function table
;   Input:  rdi = pointer to pattern string
;           rsi = pattern length m
;           rdx = pointer to output failure table (m int64_t entries)
;
;   fail[0] = 0 always (no proper prefix of a single character)
;   For i >= 1:
;     fail[i] = length of longest proper prefix of pattern[0..i] that is also a suffix
; ───────────────────────────────────────────────────────────────────────────
build_kmp_table:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 — pattern (callee-saved)
    push r13                ; save r13 — m (callee-saved)
    push r14                ; save r14 — table pointer (callee-saved)

    mov  r12, rdi           ; r12 = pattern
    mov  r13, rsi           ; r13 = m
    mov  r14, rdx           ; r14 = failure table

    ; fail[0] = 0
    mov  qword [r14], 0     ; fail[0] = 0

    mov  rbx, 1             ; rbx = i = 1 (position in pattern being processed)
    xor  rcx, rcx           ; rcx = k = 0 (length of current matching prefix)

.kmp_build:
    cmp  rbx, r13           ; i >= m?
    jge  .kmp_build_done    ; yes — table complete

    ; Compare pattern[i] with pattern[k]
    mov  al, [r12 + rbx]    ; al = pattern[i]
    cmp  al, [r12 + rcx]    ; pattern[i] == pattern[k]?
    je   .kmp_extend        ; yes — extend the current match

    ; Mismatch: fall back using the existing table
    test rcx, rcx           ; k == 0?
    jz   .kmp_zero          ; yes — fail[i] = 0

    ; k > 0: set k = fail[k-1] and retry (don't advance i)
    lea  rax, [rcx - 1]     ; rax = k - 1
    mov  rcx, [r14 + rax*8] ; k = fail[k-1] (look up the table we've built so far)
    jmp  .kmp_build         ; retry the comparison at i with new k

.kmp_zero:
    mov  qword [r14 + rbx*8], 0   ; fail[i] = 0
    inc  rbx                ; i++
    jmp  .kmp_build

.kmp_extend:
    inc  rcx                ; k++ — one more character matches
    mov  [r14 + rbx*8], rcx ; fail[i] = k
    inc  rbx                ; i++
    jmp  .kmp_build

.kmp_build_done:
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; fail_table now contains the failure function

; ───────────────────────────────────────────────────────────────────────────
; strstr_kmp — find first occurrence of pattern in haystack (KMP algorithm)
;   Input:  rdi = pointer to null-terminated haystack
;           rsi = pointer to null-terminated pattern
;   Output: rax = index of first match, or -1 if not found
; ───────────────────────────────────────────────────────────────────────────
strstr_kmp:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push r15                ; save r15 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = haystack
    mov  r13, rsi           ; r13 = pattern

    ; Compute lengths
    mov  rdi, r12
    call str_len_local
    mov  r14, rax           ; r14 = n (haystack length)

    mov  rdi, r13
    call str_len_local
    mov  r15, rax           ; r15 = m (pattern length)

    ; Build KMP failure table
    mov  rdi, r13           ; rdi = pattern
    mov  rsi, r15           ; rsi = m
    mov  rdx, fail_table    ; rdx = failure table output
    call build_kmp_table

    ; KMP search
    xor  rbx, rbx           ; rbx = i = 0 (haystack position)
    xor  rcx, rcx           ; rcx = j = 0 (pattern position)

.kmp_search:
    cmp  rbx, r14           ; i >= n?
    jge  .kmp_notfound      ; yes — exhausted haystack

    mov  al, [r12 + rbx]    ; al = haystack[i]
    cmp  al, [r13 + rcx]    ; haystack[i] == pattern[j]?
    je   .kmp_match_char    ; yes — characters match

    ; Mismatch
    test rcx, rcx           ; j == 0?
    jz   .kmp_advance_i     ; yes — no fallback possible, advance i

    ; Fall back: j = fail[j-1]
    lea  rax, [rcx - 1]     ; rax = j - 1
    mov  rcx, [fail_table + rax*8]  ; j = fail[j-1]
    jmp  .kmp_search        ; retry without advancing i

.kmp_advance_i:
    inc  rbx                ; i++
    jmp  .kmp_search

.kmp_match_char:
    inc  rbx                ; i++
    inc  rcx                ; j++

    cmp  rcx, r15           ; j == m? (found the full pattern)
    jl   .kmp_search        ; no — keep going

    ; Match found! Position in haystack = i - m = rbx - r15
    mov  rax, rbx           ; rax = i (current position, one past last match char)
    sub  rax, r15           ; rax = i - m = start of match
    jmp  .kmp_done

.kmp_notfound:
    mov  rax, -1            ; not found

.kmp_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = match index or -1

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pcs:
    cmp  byte [rdi+rcx], 0
    je   .pcsw
    inc  rcx
    jmp  .pcs
.pcsw:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13, r13

    test rdi, rdi
    jns  .pi_pos
    neg  rdi
    mov  r13, 1

.pi_pos:
    mov  rax, rdi
    test rax, rax
    jnz  .pi_dig
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pi_sign

.pi_dig:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pi_dig

.pi_sign:
    test r13, r13
    jz   .pi_term
    mov  byte [rbx], '-'
    inc  rbx

.pi_term:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pi_rev:
    cmp  rsi, rdi
    jge  .pi_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pi_rev

.pi_wr:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r13
    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print haystack and pattern
    mov  rdi, lbl_hay       ; "Haystack: "
    call print_cstr
    mov  rdi, haystack
    call print_cstr
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    mov  rdi, lbl_pat       ; "Pattern:  "
    call print_cstr
    mov  rdi, pattern
    call print_cstr
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Naive search
    mov  rdi, lbl_naive     ; "Naive  found at index: "
    call print_cstr

    mov  rdi, haystack
    mov  rsi, pattern
    call strstr_naive       ; rax = index or -1

    cmp  rax, -1
    je   .naive_none
    mov  rdi, rax
    call print_i64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
    jmp  .do_kmp

.naive_none:
    mov  rdi, lbl_none      ; "(not found)\n"
    call print_cstr

.do_kmp:
    ; KMP search
    mov  rdi, lbl_kmp       ; "KMP    found at index: "
    call print_cstr

    mov  rdi, haystack
    mov  rsi, pattern
    call strstr_kmp         ; rax = index or -1

    cmp  rax, -1
    je   .kmp_none
    mov  rdi, rax
    call print_i64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
    jmp  .exit

.kmp_none:
    mov  rdi, lbl_none
    call print_cstr

.exit:
    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall
