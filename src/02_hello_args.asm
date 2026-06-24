;═══════════════════════════════════════════════════════════════════════════════
; §01  Hello Args
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 01_hello_args.asm
;  Description : Print argv[1] — syscall ABI and stack layout at _start
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 01_hello_args.asm — Print argv[1] to stdout using only Linux syscalls
; Goal: understand the syscall ABI and how the kernel sets up the stack
;
; How the stack looks at program entry (_start):
;
;   rsp + 0   → argc         (number of arguments, including program name)
;   rsp + 8   → argv[0]      (pointer to program name string, e.g. "./hello_args")
;   rsp + 16  → argv[1]      (pointer to first user argument)
;   rsp + 24  → argv[2]      (pointer to second user argument, if any)
;   ...
;   rsp + 8*(argc+1) → NULL  (end of argv array)
;
; Linux x86-64 syscall calling convention:
;   rax = syscall number  (see /usr/include/asm/unistd_64.h)
;   rdi = 1st argument
;   rsi = 2nd argument
;   rdx = 3rd argument
;   r10 = 4th argument   (note: NOT rcx like in user-space function calls!)
;   r8  = 5th argument
;   r9  = 6th argument
;   Result comes back in rax
;   The 'syscall' instruction switches to kernel mode
;
; Syscall numbers used here:
;   1  = write(fd, buf, count)  — write bytes to a file descriptor
;   60 = exit(code)             — terminate the process
;
; Build:
;   nasm -f elf64 02_hello_args.asm -o bin/02_hello_args.o
;   ld bin/02_hello_args.o -o bin/02_hello_args
; Run:
;   ./bin/02_hello_args World
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    usage_msg  db "Usage: ./01_hello_args <word>", 10   ; message string with newline (ASCII 10)
    usage_len  equ $ - usage_msg                         ; $ = current address; subtract start to get length
    newline    db 10                                      ; just a newline character on its own

section .text
global _start               ; tell the linker that _start is our entry point

; ───────────────────────────────────────────────────────────────────────────
; str_len — count bytes in a null-terminated string
;   Input:  rdi = pointer to the first character of the string
;   Output: rax = number of bytes before the null terminator
;   Clobbers: rcx (used as loop counter — not preserved)
; ───────────────────────────────────────────────────────────────────────────
str_len:
    push rbp                ; save the caller's base pointer on the stack (callee must preserve rbp)
    mov  rbp, rsp           ; set our own base pointer = current stack pointer (establishes frame)
    xor  rcx, rcx           ; rcx = 0 — zero out our character counter (XOR with self is fastest zero)
.scan_loop:
    cmp  byte [rdi + rcx], 0   ; read one byte at address (rdi + rcx); compare with 0 (null terminator)
    je   .scan_done            ; if zero, the string ended — jump to done
    inc  rcx                   ; byte was not null, advance index by 1
    jmp  .scan_loop            ; go back and check the next byte
.scan_done:
    mov  rax, rcx           ; rax = final count — move result to the return-value register
    pop  rbp                ; restore the caller's base pointer (callee convention)
    ret                     ; return to caller; rax holds the string length

; ───────────────────────────────────────────────────────────────────────────
; sys_write — write bytes to a file descriptor using the write syscall
;   Input:  rdi = file descriptor (1 = stdout, 2 = stderr)
;           rsi = pointer to data buffer
;           rdx = number of bytes to write
;   Output: rax = number of bytes actually written (or negative error code)
; ───────────────────────────────────────────────────────────────────────────
sys_write:
    push rbp                ; save the caller's base pointer on the stack (callee must preserve rbp)
    mov  rbp, rsp           ; set our own base pointer = current stack pointer
    mov  rax, 1             ; rax = 1 — this is syscall number 1 (write)
    syscall                 ; transfer control to the kernel; args already in rdi, rsi, rdx
    pop  rbp                ; restore the caller's base pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_str — print a null-terminated string to stdout
;   Input:  rdi = pointer to null-terminated string
; ───────────────────────────────────────────────────────────────────────────
print_str:
    push rbp                ; save the caller's base pointer on the stack (callee must preserve rbp)
    mov  rbp, rsp           ; set our own base pointer = current stack pointer
    push rdi                ; save string pointer on stack (rdi will be overwritten by str_len return)

    call str_len            ; rax = length of string at [rdi]

    pop  rsi                ; rsi = the string pointer we saved earlier (syscall arg 2 = buffer)
    mov  rdx, rax           ; rdx = length returned by str_len (syscall arg 3 = byte count)
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor (syscall arg 1 = fd)
    call sys_write          ; write(1, string_ptr, length)

    pop  rbp                ; restore the caller's base pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_newline — write a single newline character to stdout
; ───────────────────────────────────────────────────────────────────────────
print_newline:
    push rbp                ; save the caller's base pointer on the stack (callee must preserve rbp)
    mov  rbp, rsp           ; set our own base pointer = current stack pointer
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor
    mov  rsi, newline       ; rsi = address of our newline byte in .data
    mov  rdx, 1             ; rdx = 1 byte to write
    call sys_write          ; write(1, &newline, 1)
    pop  rbp                ; restore the caller's base pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; sys_exit — terminate the process
;   Input:  rdi = exit status code (0 = success, non-zero = error)
; ───────────────────────────────────────────────────────────────────────────
sys_exit:
    mov  rax, 60            ; rax = 60 — syscall number for exit()
    syscall                 ; transfer to kernel; rdi already holds the exit code
    ; execution never reaches here after exit syscall

; ───────────────────────────────────────────────────────────────────────────
; _start — the kernel jumps here when the process begins
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Step 1: Read argc from the top of the stack
    mov  rax, [rsp]         ; rax = argc — at entry, rsp points to argc (an 8-byte integer on the stack)

    ; Step 2: Check if the user provided an argument
    cmp  rax, 2             ; compare argc with 2 (program_name + one_argument = 2)
    jl   .missing_arg       ; if argc < 2, user didn't supply argv[1] — show usage

    ; Step 3: Load argv[1] — the first user-supplied argument
    mov  rdi, [rsp + 16]    ; rdi = argv[1] — pointer to string at stack offset 16 (after argc and argv[0])

    ; Step 4: Print argv[1]
    call print_str          ; print the string pointed to by rdi

    ; Step 5: Print a newline so the terminal prompt appears on a new line
    call print_newline      ; write '\n' to stdout

    ; Step 6: Exit successfully
    mov  rdi, 0             ; rdi = 0 — exit code 0 means success
    call sys_exit           ; exit(0)

.missing_arg:
    ; User forgot to pass an argument — print the usage hint
    mov  rdi, 1             ; rdi = 1 — stderr... we'll use stdout for simplicity
    mov  rsi, usage_msg     ; rsi = pointer to our usage message string
    mov  rdx, usage_len     ; rdx = precomputed length of that message
    call sys_write          ; write(1, usage_msg, usage_len)

    mov  rdi, 1             ; rdi = 1 — exit code 1 indicates an error
    call sys_exit           ; exit(1)
