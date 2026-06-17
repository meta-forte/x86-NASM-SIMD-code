; =============================================================================
; hello_world.asm — Print "Hello, World!" to the terminal
;
; Description:
;   The simplest possible program.  Calls the C library printf to write the
;   classic greeting string to standard output.
;
; Concepts:
;   • global main / extern printf  — linking with the C runtime
;   • section .data               — read-only string constant
;   • lea rdi, [rel ...]          — RIP-relative address of the format string
;   • call printf                 — C library call using the System V AMD64 ABI
;
; Build:
;   nasm -f elf64 hello_world.asm -o obj/hello_world.o
;   gcc   obj/hello_world.o -o bin/hello_world -no-pie
;
; Run:
;   ./bin/hello_world
; =============================================================================

global main             ; export 'main' so the C runtime can call it
extern printf           ; use the C library printf for output

; -----------------------------------------------------------------------------
; SECTION .data — initialised, read-only string constants
; -----------------------------------------------------------------------------
section .data

    msg db "Hello, World!", 10, 0
    ; The greeting string.
    ; 10 = ASCII newline (\n).  0 = null terminator required by printf.
    ; In C: const char msg[] = "Hello, World!\n";

; -----------------------------------------------------------------------------
; SECTION .text — executable code
; -----------------------------------------------------------------------------
section .text

; ── print_str ─────────────────────────────────────────────────────────────────
; Purpose : Print a null-terminated string via printf.
; Args    : rdi = pointer to the string
; Clobbers: rax (variadic arg count), caller-saved regs
; ──────────────────────────────────────────────────────────────────────────────
print_str:
    push    rbp                 ; save caller's frame pointer
    mov     rbp, rsp            ; establish our stack frame
    ; rdi already holds the format string pointer — pass it straight to printf
    xor     eax, eax            ; eax = 0: no floating-point arguments (required for variadic calls)
    call    printf              ; printf(rdi) — writes the string to stdout
    pop     rbp                 ; restore caller's frame pointer
    ret                         ; return to caller

; ── main ──────────────────────────────────────────────────────────────────────
main:
    push    rbp                 ; align stack: (ret addr 8) + (rbp 8) = 16 bytes ✓
    mov     rbp, rsp            ; mark the base of our stack frame

    lea     rdi, [rel msg]      ; rdi = address of "Hello, World!\n\0"
    call    print_str           ; print the greeting

    xor     eax, eax            ; return value 0 (success)
    pop     rbp                 ; restore caller's rbp
    ret                         ; return to C runtime — process exits cleanly
