; =============================================================================
; reverse_utf8.asm — Reverse a UTF-8 encoded string (codepoint-aware)
;
; Description:
;   Reads a UTF-8 string (no spaces, input via scanf %s) and prints it
;   with the codepoint order reversed.  Multi-byte sequences are kept
;   intact — only the order of codepoints is reversed, not individual bytes.
;
;   UTF-8 byte layout:
;     1 byte : 0xxxxxxx                              U+0000..U+007F
;     2 bytes: 110xxxxx 10xxxxxx                     U+0080..U+07FF
;     3 bytes: 1110xxxx 10xxxxxx 10xxxxxx            U+0800..U+FFFF
;     4 bytes: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx   U+10000..U+10FFFF
;
;   Algorithm (two passes):
;     Pass 1 — scan forward: for each leading byte record its byte offset
;              and codepoint byte-length in a stack table.
;     Pass 2 — iterate the table in reverse: copy each codepoint's bytes
;              to the output buffer.
;
; Concepts:
;   • UTF-8 leading-byte detection using bit masks (AND + CMP)
;   • Two-pointer stack arrays for both the codepoint table and output
;   • No heap allocation — all buffers live on the stack
;
; Build:
;   nasm -f elf64 reverse_utf8.asm -o obj/reverse_utf8.o
;   gcc   obj/reverse_utf8.o -o bin/reverse_utf8 -no-pie
;
; Run:
;   ./bin/reverse_utf8
; =============================================================================

global main
extern printf, scanf

section .data

    prompt      db "Enter a UTF-8 string (no spaces): ", 0
    fmt_in      db "%255s", 0      ; read word, max 255 chars
    fmt_out     db "Reversed: %s", 10, 0

section .text

; ── codepoint_len ─────────────────────────────────────────────────────────────
; Given a UTF-8 leading byte in dil, return its codepoint byte length in rax.
; Continuation bytes (10xxxxxx) should not be passed here; returns 1 as fallback.
; Args   : dil = leading byte
; Returns: rax = 1, 2, 3, or 4
; ──────────────────────────────────────────────────────────────────────────────
codepoint_len:
    movzx   rax, dil            ; zero-extend leading byte into rax

    ; Check bit 7: if 0xxxxxxx → 1-byte (ASCII)
    test    al, 0x80            ; AND with 1000_0000
    jz      .len1               ; top bit is 0 → single-byte codepoint

    ; Check top 3 bits: 110xxxxx → 2-byte
    mov     ecx, eax
    and     ecx, 0xE0           ; keep top 3 bits
    cmp     ecx, 0xC0           ; 110_00000 ?
    je      .len2

    ; Check top 4 bits: 1110xxxx → 3-byte
    mov     ecx, eax
    and     ecx, 0xF0           ; keep top 4 bits
    cmp     ecx, 0xE0           ; 1110_0000 ?
    je      .len3

    ; Otherwise: 11110xxx → 4-byte
    mov     rax, 4
    ret

.len1:
    mov     rax, 1
    ret

.len2:
    mov     rax, 2
    ret

.len3:
    mov     rax, 3
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout (offsets from rbp, growing downward):
;   [rbp -  256]        input buffer   (256 bytes)
;   [rbp -  512]        output buffer  (256 bytes)
;   [rbp -  512 - i*16] codepoint table (up to 128 entries × 16 bytes each)
;                        entry layout: [0..7] = byte offset, [8..15] = byte len
;   128 entries × 16 = 2048 bytes
;   Total: 256 + 256 + 2048 = 2560 → pad to 2576 (2576 / 16 = 161 ✓)
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 2576

    ; ── Prompt and read input string ──────────────────────────────────────────
    lea     rdi, [rel prompt]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_in]
    lea     rsi, [rbp - 256]    ; rsi = input buffer
    xor     eax, eax
    call    scanf

    ; ── Pass 1: walk input, record codepoints in the stack table ──────────────
    ; r12 = byte pointer into input (walks forward)
    ; r13 = codepoint count (number of entries recorded)
    ; r14 = base address of codepoint table (first entry lives below rbp-512)
    lea     r12, [rbp - 256]    ; r12 = &input[0]
    xor     r13, r13            ; codepoint count = 0
    lea     r14, [rbp - 512]    ; r14 = table base (entries stored at r14 - (i+1)*16)

.scan_loop:
    movzx   rax, byte [r12]     ; rax = byte at current read position
    test    rax, rax            ; null terminator?
    jz      .scan_done          ; yes → finished scanning

    ; Skip continuation bytes: top two bits == 10 means 10xxxxxx
    mov     rcx, rax
    and     rcx, 0xC0           ; keep top 2 bits
    cmp     rcx, 0x80           ; is it a continuation byte?
    je      .advance            ; yes → skip; it belongs to the previous codepoint

    ; Leading byte found — measure this codepoint's length
    movzx   rdi, al             ; rdi = leading byte (argument to codepoint_len)
    call    codepoint_len       ; rax = byte length (1–4)

    ; Store table[r13] = { offset = r12 - &input[0],  len = rax }
    mov     rcx, r13
    imul    rcx, 16             ; rcx = r13 * 16 (byte index into table)
    add     rcx, 16             ; +16: entry 0 lives at r14 - 16, entry 1 at r14 - 32, …

    ; Compute byte offset of current codepoint from start of input
    lea     rdx, [rbp - 256]    ; rdx = &input[0]
    mov     r8, r12
    sub     r8, rdx             ; r8 = r12 - &input[0] = byte offset

    mov     [r14 - rcx],     r8   ; table[r13].offset = r8
    mov     [r14 - rcx + 8], rax  ; table[r13].len    = byte length

    inc     r13                 ; one more codepoint recorded

.advance:
    inc     r12                 ; move to next byte
    jmp     .scan_loop

.scan_done:
    ; r13 now holds total number of codepoints in the input.

    ; ── Pass 2: write codepoints to output in reverse order ───────────────────
    ; r15 = write pointer into output buffer
    ; r12 = codepoint index (starts at r13-1, counts down to 0)
    lea     r15, [rbp - 512]    ; r15 = &output[0]
    mov     r12, r13
    dec     r12                 ; r12 = index of last codepoint

.emit_loop:
    test    r12, r12            ; r12 < 0 → done
    js      .emit_done

    ; Load table entry r12
    mov     rcx, r12
    imul    rcx, 16
    add     rcx, 16             ; rcx = byte index of entry r12

    mov     rdx, [r14 - rcx]    ; rdx = byte offset of this codepoint
    mov     r8,  [r14 - rcx + 8] ; r8  = byte length of this codepoint

    ; Copy r8 bytes from &input[rdx] → output
    lea     rsi, [rbp - 256]
    add     rsi, rdx            ; rsi = &input[offset]
    mov     rcx, r8             ; rcx = byte count

.byte_copy:
    test    rcx, rcx
    jz      .byte_copy_done
    mov     al, [rsi]           ; al = one byte of this codepoint
    mov     [r15], al           ; write to output
    inc     rsi                 ; advance source
    inc     r15                 ; advance destination
    dec     rcx                 ; one less byte to copy
    jmp     .byte_copy

.byte_copy_done:
    dec     r12                 ; move to previous codepoint
    jmp     .emit_loop

.emit_done:
    mov     byte [r15], 0       ; null-terminate the output buffer

    ; ── Print result ──────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_out]
    lea     rsi, [rbp - 512]    ; rsi = output buffer
    xor     eax, eax
    call    printf

    xor     eax, eax
    leave
    ret
