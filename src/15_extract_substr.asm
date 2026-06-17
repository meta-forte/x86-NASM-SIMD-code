; =============================================================================
; extract_substr.asm — Extract a substring from a string
;
; Description:
;   Reads a string (up to 255 chars), a start index, and a length, then
;   prints the extracted substring.
;
;   Example:
;       Input string : "HelloWorld"
;       Start        : 5
;       Length       : 5
;       Output       : "World"
;
; Concepts:
;   • Byte-by-byte copy loop using MOVSB idiom with registers
;   • Stack buffers for both input and output strings (no .bss)
;   • Bounds checking: clamp length to available characters
;
; Build:
;   nasm -f elf64 extract_substr.asm -o obj/extract_substr.o
;   gcc   obj/extract_substr.o -o bin/extract_substr -no-pie
;
; Run:
;   ./bin/extract_substr
; =============================================================================

global main
extern printf, scanf, strlen

section .data

    prompt_str   db "Enter a string (no spaces): ", 0
    prompt_start db "Start index (0-based): ", 0
    prompt_len   db "Length: ", 0
    fmt_str_in   db "%255s", 0          ; scanf: read a word (no spaces), max 255 chars
    fmt_int      db "%ld", 0
    fmt_out      db "Substring: \"%s\"", 10, 0
    msg_bounds   db "Error: start index or length out of bounds.", 10, 0

section .text

; ── read_string ───────────────────────────────────────────────────────────────
; Read a word (no spaces) into the buffer at rsi, max 255 bytes.
; Args: rdi = format string ("%255s"), rsi = destination buffer
; ──────────────────────────────────────────────────────────────────────────────
read_string:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── read_int ──────────────────────────────────────────────────────────────────
read_int:
    push    rbp
    mov     rbp, rsp
    xor     eax, eax
    call    scanf
    pop     rbp
    ret

; ── main ──────────────────────────────────────────────────────────────────────
; Stack layout  (all relative to rbp):
;   [rbp - 256]     = input string buffer  (256 bytes, indices -1 to -256)
;   [rbp - 264]     = start (int64)
;   [rbp - 272]     = length (int64)
;   [rbp - 528]     = output buffer (256 bytes)
; Total reserved: 528 bytes → round to 544 for 16-byte alignment.
;   (ret 8) + (rbp 8) + (sub 544) = 560. 560/16 = 35. ✓
; ──────────────────────────────────────────────────────────────────────────────
main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 544

    ; ── Read input string ─────────────────────────────────────────────────────
    lea     rdi, [rel prompt_str]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_str_in]
    lea     rsi, [rbp - 256]        ; rsi = &input_buf[0]
    call    read_string

    ; ── Read start index ──────────────────────────────────────────────────────
    lea     rdi, [rel prompt_start]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_int]
    lea     rsi, [rbp - 264]        ; &start
    call    read_int

    ; ── Read length ───────────────────────────────────────────────────────────
    lea     rdi, [rel prompt_len]
    xor     eax, eax
    call    printf

    lea     rdi, [rel fmt_int]
    lea     rsi, [rbp - 272]        ; &length
    call    read_int

    ; ── Get actual string length ───────────────────────────────────────────────
    lea     rdi, [rbp - 256]        ; rdi = &input_buf
    call    strlen                  ; rax = strlen(input_buf)
    mov     r12, rax                ; r12 = string length (callee-saved)

    ; ── Bounds check ──────────────────────────────────────────────────────────
    mov     r13, [rbp - 264]        ; r13 = start
    mov     r14, [rbp - 272]        ; r14 = length

    ; start must be >= 0 and < string length
    test    r13, r13
    js      .bounds_error           ; start < 0
    cmp     r13, r12
    jge     .bounds_error           ; start >= strlen

    ; length must be >= 1
    test    r14, r14
    jle     .bounds_error

    ; clamp length so we don't read past end of string: length = min(length, strlen - start)
    mov     rax, r12
    sub     rax, r13                ; rax = strlen - start  (available chars)
    cmp     r14, rax
    jle     .copy                   ; length <= available → OK as-is
    mov     r14, rax                ; clamp: length = strlen - start

.copy:
    ; ── Copy input_buf[start .. start+length-1] to output_buf ────────────────
    lea     rsi, [rbp - 256]        ; rsi = base of input_buf
    add     rsi, r13                ; rsi = &input_buf[start]

    lea     rdi, [rbp - 528]        ; rdi = &output_buf[0]

    mov     rcx, r14                ; rcx = number of bytes to copy

.copy_loop:
    test    rcx, rcx                ; rcx == 0?
    jz      .copy_done
    mov     al, [rsi]               ; al = one byte from source
    mov     [rdi], al               ; write it to destination
    inc     rsi                     ; advance source pointer
    inc     rdi                     ; advance destination pointer
    dec     rcx                     ; one fewer byte remaining
    jmp     .copy_loop

.copy_done:
    mov     byte [rdi], 0           ; null-terminate the output buffer

    ; ── Print result ──────────────────────────────────────────────────────────
    lea     rdi, [rel fmt_out]
    lea     rsi, [rbp - 528]        ; rsi = output_buf
    xor     eax, eax
    call    printf
    jmp     .exit

.bounds_error:
    lea     rdi, [rel msg_bounds]
    xor     eax, eax
    call    printf

.exit:
    xor     eax, eax
    leave
    ret
