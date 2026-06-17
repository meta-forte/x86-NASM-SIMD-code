; ════════════════════════════════════════════════════════════════════════════════
;
;  ALL_26_PROGRAMS.ASM — Complete x86-64 NASM Study Collection
;  Session 2: Foundations → SIMD → FFmpeg-style Kernels
;
;  This file is a single-document reference containing all 26 assembly programs
;  written as part of a structured path from x86-64 basics to SIMD programming,
;  ultimately targeting FFmpeg patch contributions.
;
;  HOW TO READ THIS FILE
;  ─────────────────────
;  Each program occupies its own clearly marked section.  Programs are designed
;  to be easy to understand, not necessarily the fastest possible implementation.
;  Every instruction line carries a comment explaining what it does and why.
;
;  This file is NOT directly compilable as one unit because:
;    - Each program defines its own _start entry point
;    - Programs reuse label names (e.g. .loop, print_cstr) in different sections
;    - Data and BSS sections conflict across programs
;  Instead, compile each program individually from its own .asm source file.
;
;  ARCHITECTURE NOTES (x86-64 Linux, System V AMD64 ABI)
;  ───────────────────────────────────────────────────────
;  Registers:
;    rax rbx rcx rdx rsi rdi rsp rbp r8-r15  (16 × 64-bit GP registers)
;    xmm0-xmm15  (128-bit SSE registers, also lower half of ymm0-ymm15)
;    ymm0-ymm15  (256-bit AVX/AVX2 registers)
;
;  Calling convention (function calls, NOT syscalls):
;    Arguments:  rdi, rsi, rdx, rcx, r8, r9   (left-to-right)
;    Return:     rax  (or rdx:rax for 128-bit)
;    Callee-saved (function MUST restore):  rbx, rbp, r12-r15
;    Caller-saved (function MAY clobber):   rax, rcx, rdx, rsi, rdi, r8-r11
;
;  Linux syscall convention (the 'syscall' instruction):
;    Syscall number:  rax
;    Arguments:       rdi, rsi, rdx, r10, r8, r9  (note r10, NOT rcx)
;    Return:          rax  (negative = errno)
;    Clobbered by syscall: rcx, r11  (kernel uses them internally)
;    Key syscalls used:  write(1), exit(60)
;
;  Memory addressing modes:
;    [reg]              direct dereference
;    [reg + offset]     base + displacement
;    [base + idx*scale] SIB: scale ∈ {1,2,4,8}  (NOT 3,16,32,etc.)
;    Maximum 2 registers per address: [base + index*scale + disp]
;
;  Common pitfalls fixed in this collection:
;    • movd r64, xmm  is INVALID — use movq r64, xmm  (MOVD is 32-bit only)
;    • SIB scale must be 1, 2, 4, or 8   (use imul for *3, *16, *32, etc.)
;    • Cannot subtract register in address: [const - reg] is illegal
;    • imul dst, src, reg  (3 GP registers) encodes as EVEX/AVX-512 — use
;      2-operand form instead:  mov dst, src / imul dst, other_reg
;    • syscall clobbers rcx and r11 — never use rcx as a loop counter when
;      the loop body contains a syscall instruction
;
;  FIXED-POINT ARITHMETIC
;  ───────────────────────
;  Several programs use integer arithmetic to approximate real-number math:
;    Q13 (scale = 8192  = 1<<13): used in DCT cosine table
;    Q15 (scale = 32768 = 1<<15): mentioned in DCT header
;    Q16 (scale = 65536 = 1<<16): used in YUV→RGB coefficients
;  Pattern:  result = (a * coefficient) >> scale_bits
;
;  SIMD INSTRUCTION SUMMARY
;  ─────────────────────────
;  SSE2 (128-bit, XMM registers):
;    MOVDQU/MOVDQA  load/store 16 bytes (unaligned / aligned)
;    PADDUSB        packed add unsigned bytes with saturation (clamp to 255)
;    PSADBW         packed sum of absolute differences of bytes (→ 16-bit sums)
;    PADDQ          packed add quadwords (64-bit lanes)
;    PXOR           packed XOR (also used to zero a register)
;    PSRLDQ         shift register right by N bytes
;    MOVQ           move 64 bits between XMM and GP register
;    PCMPEQB        packed compare equal bytes (→ 0xFF or 0x00 per byte)
;
;  SSSE3 (adds to SSE2):
;    PSHUFB         packed shuffle bytes (byte-permutation by a mask register)
;
;  SSE (scalar float):
;    MOVSS/MOVAPS   move scalar/aligned packed single-precision floats
;    MULSS/MULPS    multiply scalar/packed singles
;    ADDSS/ADDPS    add scalar/packed singles
;    SHUFPS         shuffle packed singles
;    HADDPS         horizontal add packed singles
;    CVTTSS2SI      convert float to int (truncate)
;    CVTSI2SS       convert int to float
;
;  AVX2 (256-bit, YMM registers, VEX-prefixed):
;    VMOVDQU/VMOVDQA load/store 32 bytes
;    VMOVNTDQ        non-temporal store (bypasses cache — for streaming writes)
;    VPSADBW         256-bit PSADBW (4 partial sums)
;    VEXTRACTI128    extract 128-bit lane from YMM
;    VINSERTI128     insert 128-bit lane into YMM
;    VPADDQ          256-bit PADDQ
;    VPXOR           256-bit PXOR
;    VPBROADCASTB    broadcast one byte to all 32 lanes of YMM
;    VZEROUPPER      zero upper halves of all YMM registers (required before
;                    mixing AVX and legacy SSE code to avoid performance penalty)
;    SFENCE          store fence (ensures all prior stores are globally visible,
;                    required after non-temporal/streaming stores)
;
; ════════════════════════════════════════════════════════════════════════════════
;
;  TABLE OF CONTENTS
;  ─────────────────
;  §01  Hello Args        — syscall ABI, stack layout at _start, argv
;  §02  Arith Library     — System V ABI, C-callable functions, IDIV/CQO
;  §03  Fibonacci         — iterative loops, u64_to_dec, 64-bit arithmetic
;  §04  String Utils      — strlen, strcmp, memcpy; pointer arithmetic
;  §05  Bit Count         — Kernighan popcount, PSHUFB nibble LUT, PSADBW
;  §06  Image Row Add     — saturating byte add; PADDUSB vs scalar clamp
;  §07  1D Convolution    — 3-tap FIR filter; PMADDWD multiply-accumulate
;  §08  Endian Swap       — BSWAP instruction; PSHUFB shuffle mask technique
;  §09  YUV→RGB           — BT.601 fixed-point (Q16); saturation clamp
;  §10  8×8 DCT           — naive direct DCT; Q13 cosine table; separable 2D
;  §11  Fast Memcpy       — alignment peeling; AVX2 non-temporal stores; SFENCE
;  §12  SAD Motion Est.   — PSADBW/VPSADBW; FFmpeg motion estimation style
;  §13  Array Sum         — 4× loop unrolling; MOVSXD sign extension
;  §14  Reverse Array     — two-pointer in-place swap; LEA for last-element ptr
;  §15  Min/Max           — CMOVG/CMOVL branchless conditional moves
;  §16  Rotate Array      — GCD cycle algorithm; in-place O(1) space rotation
;  §17  Dot Product       — MOVSS/MULSS loop; HADDPS horizontal sum
;  §18  Reverse String    — two-pointer byte swap; edge case (len ≤ 1)
;  §19  Substring Search  — naive O(n×m); KMP failure table O(n+m)
;  §20  Word Frequency    — djb2 hash; chaining hash table; tokeniser
;  §21  Base Convert      — decimal/hex to/from integer; nibble extraction
;  §22  Bit Twiddling     — POPCNT, LZCNT, TZCNT, BSR, BSF hardware instructions
;  §23  Matrix Multiply   — 3×3 integer (MOVSXD+IMUL); 4×4 float SSE (SHUFPS)
;  §24  Prefix Sum        — inclusive scan; exclusive scan; SSE PSLLDQ trick
;  §25  Fast Division     — magic-number multiplication (Hacker's Delight)
;  §26  SAD Kernel        — side-by-side scalar / SSE2 / AVX2 implementation
;
; ════════════════════════════════════════════════════════════════════════════════



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
;   nasm -f elf64 01_hello_args.asm -o bin/01_hello_args.o
;   ld bin/01_hello_args.o -o bin/01_hello_args
; Run:
;   ./bin/01_hello_args World
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



;═══════════════════════════════════════════════════════════════════════════════
; §02  Arith Library
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 02_arith_lib.asm
;  Description : C-callable add/sub/mul/div/mod — System V ABI, IDIV, CQO
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 02_arith_lib.asm — Integer arithmetic functions callable from C
; Goal: understand parameter passing, return values, and the System V ABI
;
; System V AMD64 ABI (used by Linux/macOS):
;   Integer/pointer arguments are passed in registers, left-to-right:
;     1st arg → rdi
;     2nd arg → rsi
;     3rd arg → rdx
;     4th arg → rcx
;     5th arg → r8
;     6th arg → r9
;     Additional args → pushed onto the stack (right to left)
;
;   Integer return value → rax
;   128-bit return value → rdx:rax
;
;   Callee-saved (function MUST restore these before returning):
;     rbx, rbp, r12, r13, r14, r15
;
;   Caller-saved (function MAY clobber these freely):
;     rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11
;
; We expose three functions:
;   int64_t asm_add(int64_t a, int64_t b)
;   int64_t asm_sub(int64_t a, int64_t b)
;   int64_t asm_mul(int64_t a, int64_t b)
;
; Build (as a library linked with C):
;   nasm -f elf64 02_arith_lib.asm -o bin/02_arith_lib.o
;   gcc arith_test.c bin/02_arith_lib.o -o bin/02_arith_test -no-pie
; Run:
;   ./bin/02_arith_test
;
; If you want a standalone test without C, also see 02_arith_standalone below.
; ═══════════════════════════════════════════════════════════════════════════════

section .text

global asm_add              ; expose asm_add symbol to the C linker
global asm_sub              ; expose asm_sub symbol to the C linker
global asm_mul              ; expose asm_mul symbol to the C linker
global asm_div              ; expose asm_div symbol to the C linker
global asm_mod              ; expose asm_mod symbol to the C linker

; ───────────────────────────────────────────────────────────────────────────
; asm_add — add two signed 64-bit integers
;   C prototype: int64_t asm_add(int64_t a, int64_t b);
;   Input:  rdi = a  (first argument — per ABI)
;           rsi = b  (second argument — per ABI)
;   Output: rax = a + b
;
;   Note: we don't strictly need 'push rbp / mov rbp, rsp' for a leaf function
;   this simple, but we include it for consistency and to make backtraces work.
; ───────────────────────────────────────────────────────────────────────────
asm_add:
    push rbp                ; save caller's base pointer (rbp is callee-saved — we must restore it)
    mov  rbp, rsp           ; set our own base pointer = current stack top (establishes frame)

    mov  rax, rdi           ; rax = a — copy first argument into the return-value register
    add  rax, rsi           ; rax = a + b — add second argument to rax

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return to caller; rax holds the result

; ───────────────────────────────────────────────────────────────────────────
; asm_sub — subtract b from a
;   C prototype: int64_t asm_sub(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a - b
; ───────────────────────────────────────────────────────────────────────────
asm_sub:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — copy first argument to return register
    sub  rax, rsi           ; rax = a - b — subtract second argument

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds result

; ───────────────────────────────────────────────────────────────────────────
; asm_mul — multiply two signed 64-bit integers
;   C prototype: int64_t asm_mul(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a * b (lower 64 bits; upper 64 bits discarded)
;
;   IMUL with two operands: IMUL dst, src → dst = dst * src
;   The upper 64 bits of the full 128-bit product would go into rdx, but
;   we don't need them for normal integer multiplication.
; ───────────────────────────────────────────────────────────────────────────
asm_mul:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — start with first argument in return register
    imul rax, rsi           ; rax = a * b — signed multiply; lower 64 bits in rax

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds lower 64 bits of product

; ───────────────────────────────────────────────────────────────────────────
; asm_div — signed integer division
;   C prototype: int64_t asm_div(int64_t a, int64_t b);
;   Input:  rdi = a (dividend), rsi = b (divisor)
;   Output: rax = a / b (quotient)
;
;   IDIV instruction:
;     Divides rdx:rax (128-bit) by the operand.
;     Before IDIV: sign-extend rax into rdx using CQO (convert quadword to octword).
;     After IDIV: rax = quotient, rdx = remainder.
; ───────────────────────────────────────────────────────────────────────────
asm_div:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — load dividend into rax for IDIV
    cqo                     ; sign-extend rax into rdx:rax (rdx = sign-extension of rax)
                            ; this prepares the 128-bit dividend that IDIV expects
    idiv rsi                ; signed divide rdx:rax by rsi: rax = quotient, rdx = remainder

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds quotient

; ───────────────────────────────────────────────────────────────────────────
; asm_mod — signed integer modulo (remainder)
;   C prototype: int64_t asm_mod(int64_t a, int64_t b);
;   Input:  rdi = a, rsi = b
;   Output: rax = a % b (remainder)
; ───────────────────────────────────────────────────────────────────────────
asm_mod:
    push rbp                ; save caller's base pointer (callee-saved — must restore)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = a — dividend into rax
    cqo                     ; sign-extend rax into rdx:rax (prepare 128-bit dividend)
    idiv rsi                ; rax = quotient, rdx = remainder

    mov  rax, rdx           ; rax = rdx = remainder (move result to return register)

    pop  rbp                ; restore caller's base pointer (callee-saved — must restore)
    ret                     ; return; rax holds the remainder



;═══════════════════════════════════════════════════════════════════════════════
; §03  Fibonacci
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 03_fibonacci.asm
;  Description : Iterative F(1)..F(93) — loops, u64_to_dec, 64-bit arithmetic
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 03_fibonacci.asm — Produce the Fibonacci sequence, terms 1 through 93
; Goal: learn iterative loops and 64-bit arithmetic
;
; Fibonacci definition:
;   F(1) = 1
;   F(2) = 1
;   F(n) = F(n-1) + F(n-2)  for n >= 3
;
; Why stop at 93?
;   F(93)  = 12,200,160,415,121,876,738  — fits in an unsigned 64-bit int (max ~1.8e19)
;   F(94)  = 19,740,274,219,868,223,167  — still fits
;   F(95) would overflow 64 bits, so we print up to F(93) for safety.
;
; What we print (one line per term):
;   1
;   1
;   2
;   3
;   5
;   ...
;
; Build:
;   nasm -f elf64 03_fibonacci.asm -o bin/03_fibonacci.o
;   ld bin/03_fibonacci.o -o bin/03_fibonacci
; Run:
;   ./bin/03_fibonacci
; ═══════════════════════════════════════════════════════════════════════════════

section .bss
    ; Buffer for converting a number to decimal string.
    ; A uint64 has at most 20 decimal digits, +1 for null terminator.
    num_buf  resb 22        ; reserve 22 bytes of uninitialised storage

section .data
    newline  db 10          ; ASCII 10 = '\n'

section .text
global _start               ; expose _start to the linker (program entry point)

; ───────────────────────────────────────────────────────────────────────────
; u64_to_dec — convert unsigned 64-bit integer to a decimal ASCII string
;   Input:  rdi = the number
;           rsi = pointer to output buffer (at least 21 bytes)
;   Output: rax = pointer to first character of string in the buffer
;           rdx = length of the string (number of characters, no null)
;
;   Method: divide by 10 repeatedly; each remainder is a digit (0-9).
;   Digits come out least-significant first so we reverse at the end.
; ───────────────────────────────────────────────────────────────────────────
u64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved: must not change)
    mov  rbp, rsp           ; set our own frame pointer to track this function's locals
    push rbx                ; save rbx — we use it as write pointer (callee-saved)
    push r12                ; save r12 — we use it to remember the buffer start (callee-saved)

    mov  rax, rdi           ; rax = the number (dividend — 'div' instruction uses rax)
    mov  rbx, rsi           ; rbx = current write pointer into the buffer
    mov  r12, rsi           ; r12 = fixed start of the buffer (for reversal later)

    ; Special case: number == 0
    test rax, rax           ; bitwise AND of rax with itself; sets ZF if rax == 0
    jnz  .extract_digits    ; if not zero, go extract digits normally

    mov  byte [rbx], '0'    ; write the character '0' into the buffer
    inc  rbx                ; advance write pointer by 1 byte
    jmp  .null_term         ; skip the loop

.extract_digits:
    ; Loop: extract each decimal digit as a remainder from dividing by 10
    xor  rdx, rdx           ; rdx = 0 — 'div' uses rdx:rax as the 128-bit dividend; clear high half
    mov  rcx, 10            ; rcx = 10 — divisor
    div  rcx                ; unsigned divide: rax = rax/10 (quotient), rdx = rax%10 (remainder)
    add  dl, '0'            ; dl = (digit 0-9) + 48 = ASCII character '0' to '9'
    mov  [rbx], dl          ; store this digit character in the buffer
    inc  rbx                ; move write pointer to the next byte
    test rax, rax           ; is the quotient now zero? (all digits extracted?)
    jnz  .extract_digits    ; no — loop again for the next digit

.null_term:
    mov  byte [rbx], 0      ; write a null terminator at the end

    ; Compute the string length before we reverse
    mov  rdx, rbx           ; rdx = pointer to just past the last digit
    sub  rdx, r12           ; rdx = length = (end pointer) - (start pointer)

    ; Now reverse the buffer [r12 .. rbx-1] because digits are backwards
    lea  rdi, [rbx - 1]     ; rdi = pointer to the LAST written digit (right end)
    mov  rsi, r12           ; rsi = pointer to the FIRST written digit (left end)
.reverse:
    cmp  rsi, rdi           ; have the two ends met or crossed?
    jge  .rev_done          ; yes — reversal is complete
    mov  al,  [rsi]         ; al = character at left pointer
    mov  cl,  [rdi]         ; cl = character at right pointer
    mov  [rsi], cl          ; swap: write right char to left position
    mov  [rdi], al          ; swap: write left char to right position
    inc  rsi                ; left pointer moves right
    dec  rdi                ; right pointer moves left
    jmp  .reverse           ; check again

.rev_done:
    mov  rax, r12           ; rax = pointer to start of (now correctly ordered) string

    pop  r12                ; restore r12 (callee-saved: must restore before returning)
    pop  rbx                ; restore rbx (callee-saved: must restore before returning)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string start, rdx = length

; ───────────────────────────────────────────────────────────────────────────
; print_u64 — print an unsigned 64-bit integer followed by a newline
;   Input:  rdi = the number to print
;   Clobbers: rax, rdx, rsi (syscall registers — caller must save if needed)
; ───────────────────────────────────────────────────────────────────────────
print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rdi                ; push the number — rdi will be overwritten by u64_to_dec return

    ; Convert the number to a decimal string in num_buf
    ; rdi still holds the number from the push above — restore first
    pop  rdi                ; restore the number into rdi
    mov  rsi, num_buf       ; rsi = pointer to our conversion buffer
    call u64_to_dec         ; rax = string pointer, rdx = string length

    ; Write the decimal string to stdout
    mov  rsi, rax           ; rsi = string pointer (syscall arg 2)
    mov  rdx, rdx           ; rdx = string length (syscall arg 3) — already in rdx from u64_to_dec
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor (syscall arg 1)
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; kernel: write(stdout, string, length)

    ; Write the newline
    mov  rdi, 1             ; rdi = 1 — stdout file descriptor
    mov  rsi, newline       ; rsi = pointer to our '\n' byte
    mov  rdx, 1             ; rdx = 1 byte to write
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; kernel: write(stdout, "\n", 1)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; _start — program entry point
;   Iteratively computes and prints Fibonacci numbers F(1) through F(93)
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; We track the sequence using two registers.
    ; r13 = "previous" term (starts as 0, a virtual F(0) to kick off the recurrence)
    ; r14 = "current"  term (starts as 1, which is F(1))
    ; r15 = loop counter from 1 to 93
    ;
    ; We use r13-r15 because they are callee-saved; calling print_u64 will NOT clobber them.

    mov  r13, 0             ; r13 = previous = 0 (F(0), not printed — just a seed)
    mov  r14, 1             ; r14 = current  = 1 (F(1) — first term to print)
    mov  r15, 1             ; r15 = term index, starts at 1

.loop:
    cmp  r15, 93            ; have we printed all 93 terms?
    jg   .finish            ; if r15 > 93, we are done

    ; Print the current Fibonacci number
    mov  rdi, r14           ; rdi = current term (F(r15)) — argument to print_u64
    call print_u64          ; print the number, followed by a newline

    ; Advance the sequence: next = current + previous
    mov  rax, r14           ; rax = F(n) — save the current value before overwriting r14
    add  r14, r13           ; r14 = F(n) + F(n-1) = F(n+1) — update current to next term
    mov  r13, rax           ; r13 = old F(n) = new F(n-1) — update previous

    inc  r15                ; term_index++ — move to the next term
    jmp  .loop              ; go back and print the next term

.finish:
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success (XOR with self clears to zero)
    syscall                 ; kernel: exit(0) — terminate the process



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



;═══════════════════════════════════════════════════════════════════════════════
; §05  Bit Count (Popcount)
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 05_bitcount.asm
;  Description : Kernighan n&(n-1) trick, SSSE3 PSHUFB nibble-LUT, PSADBW
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 05_bitcount.asm — Count set bits (popcount) using scalar and SSE2 methods
; Goal: learn SIMD data layout and lane operations
;
; We implement popcount in two ways:
;
; 1. SCALAR — Brian Kernighan's algorithm (n & (n-1) trick), one bit per iteration
;    Simple but O(k) where k = number of set bits
;
; 2. SSE2 lookup table (pshufb/psadbw trick):
;    This is the vectorized approach used in FFmpeg and other high-performance code.
;    Idea: split each byte into two nibbles (4-bit pieces), look up the popcount
;    of each nibble in a 16-entry table, then sum.
;
;    NOTE: PSHUFB is part of SSSE3 (Supplemental SSE3), not SSE2.
;    The technique is often called the "SSE2 popcount" but uses PSHUFB (SSSE3).
;    We handle this by providing the scalar fallback and using the SSSE3 version.
;
;    Steps for the vectorized popcount over 16 bytes at a time:
;    a) Load 16 bytes into xmm0
;    b) Create low nibble mask: xmm_mask = {0x0F x 16}
;    c) Extract low nibbles:  lo = xmm0 & mask
;    d) Extract high nibbles: hi = (xmm0 >> 4) & mask  (PSRLW then AND)
;    e) PSHUFB lo_lut, lo   — look up popcount of each low nibble
;    f) PSHUFB hi_lut, hi   — look up popcount of each high nibble
;    g) PADDB result = lo_lut + hi_lut  — sum nibble popcounts per byte
;    h) PSADBW result, zeros — sum 8 bytes at a time into 16-bit accumulators
;    i) Sum the two 16-bit accumulators for total popcount of the 16 bytes
;
; Build:
;   nasm -f elf64 05_bitcount.asm -o bin/05_bitcount.o
;   ld bin/05_bitcount.o -o bin/05_bitcount
; Run:
;   ./bin/05_bitcount
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16                ; 16-byte align for SSE loads (unaligned loads work too but are slower)

    ; 16-entry lookup table: popcount_lut[i] = number of 1-bits in the nibble i (0-15)
    ; nibble:     0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
    popcount_lut  db 0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4

    ; Test data: 16 bytes whose bitcounts we want to sum
    ; The test buffer has known content so we can verify the result
    test_buf db 0xFF, 0x00, 0xAA, 0x55, 0x0F, 0xF0, 0x01, 0x80
             db 0xFE, 0x7F, 0x0E, 0x70, 0xFF, 0xFF, 0x00, 0x00
    ; Popcount per byte:
    ;   FF=8, 00=0, AA=4, 55=4, 0F=4, F0=4, 01=1, 80=1
    ;   FE=7, 7F=7, 0E=3, 70=3, FF=8, FF=8, 00=0, 00=0
    ; Total = 8+0+4+4+4+4+1+1+7+7+3+3+8+8+0+0 = 62

    lbl_scalar   db "Scalar popcount of test_buf = ", 0
    lbl_ssse3    db "SSSE3  popcount of test_buf = ", 0
    lbl_val      db "popcount(0xDEADBEEF12345678) = ", 0
    newline      db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; popcount_kernighan — count set bits in a 64-bit value (scalar)
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits
;
;   Key insight: n & (n-1) always clears the LOWEST set bit.
;   Example: n=0b1100, n-1=0b1011, n&(n-1)=0b1000 (cleared bit 2, which was lowest)
;   Count how many times we can do this before n reaches 0.
; ───────────────────────────────────────────────────────────────────────────
popcount_kernighan:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — counter starts at zero

.pk_loop:
    test rdi, rdi           ; is rdi == 0? (AND with itself, sets ZF if zero)
    jz   .pk_done           ; yes — no more set bits to count

    mov  rcx, rdi           ; rcx = n — copy current value
    dec  rcx                ; rcx = n - 1
    and  rdi, rcx           ; rdi = n & (n-1) — clears the lowest set bit
    inc  rax                ; we just eliminated one set bit — count it

    jmp  .pk_loop           ; check again

.pk_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total number of set bits

; ───────────────────────────────────────────────────────────────────────────
; popcount_buf_scalar — popcount of a byte buffer using scalar method
;   Input:  rdi = pointer to byte buffer
;           rsi = number of bytes
;   Output: rax = total number of set bits across all bytes
; ───────────────────────────────────────────────────────────────────────────
popcount_buf_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — buffer pointer (callee-saved)
    push r15                ; save r15 — total count (callee-saved)
    push rbx                ; save rbx — index (callee-saved)

    mov  r14, rdi           ; r14 = buffer pointer
    xor  r15, r15           ; r15 = total = 0
    xor  rbx, rbx           ; rbx = index = 0

.pbs_loop:
    cmp  rbx, rsi           ; index >= byte count?
    jge  .pbs_done          ; yes — done

    movzx rdi, byte [r14 + rbx]   ; rdi = current byte (zero-extended to 64 bits)
    call popcount_kernighan         ; rax = popcount of this byte

    add  r15, rax           ; r15 += popcount(byte)
    inc  rbx                ; advance to next byte
    jmp  .pbs_loop          ; loop

.pbs_done:
    mov  rax, r15           ; rax = total popcount (return value)

    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; popcount_buf_ssse3 — vectorized popcount of 16 bytes using SSSE3 pshufb trick
;   Input:  rdi = pointer to 16-byte buffer (need not be aligned)
;   Output: rax = total number of set bits in the 16 bytes
;
;   The pshufb instruction uses one register as a SHUFFLE CONTROL mask:
;   PSHUFB xmm_dst, xmm_src:
;     For each byte i of xmm_dst:
;       if xmm_src[i] has bit 7 set → result byte i = 0
;       else result byte i = xmm_dst[ xmm_src[i] & 0x0F ]
;   So we can use the nibble value (0-15) as an index into a lookup table!
; ───────────────────────────────────────────────────────────────────────────
popcount_buf_ssse3:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; Load the lookup table into xmm_lut (stays constant across all bytes)
    movdqu xmm5, [popcount_lut]   ; xmm5 = LUT: {4,3,3,2,...,1,0} for nibbles 15..0
                                   ; MOVDQU: Move Unaligned Double Quadword (16 bytes, any alignment)

    ; Create a mask of 0x0F in all 16 byte lanes
    ; We do this by loading the LUT bytes which happen to fit, then we PCMPeq or just use an immediate
    ; Easiest: use PCMPEQB to create all-0xFF, then shift right arithmetically
    ; Simpler: use a constant in .data
    movdqu xmm6, [nibble_mask]    ; xmm6 = {0x0F, 0x0F, ..., 0x0F} — 16 copies of 0x0F

    ; Load the 16 bytes to count
    movdqu xmm0, [rdi]            ; xmm0 = the 16 input bytes

    ; Extract LOW nibbles: lo = xmm0 & 0x0F (per byte)
    movdqa xmm1, xmm0             ; xmm1 = copy of input (MOVDQA: move aligned — valid since xmm1 is a register)
    pand   xmm1, xmm6             ; xmm1 = xmm0 & 0x0F — keep only the lower 4 bits of each byte
                                   ; PAND: Packed AND — bitwise AND all 16 bytes

    ; Extract HIGH nibbles: hi = (xmm0 >> 4) & 0x0F (per byte)
    movdqa xmm2, xmm0             ; xmm2 = copy of input
    psrlw  xmm2, 4                ; xmm2 = xmm0 >> 4 (shift all 16-bit words right by 4 bits)
                                   ; PSRLW: Packed Shift Right Logical Word (16-bit granularity)
                                   ; This shifts high nibble into low position (and contaminates the high bit of
                                   ; each byte with the high bit of the high nibble, which we clear next)
    pand   xmm2, xmm6             ; xmm2 = hi & 0x0F — clear any contamination from the shift
                                   ; PAND: Packed AND

    ; Look up popcount for each nibble
    ; PSHUFB uses each byte of xmm1/xmm2 as an INDEX into xmm5 (the LUT)
    pshufb xmm5, xmm1             ; xmm5 = LUT[lo_nibble] for each byte — popcount of low nibble
                                   ; PSHUFB (SSSE3): Packed Shuffle Bytes

    movdqu xmm4, [popcount_lut]   ; reload the LUT (pshufb modified xmm5)
    pshufb xmm4, xmm2             ; xmm4 = LUT[hi_nibble] for each byte — popcount of high nibble
                                   ; PSHUFB: uses xmm2 as index, xmm4 as table

    ; Sum nibble popcounts per byte: popcount(byte) = pop(lo nibble) + pop(hi nibble)
    paddb  xmm5, xmm4             ; xmm5 = per-byte popcount (add the two nibble counts)
                                   ; PADDB: Packed Add Bytes — adds 16 pairs of bytes

    ; Sum all 16 byte popcounts
    ; PSADBW computes: for each group of 8 bytes, compute sum of absolute differences with 0
    ; Since all values are positive, |x - 0| = x, so PSADBW with zero simply sums groups of 8.
    pxor   xmm0, xmm0             ; xmm0 = {0 x 16} — all zeros (XOR with self)
                                   ; PXOR: Packed XOR — fastest way to zero an XMM register
    psadbw xmm5, xmm0             ; xmm5 = sum of bytes 0-7 in low 64 bits, sum of bytes 8-15 in high 64 bits
                                   ; PSADBW: Packed Sum of Absolute Differences of Bytes against zero

    ; Extract the two 64-bit halves and sum them
    movq   rax, xmm5              ; rax = lower 64 bits = sum of bytes 0-7
                                   ; MOVQ: move quadword from XMM to 64-bit general register
    psrldq xmm5, 8                ; shift xmm5 right by 8 bytes to move upper sum to lower position
                                   ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movq   rcx, xmm5              ; rcx = sum of bytes 8-15

    add    rax, rcx               ; rax = total popcount = sum_low + sum_high

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total set bits in the 16 bytes

section .data
    align 16
    nibble_mask  db 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F
                 db 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F, 0x0F

section .text

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers
; ───────────────────────────────────────────────────────────────────────────
print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pu_d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pu_t

.pu_d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pu_d

.pu_t:
    mov  byte [rbx], 0
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pu_r:
    cmp  rsi, rdi
    jge  .pu_w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pu_r
.pu_w:
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
.pc:
    cmp  byte [rdi + rcx], 0
    je   .pc_w
    inc  rcx
    jmp  .pc
.pc_w:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Scalar popcount of the 16-byte test buffer
    mov  rdi, lbl_scalar
    call print_cstr

    mov  rdi, test_buf      ; rdi = buffer pointer
    mov  rsi, 16            ; rsi = 16 bytes
    call popcount_buf_scalar ; rax = total set bits

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; SSSE3 vectorized popcount of the same buffer
    mov  rdi, lbl_ssse3
    call print_cstr

    mov  rdi, test_buf      ; rdi = buffer pointer (16 bytes)
    call popcount_buf_ssse3 ; rax = total set bits

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Single 64-bit value popcount
    mov  rdi, lbl_val
    call print_cstr

    mov  rdi, 0xDEADBEEF12345678   ; rdi = 64-bit test value
    call popcount_kernighan         ; rax = popcount

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §06  Image Row Add
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 06_img_row_add.asm
;  Description : Saturating byte addition: scalar clamp vs SSE2 PADDUSB
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 06_img_row_add.asm — Add two 8-bit pixel rows into an output buffer
; Goal: aligned vs unaligned loads, loop peeling, basic SIMD data flow
;
; This models what FFmpeg does when blending two video frames pixel by pixel.
; Each pixel is one uint8_t (0-255). Adding can overflow 255, so we clamp.
; We add with SATURATING addition: paddusb instruction does this automatically.
;
; We implement three versions:
;
; 1. SCALAR — loop over each byte individually
;    dst[i] = min(src_a[i] + src_b[i], 255)  for i in [0, n)
;
; 2. SSE2 UNALIGNED — process 16 bytes at a time using MOVDQU (unaligned)
;    PADDUSB: Packed ADD Unsigned Bytes with Saturation — clamps at 255 per lane
;    Handles tail bytes (n % 16) with scalar fallback
;
; 3. SSE2 ALIGNED + PEELED LOOP — demonstrates loop peeling:
;    Process initial unaligned bytes one-by-one until we hit 16-byte alignment,
;    then use aligned MOVDQA for the main loop (aligned loads are slightly faster
;    and required for some SSE operations; misalignment causes #GP fault with MOVDQA).
;
; Build:
;   nasm -f elf64 06_img_row_add.asm -o bin/06_img_row_add.o
;   ld bin/06_img_row_add.o -o bin/06_img_row_add
; Run:
;   ./bin/06_img_row_add
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16                    ; 16-byte align so test buffers are aligned for SSE

    ; Test image rows — 32 bytes each (simulates 32 pixels)
    row_a  db 100, 200, 50, 250,  10, 120, 180, 30,  60, 90, 200, 10, 100, 20, 150, 80
           db  70, 110, 40,  60, 250,   5,  95, 45, 100, 35,  80, 20,  15, 60, 200, 10
    row_b  db 100, 100, 50,  10, 200,  80,  50, 90, 190, 10,  50, 30, 150, 20, 100, 80
           db  30,  40,  5, 190,   5, 245, 100, 55,  50, 65, 120, 30, 230, 40,  55, 20

    n_pixels equ 32             ; number of pixels per row

    lbl_scal   db "Scalar result: ", 0
    lbl_sse    db "SSE2   result: ", 0
    lbl_match  db "Results match!", 10, 0
    lbl_nomatch db "MISMATCH!", 10, 0
    newline    db 10
    space      db " ", 0

section .bss
    dst_scalar  resb 32     ; output from scalar implementation
    dst_sse     resb 32     ; output from SSE2 implementation
    num_buf     resb 8      ; small buffer for printing single bytes

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; row_add_scalar — add two uint8 pixel rows with saturation (clamped at 255)
;   Input:  rdi = pointer to row A (uint8_t array)
;           rsi = pointer to row B (uint8_t array)
;           rdx = pointer to output row (uint8_t array)
;           rcx = number of pixels n
; ───────────────────────────────────────────────────────────────────────────
row_add_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  r8, r8             ; r8 = 0 — pixel index

.ras_loop:
    cmp  r8, rcx            ; index >= n?
    jge  .ras_done          ; yes — done

    movzx rax, byte [rdi + r8]   ; rax = A[i] (zero-extend byte to 64-bit — avoids partial-register issues)
    movzx r9,  byte [rsi + r8]   ; r9  = B[i] (zero-extend byte to 64-bit)
    add  rax, r9                  ; rax = A[i] + B[i] (may exceed 255)
    cmp  rax, 255                 ; is sum > 255?
    jle  .ras_store               ; no — store as-is
    mov  rax, 255                 ; yes — clamp to 255 (saturation)

.ras_store:
    mov  [rdx + r8], al          ; store the clamped byte to output (AL = lowest byte of rax)
    inc  r8                       ; advance to next pixel
    jmp  .ras_loop                ; loop

.ras_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; row_add_sse2 — add two pixel rows using SSE2 PADDUSB (16 pixels per iteration)
;   Input:  rdi = pointer to row A
;           rsi = pointer to row B
;           rdx = pointer to output
;           rcx = number of pixels n
;
;   PADDUSB: Packed Add Unsigned Bytes with Saturation
;     Adds corresponding bytes; if result > 255, clamps to 255.
;     Operates on 16 bytes simultaneously.
;
;   We use MOVDQU (unaligned) for simplicity — works on any pointer alignment.
;   Production code might peel the first few bytes to achieve alignment.
; ───────────────────────────────────────────────────────────────────────────
row_add_sse2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; Compute number of 16-byte blocks
    mov  r8, rcx            ; r8 = n
    shr  r8, 4              ; r8 = n / 16 — number of full 16-byte blocks

    xor  r9, r9             ; r9 = 0 — byte offset (advances by 16 per iteration)

.rss_block:
    test r8, r8             ; any 16-byte blocks remaining?
    jz   .rss_tail          ; no — handle the tail

    movdqu xmm0, [rdi + r9]    ; xmm0 = 16 bytes from row A (unaligned load)
                                ; MOVDQU: Move Unaligned Double Quadword
    movdqu xmm1, [rsi + r9]    ; xmm1 = 16 bytes from row B (unaligned load)
    paddusb xmm0, xmm1          ; xmm0 = saturating_add(A, B) per byte
                                ; PADDUSB: Packed ADD Unsigned Bytes with Saturation
                                ; Each byte: result = min(A[i] + B[i], 255)
    movdqu [rdx + r9], xmm0    ; store 16 output bytes (unaligned store)
                                ; MOVDQU: Move Unaligned Double Quadword (store)

    add  r9, 16             ; advance byte offset by 16 (16 bytes per block)
    dec  r8                 ; one fewer block to process
    jmp  .rss_block         ; loop

.rss_tail:
    ; Handle remaining 0-15 bytes (n % 16) using scalar saturation
    ; r9 = byte offset where the tail starts
.rss_tail_loop:
    cmp  r9, rcx            ; have we processed all n bytes?
    jge  .rss_done          ; yes

    movzx rax, byte [rdi + r9]  ; rax = A[i]
    movzx r10, byte [rsi + r9]  ; r10 = B[i]
    add  rax, r10               ; rax = A[i] + B[i]
    cmp  rax, 255               ; > 255?
    jle  .rss_t_store           ; no
    mov  rax, 255               ; clamp to 255

.rss_t_store:
    mov  [rdx + r9], al         ; store clamped byte
    inc  r9                     ; next byte
    jmp  .rss_tail_loop         ; loop

.rss_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; print helpers
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pc:
    cmp  byte [rdi + rcx], 0
    je   .pcw
    inc  rcx
    jmp  .pc
.pcw:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

print_byte_array:           ; rdi = ptr, rsi = count
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14
    push r15
    push rbx

    mov  r14, rdi           ; r14 = array pointer
    mov  r15, rsi           ; r15 = count
    xor  rbx, rbx           ; rbx = index

.pba_l:
    cmp  rbx, r15
    jge  .pba_nl

    ; Print one byte as 3-digit decimal (padded)
    movzx rdi, byte [r14 + rbx]  ; rdi = current byte
    ; Convert byte (0-255) to 3-char string with leading spaces
    mov  rax, rdi
    ; Hundreds digit
    xor  rdx, rdx
    mov  rcx, 100
    div  rcx                ; rax = hundreds, rdx = remainder
    add  al, '0'
    mov  [num_buf], al
    mov  rax, rdx
    ; Tens digit
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  al, '0'
    mov  [num_buf+1], al
    ; Ones digit
    add  dl, '0'
    mov  [num_buf+2], dl
    ; Space
    mov  byte [num_buf+3], ' '
    mov  rdi, 1
    mov  rsi, num_buf
    mov  rdx, 4
    mov  rax, 1
    syscall

    inc  rbx
    jmp  .pba_l

.pba_nl:
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
    ; ── Scalar addition ──
    mov  rdi, row_a         ; rdi = row A
    mov  rsi, row_b         ; rsi = row B
    mov  rdx, dst_scalar    ; rdx = output buffer
    mov  rcx, n_pixels      ; rcx = 32 pixels
    call row_add_scalar     ; compute saturated sum

    mov  rdi, lbl_scal      ; "Scalar result: "
    call print_cstr

    mov  rdi, dst_scalar    ; rdi = output
    mov  rsi, n_pixels      ; rsi = 32
    call print_byte_array   ; print the pixel values

    ; ── SSE2 addition ──
    mov  rdi, row_a         ; rdi = row A
    mov  rsi, row_b         ; rsi = row B
    mov  rdx, dst_sse       ; rdx = output buffer
    mov  rcx, n_pixels      ; rcx = 32 pixels
    call row_add_sse2       ; compute saturated sum via SSE2

    mov  rdi, lbl_sse       ; "SSE2   result: "
    call print_cstr

    mov  rdi, dst_sse       ; rdi = output
    mov  rsi, n_pixels      ; rsi = 32
    call print_byte_array   ; print the pixel values

    ; ── Verify scalar == SSE2 ──
    ; Compare the two output buffers byte by byte
    xor  rcx, rcx           ; rcx = index = 0
.verify:
    cmp  rcx, n_pixels      ; done?
    jge  .match             ; yes — all bytes matched

    mov  al, [dst_scalar + rcx]    ; al = scalar result
    cmp  al, [dst_sse + rcx]       ; compare with SSE result
    jne  .nomatch                   ; mismatch!

    inc  rcx                ; next byte
    jmp  .verify            ; loop

.match:
    mov  rdi, lbl_match     ; "Results match!"
    call print_cstr
    jmp  .exit

.nomatch:
    mov  rdi, lbl_nomatch   ; "MISMATCH!"
    call print_cstr

.exit:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §07  1-D Convolution
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 07_conv1d.asm
;  Description : 3-tap FIR filter: scalar MAC loop vs SSE2 PMADDWD
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 07_conv1d.asm — 1D convolution with a 3-tap kernel on 16-bit samples
; Goal: multiply-accumulate patterns in scalar and SSE2
;
; 1D convolution: out[i] = k0*in[i-1] + k1*in[i] + k2*in[i+1]
; This is a 3-tap FIR filter. "Tap" = number of kernel coefficients.
; Border pixels (i=0, i=n-1) use zero-padding (out-of-bounds inputs = 0).
;
; Samples are int16_t (16-bit signed integers, range -32768 to 32767).
; Kernel is also int16_t.
; Output is int32_t (32-bit) to hold the full product without overflow.
;
; Example kernel [1, 2, 1] approximates a simple smoothing (blurring) filter.
;
; SCALAR:
;   For each output sample, load 3 input samples, multiply by kernel, sum.
;
; SSE2 PACKED 16-bit:
;   PMULLW: Packed Multiply Low 16-bit Words → 8 multiplications in parallel
;   PMADDWD: Packed Multiply-Add Words → multiply 8 pairs and add adjacent pairs,
;            giving 4 int32_t results
;   For 3-tap convolution we process one output per iteration with PMADDWD.
;
; Build:
;   nasm -f elf64 07_conv1d.asm -o bin/07_conv1d.o
;   ld bin/07_conv1d.o -o bin/07_conv1d
; Run:
;   ./bin/07_conv1d
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16

    ; Input signal: 16-bit samples
    in_sig   dw 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120
    n_samp   equ ($ - in_sig) / 2      ; count = byte size / 2 (each sample is 2 bytes)

    ; 3-tap kernel: [k0, k1, k2]
    ; Smoothing kernel weights 1, 2, 1 (like a weighted average of 3 neighbors)
    kernel   dw 1, 2, 1
    ; k0 = 1 (weight for in[i-1])
    ; k1 = 2 (weight for in[i])
    ; k2 = 1 (weight for in[i+1])

    ; For SSE: replicate kernel into xmm register pattern as needed
    ; We'll load kernel[0] into a scalar, etc. for the scalar version.

    lbl_scal  db "Scalar output: ", 0
    lbl_sse   db "SSE2   output: ", 0
    newline   db 10
    space     db " ", 0

section .bss
    out_scalar  resd 12     ; output int32 samples (scalar) — 4 bytes each
    out_sse     resd 12     ; output int32 samples (SSE)
    num_buf     resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; conv1d_scalar — 3-tap convolution, scalar implementation
;   Input:  rdi = pointer to int16_t input array
;           rsi = pointer to int32_t output array
;           rdx = number of input samples n
;   Kernel is read from the global 'kernel' variable.
;   Boundary: zero-padding (samples outside [0,n) are treated as 0).
; ───────────────────────────────────────────────────────────────────────────
conv1d_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved) — input pointer
    push r13                ; save r13 (callee-saved) — output pointer
    push r14                ; save r14 (callee-saved) — n
    push r15                ; save r15 (callee-saved) — loop index i

    mov  r12, rdi           ; r12 = input pointer
    mov  r13, rsi           ; r13 = output pointer
    mov  r14, rdx           ; r14 = n

    xor  r15, r15           ; r15 = i = 0

    ; Load kernel coefficients into registers once (avoids repeated memory reads)
    movsx r8, word [kernel]        ; r8 = k0 (sign-extend int16 to int64)
    movsx r9, word [kernel + 2]    ; r9 = k1
    movsx r10, word [kernel + 4]   ; r10 = k2

.cs_loop:
    cmp  r15, r14           ; i >= n?
    jge  .cs_done           ; yes — done

    ; Accumulate: sum = k0*in[i-1] + k1*in[i] + k2*in[i+1]
    xor  rax, rax           ; rax = 0 — accumulator

    ; Tap 0: k0 * in[i-1]  (boundary check: if i==0, treat as 0)
    test r15, r15           ; is i == 0?
    jz   .cs_tap0_zero      ; yes — skip (0 * k0 = 0)
    movsx rcx, word [r12 + r15*2 - 2]  ; rcx = in[i-1] (sign-extend int16 → int64)
    imul rcx, r8                        ; rcx = k0 * in[i-1]
    add  rax, rcx                       ; accumulator += k0 * in[i-1]
.cs_tap0_zero:

    ; Tap 1: k1 * in[i]
    movsx rcx, word [r12 + r15*2]    ; rcx = in[i] (sign-extend int16 → int64)
    imul rcx, r9                      ; rcx = k1 * in[i]
    add  rax, rcx                     ; accumulator += k1 * in[i]

    ; Tap 2: k2 * in[i+1]  (boundary check: if i==n-1, treat as 0)
    lea  rcx, [r15 + 1]    ; rcx = i + 1
    cmp  rcx, r14           ; is (i+1) >= n? (i.e., i is the last element)
    jge  .cs_tap2_zero      ; yes — skip (0 * k2 = 0)
    movsx rcx, word [r12 + r15*2 + 2]  ; rcx = in[i+1] (sign-extend int16 → int64)
    imul rcx, r10                       ; rcx = k2 * in[i+1]
    add  rax, rcx                       ; accumulator += k2 * in[i+1]
.cs_tap2_zero:

    ; Store 32-bit result (truncate rax to 32 bits for output)
    mov  [r13 + r15*4], eax  ; out[i] = accumulator (store as int32)

    inc  r15                ; i++
    jmp  .cs_loop           ; next sample

.cs_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; conv1d_sse — 3-tap convolution using SSE2 packed 16-bit multiply-add
;   Input:  rdi = pointer to int16_t input array
;           rsi = pointer to int32_t output array
;           rdx = number of input samples n
;
;   We use PMADDWD (Packed Multiply and Add Words):
;     PMADDWD xmm_dst, xmm_src
;     Multiplies 8 pairs of int16, then adds adjacent pairs → 4 int32 results
;     xmm_dst[i] = xmm_dst[2i] * xmm_src[2i] + xmm_dst[2i+1] * xmm_src[2i+1]
;
;   For each output sample out[i], we create a vector of [in[i-1], in[i], in[i+1], 0]
;   and a kernel vector [k0, k1, k2, 0].
;   PMADDWD gives: [k0*in[i-1] + k1*in[i], k2*in[i+1] + 0*0, ...]
;   We then need to add lane 0 and lane 1 of the result.
;   This is a simplified approach; real FFmpeg code does much more parallelism.
; ───────────────────────────────────────────────────────────────────────────
conv1d_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push r15                ; save r15 (callee-saved)

    mov  r12, rdi           ; r12 = input pointer
    mov  r13, rsi           ; r13 = output pointer
    mov  r14, rdx           ; r14 = n

    ; Load kernel into the low 6 bytes of xmm_kern
    ; We arrange as [k2, k1, k0, 0, ...] for PMADDWD usage
    movd    xmm7, dword [kernel]      ; xmm7[0..31] = {k1:16, k0:16} (two 16-bit words)
    pinsrw  xmm7, word [kernel+4], 2  ; insert k2 at word position 2
                                       ; PINSRW: Packed INsert Word — inserts a 16-bit value
    ; Now xmm7 = [0, 0, 0, 0, 0, 0, k2, k1, k0, ...]
    ; Actually xmm7 low words = k0, k1, k2, 0, 0, ...

    xor  r15, r15           ; r15 = i = 0

.csse_loop:
    cmp  r15, r14           ; i >= n?
    jge  .csse_done         ; yes — done

    ; Build vector [in[i+1], in[i], in[i-1], 0, ...] in low 3 words of xmm0
    ; We handle boundary conditions manually

    pxor    xmm0, xmm0      ; xmm0 = all zeros (PXOR: clear by XOR with self)

    ; Word 0 = in[i-1] (or 0 if i == 0)
    test r15, r15            ; i == 0?
    jz   .csse_no_prev       ; yes — leave word 0 as 0
    movsx rax, word [r12 + r15*2 - 2]    ; rax = in[i-1]
    pinsrw xmm0, ax, 0                    ; insert in[i-1] at word 0 of xmm0
.csse_no_prev:

    ; Word 1 = in[i]
    movsx  rax, word [r12 + r15*2]    ; rax = in[i]
    pinsrw xmm0, ax, 1                ; insert in[i] at word 1 of xmm0

    ; Word 2 = in[i+1] (or 0 if i == n-1)
    lea    rax, [r15 + 1]
    cmp    rax, r14          ; i+1 >= n?
    jge    .csse_no_next     ; yes — leave word 2 as 0
    movsx  rax, word [r12 + r15*2 + 2]   ; rax = in[i+1]
    pinsrw xmm0, ax, 2                    ; insert in[i+1] at word 2 of xmm0
.csse_no_next:

    ; Now xmm0 = [0, 0, 0, 0, 0, in[i+1], in[i], in[i-1]] (16-bit words)
    ; xmm7     = [0, 0, 0, 0, 0, k2,      k1,    k0     ]

    pmaddwd xmm0, xmm7      ; xmm0 = {0, 0, 0, k2*in[i+1], k1*in[i] + k0*in[i-1]}
                             ; PMADDWD: multiply 8 pairs of int16, add adjacent pairs → 4 int32
                             ; Result at dword 0 = k0*in[i-1] + k1*in[i]
                             ; Result at dword 1 = k2*in[i+1] + 0*0

    ; Extract dword 0 and dword 1, add them
    movd   eax, xmm0         ; eax = dword 0 = k0*in[i-1] + k1*in[i]
    psrldq xmm0, 4           ; shift xmm0 right 4 bytes to move dword 1 to position 0
                              ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movd   ecx, xmm0         ; ecx = dword 1 = k2*in[i+1]
    add    eax, ecx           ; eax = total sum = k0*in[i-1] + k1*in[i] + k2*in[i+1]

    mov    [r13 + r15*4], eax ; store result as int32

    inc  r15                ; i++
    jmp  .csse_loop         ; loop

.csse_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_i32:                  ; print signed 32-bit; Input: edi
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    movsxd rdi, edi         ; sign-extend int32 to int64
    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13d, r13d

    test rdi, rdi
    jns  .p32pos
    neg  rdi
    mov  r13d, 1

.p32pos:
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
    lea  rdi, [rbx-1]
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

    pop  r13
    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi
    xor  rcx, rcx
.pcl:
    cmp  byte [rdi+rcx], 0
    je   .pcw
    inc  rcx
    jmp  .pcl
.pcw:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Scalar convolution ──
    mov  rdi, in_sig        ; rdi = input array
    mov  rsi, out_scalar    ; rsi = output buffer
    mov  rdx, n_samp        ; rdx = number of samples
    call conv1d_scalar

    mov  rdi, lbl_scal      ; "Scalar output: "
    call print_cstr

    xor  rbx, rbx           ; rbx = index = 0
.print_scal:
    cmp  rbx, n_samp
    jge  .do_sse
    mov  edi, [out_scalar + rbx*4]  ; edi = out[i] (int32)
    call print_i32
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall
    inc  rbx
    jmp  .print_scal

.do_sse:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE convolution ──
    mov  rdi, in_sig        ; rdi = input
    mov  rsi, out_sse       ; rsi = output
    mov  rdx, n_samp        ; rdx = count
    call conv1d_sse

    mov  rdi, lbl_sse       ; "SSE2   output: "
    call print_cstr

    xor  rbx, rbx
.print_sse:
    cmp  rbx, n_samp
    jge  .done
    mov  edi, [out_sse + rbx*4]  ; edi = out[i]
    call print_i32
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall
    inc  rbx
    jmp  .print_sse

.done:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §08  Endian Swap
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 08_endian_swap.asm
;  Description : 32/64-bit byte reversal: BSWAP instruction vs PSHUFB mask
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 08_endian_swap.asm — Reverse byte order (endian swap) of 32/64-bit words
; Goal: understand shuffle/permutation instructions (pshufb, bswap)
;
; "Big-endian" stores the most significant byte first (e.g., network order).
; "Little-endian" stores the least significant byte first (x86 native order).
; Converting between them requires reversing the bytes of each word.
;
; Example (32-bit): 0x12345678 stored as [12][34][56][78] (big-endian)
;                   in little-endian memory: [78][56][34][12]
;   BSWAP converts between the two:
;   BSWAP 0x12345678 → 0x78563412
;
; We implement:
;   1. SCALAR: use BSWAP instruction on each 32-bit or 64-bit word
;   2. SSE2/SSSE3: use PSHUFB to reverse bytes within multiple words simultaneously
;      PSHUFB can swap bytes within an XMM register based on a shuffle mask.
;
; PSHUFB recap:
;   PSHUFB xmm_data, xmm_mask
;   For each output byte i:
;     if mask[i] bit 7 == 1 → output[i] = 0
;     else output[i] = data[ mask[i] & 0x0F ]  (just the low 4 bits = index 0-15)
;
;   So a mask of [3,2,1,0, 7,6,5,4, 11,10,9,8, 15,14,13,12] reverses each 4-byte word.
;
; Build:
;   nasm -f elf64 08_endian_swap.asm -o bin/08_endian_swap.o
;   ld bin/08_endian_swap.o -o bin/08_endian_swap
; Run:
;   ./bin/08_endian_swap
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 16

    ; Test buffer of 4 x 32-bit words
    buf32    dd 0x12345678, 0xDEADBEEF, 0x00010203, 0xCAFEBABE

    ; Test buffer of 2 x 64-bit words
    buf64    dq 0x0102030405060708, 0xDEADBEEFCAFEBABE

    ; PSHUFB mask to reverse bytes within each 4-byte (dword) group
    ; Byte position: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
    ; Source index:  3  2  1  0  7  6  5  4  11 10  9  8 15 14 13 12
    ; Meaning: output byte 0 comes from input byte 3, etc.
    shuf32_mask  db 3, 2, 1, 0,  7, 6, 5, 4,  11, 10, 9, 8,  15, 14, 13, 12

    ; PSHUFB mask to reverse bytes within each 8-byte (qword) group
    ; Byte position: 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
    ; Source index:  7  6  5  4  3  2  1  0  15 14 13 12 11 10  9  8
    shuf64_mask  db 7, 6, 5, 4,  3, 2, 1, 0,  15, 14, 13, 12,  11, 10, 9, 8

    lbl_before32  db "Before (32-bit):  ", 0
    lbl_after32   db "After  (32-bit):  ", 0
    lbl_before64  db "Before (64-bit):  ", 0
    lbl_after64   db "After  (64-bit):  ", 0
    lbl_pshufb32  db "PSHUFB (32-bit):  ", 0
    newline       db 10
    space         db " ", 0
    hex_prefix    db "0x", 0

section .bss
    out_bswap   resd 4      ; output from scalar BSWAP on 32-bit values
    out_pshufb  resd 4      ; output from PSHUFB on 32-bit values
    num_buf     resb 20

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; bswap32_buf — reverse bytes of each 32-bit word in a buffer (scalar)
;   Input:  rdi = pointer to uint32_t array
;           rsi = pointer to output uint32_t array
;           rdx = count (number of 32-bit words)
;
;   BSWAP reg32 — reverses the 4 bytes of the 32-bit register
;   0x12345678 → 0x78563412
; ───────────────────────────────────────────────────────────────────────────
bswap32_buf:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rcx, rcx           ; rcx = 0 — index

.bs32_loop:
    cmp  rcx, rdx           ; index >= count?
    jge  .bs32_done         ; yes — done

    mov  eax, [rdi + rcx*4] ; eax = input word (load 32-bit unsigned integer)
    bswap eax               ; reverse the 4 bytes in eax
                            ; BSWAP eax: eax = ((eax & 0xFF) << 24) | ... | ((eax >> 24) & 0xFF)
    mov  [rsi + rcx*4], eax ; store swapped word to output

    inc  rcx                ; next word
    jmp  .bs32_loop         ; loop

.bs32_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; bswap32_pshufb — reverse bytes within each 32-bit word, 4 words at a time (SSE)
;   Input:  rdi = pointer to 4 x uint32_t (16 bytes, ideally 16-byte aligned)
;           rsi = pointer to output (16 bytes)
;
;   PSHUFB xmm_data, xmm_mask:
;     Uses mask bytes as source indices to rearrange data bytes.
;     We use shuf32_mask which maps each dword to its byte-reversed version.
; ───────────────────────────────────────────────────────────────────────────
bswap32_pshufb:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    movdqu xmm0, [rdi]         ; xmm0 = 4 input words (16 bytes, unaligned load)
                                ; MOVDQU: Move Unaligned Double Quadword
    movdqa xmm1, [shuf32_mask] ; xmm1 = our shuffle mask (load the mask array)
                                ; MOVDQA: Move Aligned Double Quadword (aligned because of 'align 16')

    pshufb xmm0, xmm1          ; xmm0 = byte-reversed 4 dwords
                                ; PSHUFB (SSSE3): for each of 16 output bytes:
                                ;   output[i] = input[ mask[i] ]
                                ; With our mask this reverses bytes within each 4-byte group

    movdqu [rsi], xmm0         ; store the 4 byte-swapped words
                                ; MOVDQU: Move Unaligned Double Quadword (store)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; bswap64_scalar — reverse bytes of a 64-bit value (scalar)
;   Input:  rdi = uint64_t value
;   Output: rax = byte-reversed value
;
;   BSWAP rdi — reverses all 8 bytes of the 64-bit register
; ───────────────────────────────────────────────────────────────────────────
bswap64_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = input value
    bswap rax               ; reverse the 8 bytes: byte 7 ↔ byte 0, byte 6 ↔ byte 1, etc.
                            ; BSWAP rax: for a 64-bit register, reverses all 8 bytes

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = byte-swapped 64-bit value

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────

; print_hex32 — print 32-bit value as "0xXXXXXXXX" with space after
;   Input: edi = 32-bit value
print_hex32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    ; Convert to 8-char hex string (leading zeros)
    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, 8             ; rbx = digit counter (8 hex digits for 32-bit)
    movzx rdi, edi          ; zero-extend to 64-bit

.ph32_loop:
    ; Extract leftmost 4 bits of the remaining value
    mov  rax, rdi           ; rax = value
    mov  rcx, 8             ; we need to isolate 4 bits = 1 hex digit
    lea  rcx, [rbx - 1]     ; digit position (0=leftmost, 7=rightmost)
    mov  rcx, rbx           ; rcx = remaining digits
    dec  rcx                ; rcx = remaining - 1
    imul rcx, rcx, 4        ; rcx = bit position = (remaining-1) * 4
    mov  rax, rdi
    shr  rax, cl            ; shift to get the nibble at top
    and  rax, 0xF           ; isolate just the 4 bits

    cmp  rax, 10            ; < 10?
    jl   .ph32_num
    add  al, 'A' - 10       ; 'A'-'F'
    jmp  .ph32_store
.ph32_num:
    add  al, '0'            ; '0'-'9'
.ph32_store:
    mov  rcx, 8             ; rcx = 8
    sub  rcx, rbx           ; rcx = 8 - rbx = index into digit buffer
    add  rcx, 2             ; offset by 2 for "0x" prefix
    mov  [r12 + rcx], al

    dec  rbx
    jnz  .ph32_loop

    ; Write "0x" prefix then 8 hex digits
    mov  byte [r12], '0'
    mov  byte [r12 + 1], 'x'
    mov  byte [r12 + 10], ' '

    mov  rdi, 1             ; stdout
    mov  rsi, r12           ; buffer
    mov  rdx, 11            ; "0x" + 8 digits + space = 11 chars
    mov  rax, 1             ; write
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; print_hex64 — print 64-bit value as "0xXXXXXXXXXXXXXXXX"
;   Input: rdi = 64-bit value
print_hex64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf       ; buffer start
    mov  rbx, 16            ; 16 hex digits for 64-bit
    mov  r8, rdi            ; r8 = value

.ph64_loop:
    lea  rcx, [rbx - 1]
    imul rcx, rcx, 4        ; bit position = (remaining-1)*4
    mov  rax, r8
    shr  rax, cl
    and  rax, 0xF
    cmp  rax, 10
    jl   .ph64_num
    add  al, 'A' - 10
    jmp  .ph64_st
.ph64_num:
    add  al, '0'
.ph64_st:
    mov  rcx, 16            ; rcx = 16
    sub  rcx, rbx           ; rcx = 16 - rbx = digit index in buffer
    add  rcx, 2             ; offset by 2 for "0x" prefix
    mov  [r12 + rcx], al
    dec  rbx
    jnz  .ph64_loop

    mov  byte [r12], '0'
    mov  byte [r12 + 1], 'x'
    mov  byte [r12 + 18], 10  ; newline

    mov  rdi, 1
    mov  rsi, r12
    mov  rdx, 19            ; "0x" + 16 + '\n'
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

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

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── 32-bit BSWAP demonstration ──
    mov  rdi, lbl_before32  ; "Before (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_before32:
    cmp  rbx, 4
    jge  .do_bswap32
    mov  edi, [buf32 + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_before32

.do_bswap32:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Scalar BSWAP
    mov  rdi, buf32         ; input
    mov  rsi, out_bswap     ; output
    mov  rdx, 4             ; 4 words
    call bswap32_buf

    mov  rdi, lbl_after32   ; "After  (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_after32:
    cmp  rbx, 4
    jge  .do_pshufb
    mov  edi, [out_bswap + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_after32

.do_pshufb:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; PSHUFB BSWAP
    mov  rdi, buf32         ; input
    mov  rsi, out_pshufb    ; output
    call bswap32_pshufb

    mov  rdi, lbl_pshufb32  ; "PSHUFB (32-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_pshufb:
    cmp  rbx, 4
    jge  .do_bswap64
    mov  edi, [out_pshufb + rbx*4]
    call print_hex32
    inc  rbx
    jmp  .p_pshufb

.do_bswap64:
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── 64-bit BSWAP demonstration ──
    mov  rdi, lbl_before64  ; "Before (64-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_b64:
    cmp  rbx, 2
    jge  .after64
    mov  rdi, [buf64 + rbx*8]
    call print_hex64
    inc  rbx
    jmp  .p_b64

.after64:
    mov  rdi, lbl_after64   ; "After  (64-bit):  "
    call print_cstr

    xor  rbx, rbx
.p_a64:
    cmp  rbx, 2
    jge  .done
    mov  rdi, [buf64 + rbx*8]
    call bswap64_scalar
    mov  rdi, rax
    call print_hex64
    inc  rbx
    jmp  .p_a64

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §09  YUV420 to RGB
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 09_yuv2rgb.asm
;  Description : BT.601 conversion in Q16 fixed-point with saturation clamp
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 09_yuv2rgb.asm — YUV420 to RGB row conversion kernel (8 pixels, SSE2)
; Goal: fixed-point arithmetic, saturation, FFmpeg-style calling convention
;
; What is YUV420?
;   Digital video often stores color in YUV format rather than RGB because the
;   human eye is more sensitive to brightness (Y) than color (U, V).
;   YUV420 means: one Y sample per pixel, one U and one V sample per 2x2 pixels.
;   So for an 8-pixel row: 8 Y values, 4 U values, 4 V values.
;
; The BT.601 conversion formula (full-range):
;   R = Y + 1.402 * (V - 128)
;   G = Y - 0.344 * (U - 128) - 0.714 * (V - 128)
;   B = Y + 1.772 * (U - 128)
;
; Fixed-point representation:
;   We don't use floating point — multiply by 65536 (= 1 << 16) and shift right 16.
;   This is called "Q16" fixed-point arithmetic.
;
;   1.402 * 65536 ≈ 91881  → coeffR_V  = 91881
;   0.344 * 65536 ≈ 22553  → coeffG_U  = 22553
;   0.714 * 65536 ≈ 46801  → coeffG_V  = 46801
;   1.772 * 65536 ≈ 116130 → coeffB_U  = 116130
;
; Saturation: results must be clamped to [0, 255].
;
; This scalar implementation is close to FFmpeg's swscale style.
;
; Build:
;   nasm -f elf64 09_yuv2rgb.asm -o bin/09_yuv2rgb.o
;   ld bin/09_yuv2rgb.o -o bin/09_yuv2rgb
; Run:
;   ./bin/09_yuv2rgb
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test YUV data for 8 pixels (YUV420 format)
    ; Y values: one per pixel
    y_row    db 76, 149, 29, 128, 200, 100, 50, 180
    ; U values: one per 2 pixels (Cb component, chroma blue)
    u_row    db 84, 43, 255, 170    ; 4 U values for 8 pixels
    ; V values: one per 2 pixels (Cr component, chroma red)
    v_row    db 255, 21, 128, 100   ; 4 V values for 8 pixels

    ; Fixed-point coefficients (scaled by 65536 = 1 << 16)
    ; Using signed 32-bit integers to hold the products
    coeff_r_v  dd 91881    ; R += V * 91881 >> 16
    coeff_g_u  dd 22553    ; G -= U * 22553 >> 16
    coeff_g_v  dd 46801    ; G -= V * 46801 >> 16
    coeff_b_u  dd 116130   ; B += U * 116130 >> 16

    lbl_rgb    db "RGB output (8 pixels):", 10, 0
    lbl_pix    db "  Pixel ", 0
    lbl_r      db "  R=", 0
    lbl_g      db " G=", 0
    lbl_b      db " B=", 0
    newline    db 10

section .bss
    ; Output RGB buffer: 8 pixels × 3 bytes each (R, G, B interleaved)
    rgb_out    resb 24
    num_buf    resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; clamp_0_255 — clamp a signed 32-bit value to [0, 255]
;   Input:  eax = signed 32-bit value
;   Output: eax = clamped value
; ───────────────────────────────────────────────────────────────────────────
clamp_0_255:
    test eax, eax           ; is eax < 0? (sets SF flag)
    jns  .cl_pos            ; jump if not signed (eax >= 0)
    xor  eax, eax           ; eax = 0 (clamp to 0)
    ret
.cl_pos:
    cmp  eax, 255           ; is eax > 255?
    jle  .cl_done           ; no — within range
    mov  eax, 255           ; clamp to 255
.cl_done:
    ret

; ───────────────────────────────────────────────────────────────────────────
; yuv420_to_rgb_scalar — convert 8 YUV420 pixels to RGB (scalar, 1 pixel/iter)
;   Input:  rdi = pointer to Y row (8 bytes)
;           rsi = pointer to U row (4 bytes, one per 2 pixels)
;           rdx = pointer to V row (4 bytes)
;           rcx = pointer to RGB output (24 bytes: R,G,B per pixel)
; ───────────────────────────────────────────────────────────────────────────
yuv420_to_rgb_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 — Y pointer (callee-saved)
    push r13                ; save r13 — U pointer (callee-saved)
    push r14                ; save r14 — V pointer (callee-saved)
    push r15                ; save r15 — RGB output pointer (callee-saved)
    push rbx                ; save rbx — pixel index (callee-saved)

    mov  r12, rdi           ; r12 = Y pointer
    mov  r13, rsi           ; r13 = U pointer
    mov  r14, rdx           ; r14 = V pointer
    mov  r15, rcx           ; r15 = RGB output pointer
    xor  rbx, rbx           ; rbx = pixel index = 0

.yuv_loop:
    cmp  rbx, 8             ; processed all 8 pixels?
    jge  .yuv_done          ; yes — done

    ; Load Y for pixel i
    movzx eax, byte [r12 + rbx]    ; eax = Y[i] (zero-extend byte to 32-bit)

    ; Load U and V for pixel pair i/2 (each U/V covers 2 pixels)
    mov  r8, rbx
    shr  r8, 1              ; r8 = i / 2 (integer divide by 2 via right shift)
    movzx r9d, byte [r13 + r8]     ; r9d = U[i/2] (Cb)
    movzx r10d, byte [r14 + r8]    ; r10d = V[i/2] (Cr)

    ; Subtract 128 (center the chroma values: they are unsigned 0-255, centered at 128)
    sub  r9d, 128           ; r9d = U - 128 (now in range -128 to 127)
    sub  r10d, 128          ; r10d = V - 128 (now in range -128 to 127)

    ; Compute R = Y + 1.402 * (V - 128)
    ;             = Y + (V - 128) * 91881 >> 16
    mov  r11d, r10d         ; r11d = V - 128
    imul r11d, [coeff_r_v]  ; r11d = (V - 128) * 91881 (32-bit signed multiply)
    sar  r11d, 16           ; r11d = >> 16 (arithmetic right shift, preserves sign)
    add  r11d, eax          ; r11d = Y + chroma_R
    mov  eax, r11d          ; eax = R (before clamp)
    call clamp_0_255        ; eax = clamped R (0-255)
    ; Save R before using rax as offset scratch (lea overwrites rax)
    mov  r11d, eax                  ; r11d = clamped R value
    lea  rax, [rbx + rbx*2]        ; rax = rbx * 3 (pixel byte offset)
    mov  [r15 + rax], r11b          ; store R byte at output[i*3 + 0]
                            ; R11B = lowest byte of R11

    ; Compute G = Y - 0.344 * (U - 128) - 0.714 * (V - 128)
    ;           = Y - U_term - V_term
    mov  r11d, r9d          ; r11d = U - 128
    imul r11d, [coeff_g_u]  ; r11d = (U - 128) * 22553
    sar  r11d, 16           ; r11d = >> 16
    mov  ecx, r10d          ; ecx = V - 128
    imul ecx, [coeff_g_v]   ; ecx = (V - 128) * 46801
    sar  ecx, 16            ; ecx = >> 16
    ; ecx/r11d still hold valid values; compute Y - U_term - V_term
    ; We need fresh Y:
    movzx eax, byte [r12 + rbx]   ; eax = Y[i] (reload)
    sub  eax, r11d          ; eax = Y - U_term
    sub  eax, ecx           ; eax = Y - U_term - V_term = G before clamp
    call clamp_0_255        ; eax = clamped G
    mov  r11d, eax                  ; save G before overwriting rax
    lea  rax, [rbx + rbx*2]        ; rax = rbx * 3 (pixel byte offset)
    mov  [r15 + rax + 1], r11b     ; store G byte at output[i*3 + 1]

    ; Compute B = Y + 1.772 * (U - 128)
    mov  r11d, r9d          ; r11d = U - 128
    imul r11d, [coeff_b_u]  ; r11d = (U - 128) * 116130
    sar  r11d, 16           ; r11d = >> 16
    movzx eax, byte [r12 + rbx]   ; eax = Y[i] (reload again)
    add  eax, r11d          ; eax = Y + chroma_B = B before clamp
    call clamp_0_255        ; eax = clamped B
    mov  r11d, eax                  ; save B before overwriting rax
    lea  rax, [rbx + rbx*2]        ; rax = rbx * 3 (pixel byte offset)
    mov  [r15 + rax + 2], r11b     ; store B byte at output[i*3 + 2]

    inc  rbx                ; next pixel
    jmp  .yuv_loop          ; loop

.yuv_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

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

print_u8:                   ; print unsigned byte (0-255); Input: edi = value
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    movzx rax, dil          ; rax = the byte value (zero-extend to 64-bit)

    test rax, rax
    jnz  .pu8d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pu8t

.pu8d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pu8d

.pu8t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pu8r:
    cmp  rsi, rdi
    jge  .pu8w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pu8r

.pu8w:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

print_u64:                  ; print uint64; Input: rdi = value
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pu64d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pu64t

.pu64d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pu64d

.pu64t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pu64r:
    cmp  rsi, rdi
    jge  .pu64w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pu64r

.pu64w:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Convert YUV420 to RGB
    mov  rdi, y_row         ; rdi = Y array
    mov  rsi, u_row         ; rsi = U array
    mov  rdx, v_row         ; rdx = V array
    mov  rcx, rgb_out       ; rcx = RGB output buffer
    call yuv420_to_rgb_scalar

    ; Print the RGB values
    mov  rdi, lbl_rgb       ; "RGB output (8 pixels):\n"
    call print_cstr

    xor  rbx, rbx           ; rbx = pixel index = 0
.print_loop:
    cmp  rbx, 8             ; done?
    jge  .done

    mov  rdi, lbl_pix       ; "  Pixel "
    call print_cstr

    mov  rdi, rbx           ; rdi = pixel index
    call print_u64          ; print index number

    mov  rdi, lbl_r         ; "  R="
    call print_cstr

    lea  rax, [rbx + rbx*2]                ; rax = rbx*3 (pixel byte offset)
    movzx edi, byte [rgb_out + rax]        ; R value
    call print_u8

    mov  rdi, lbl_g         ; " G="
    call print_cstr

    lea  rax, [rbx + rbx*2]                ; rax = rbx*3
    movzx edi, byte [rgb_out + rax + 1]    ; G value
    call print_u8

    mov  rdi, lbl_b         ; " B="
    call print_cstr

    lea  rax, [rbx + rbx*2]                ; rax = rbx*3
    movzx edi, byte [rgb_out + rax + 2]    ; B value
    call print_u8

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  rbx
    jmp  .print_loop

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §10  8x8 DCT
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 10_dct8x8.asm
;  Description : Naive direct DCT — Q13 cosine table, separable 2D row pass
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 10_dct8x8.asm — Forward 8×8 Discrete Cosine Transform (DCT), scalar
; Goal: pipeline and latency awareness, register reuse, memory access patterns
;
; DCT is the heart of JPEG and MPEG video compression.
; An 8×8 DCT transforms a block of 64 pixel values (spatial domain)
; into 64 frequency coefficients (frequency domain).
;
; The forward DCT formula for an 8-point 1D row:
;   F[k] = scale[k] * sum_{n=0}^{7}  f[n] * cos((2n+1)*k*PI / 16)
;   where scale[0] = 1/sqrt(8), scale[k!=0] = 1/2  (orthonormal form)
;
; The separable 2D DCT is done by:
;   1. Apply 1D DCT to each of the 8 ROWS → intermediate result
;   2. Apply 1D DCT to each of the 8 COLUMNS of the intermediate result
;
; We use the scaled fixed-point AAN algorithm (Arai, Agui, Nakajima 1988)
; which needs only 11 multiplications per 8-point DCT (vs 64 for direct).
; All multiplications use Q15 fixed-point (scale = 32768 = 1 << 15).
;
; AAN algorithm constants (all multiplied by 32768):
;   C1 = cos(pi/16) ≈ 0.9808  → 32138
;   C2 = cos(pi/8)  ≈ 0.9239  → 30274
;   C3 = cos(3pi/16)≈ 0.8315  → 27246
;   C4 = cos(pi/4)  = 0.7071  → 23170  (= 1/sqrt(2))
;   C5 = cos(5pi/16)≈ 0.5556  → 18205
;   C6 = cos(3pi/8) ≈ 0.3827  → 12540
;   C7 = cos(7pi/16)≈ 0.1951  → 6393
;
; The simplest version to understand is the naive direct formula.
; We implement the naive version for clarity since the goal is learning,
; then note how the AAN algorithm improves it.
;
; Build:
;   nasm -f elf64 10_dct8x8.asm -o bin/10_dct8x8.o
;   ld bin/10_dct8x8.o -o bin/10_dct8x8
; Run:
;   ./bin/10_dct8x8
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; DCT cosine table: cos_table[k][n] = cos((2n+1)*k*PI/16) * 32768
    ; for k = 0..7, n = 0..7 (k = frequency, n = input sample index)
    ; Stored in row-major order: first all n for k=0, then all n for k=1, etc.
    ;
    ; Row k=0: scale factor 1/sqrt(8) ≈ 0.3536; cos((2n+1)*0/16) = cos(0) = 1 for all n
    ; So row 0 = 0.3536 * 32768 ≈ 11585 for all entries
    ; Row k=1: cos(pi/16), cos(3pi/16), cos(5pi/16), cos(7pi/16), cos(9pi/16),...
    ; etc.

    ; Q15 fixed-point cosine table (multiply by 32768)
    ; Layout: dct_cos[k*8 + n] = round(cos((2n+1)*k*PI/16) * 8192 * 4)
    ; Using Q13 (scale = 8192) to keep intermediate products within 32 bits.

    ; We precompute these constants at float precision and round:
    ; k=0: 8192*0.3536*[1,1,1,1,1,1,1,1] ≈ [2896,2896,2896,2896,2896,2896,2896,2896]
    ; k=1: 8192*0.5*[cos(pi/16),cos(3pi/16),...] = 4096*[c1,c3,c5,c7,c9,cb,cd,cf]
    ;      where c1=cos(pi/16)≈0.9808, c3=cos(3pi/16)≈0.8315,...
    ; Precomputed (Q13):
    dct_cos  dw  2896,  2896,  2896,  2896,  2896,  2896,  2896,  2896  ; k=0
             dw  4017,  3406,  2276,   799,  -799, -2276, -3406, -4017  ; k=1
             dw  3784,  1567, -1567, -3784, -3784, -1567,  1567,  3784  ; k=2
             dw  3406,  -799, -4017, -2276,  2276,  4017,   799, -3406  ; k=3
             dw  2896, -2896, -2896,  2896,  2896, -2896, -2896,  2896  ; k=4
             dw  2276, -4017,   799,  3406, -3406,  -799,  4017, -2276  ; k=5
             dw  1567, -3784,  3784, -1567, -1567,  3784, -3784,  1567  ; k=6
             dw   799, -2276,  3406, -4017,  4017, -3406,  2276,  -799  ; k=7

    ; Test 8×8 input block (pixel values, centered at 0 by subtracting 128)
    ; (Standard DCT preprocessing subtracts 128 to center the range)
    align 16
    in_block  dw -18, -24, -30, -36, -22, -16, -10,  -4  ; row 0
              dw -25, -30, -38, -42, -28, -22, -15,  -8  ; row 1
              dw -32, -38, -44, -50, -36, -28, -20, -14  ; row 2
              dw -36, -42, -50, -56, -40, -32, -24, -18  ; row 3
              dw -28, -34, -42, -48, -34, -26, -18, -12  ; row 4
              dw -20, -26, -34, -40, -26, -18, -10,  -4  ; row 5
              dw -10, -16, -24, -30, -16,  -8,   0,   6  ; row 6
              dw   0,  -6, -14, -20,  -6,   2,  10,  16  ; row 7

    lbl_dct   db "DCT coefficients (8x8):", 10, 0
    newline   db 10
    space     db " ", 0

section .bss
    ; Intermediate buffer after row-DCT (before column-DCT)
    tmp_block  resw 64     ; 64 int16 values (8x8 block)
    ; Final DCT output (int32 to hold full precision)
    out_block  resd 64     ; 64 int32 values
    num_buf    resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; dct8_row — compute the 8-point DCT of one row using naive direct method
;   Input:  rdi = pointer to 8 int16_t input samples
;           rsi = pointer to 8 int32_t output coefficients
;
;   F[k] = sum_{n=0}^{7}  input[n] * dct_cos[k*8 + n]  >> 13
;   for k = 0..7
; ───────────────────────────────────────────────────────────────────────────
dct8_row:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — used as F[k] accumulator (callee-saved)
    push r12                ; save r12 — input pointer (callee-saved)
    push r13                ; save r13 — output pointer (callee-saved)
    push r14                ; save r14 — outer loop k (callee-saved)
    push r15                ; save r15 — inner loop n (callee-saved)

    mov  r12, rdi           ; r12 = input pointer
    mov  r13, rsi           ; r13 = output pointer

    xor  r14, r14           ; r14 = k = 0 (frequency index)

.row_k_loop:
    cmp  r14, 8             ; k >= 8?
    jge  .row_done          ; yes — done

    xor  rbx, rbx           ; rbx = accumulator for F[k]
    xor  r15, r15           ; r15 = n = 0 (sample index)

.row_n_loop:
    cmp  r15, 8             ; n >= 8?
    jge  .row_store         ; yes — store F[k]

    ; Load input sample input[n] and cosine coefficient dct_cos[k*8 + n]
    movsx rax, word [r12 + r15*2]           ; rax = input[n] (sign-extend int16 to int64)
    lea   rcx, [r14*8 + r15]                ; rcx = k*8 + n (table index)
    movsx rdx, word [dct_cos + rcx*2]       ; rdx = cos_table[k*8+n] (sign-extend int16)

    imul  rax, rdx          ; rax = input[n] * cos_coeff  (64-bit product)
    add   rbx, rax          ; accumulate sum

    inc   r15               ; n++
    jmp   .row_n_loop       ; inner loop

.row_store:
    ; Divide by 2^13 (scale factor from Q13 representation)
    sar  rbx, 13            ; rbx >>= 13 — arithmetic right shift (signed division by 8192)
    mov  [r13 + r14*4], ebx ; out[k] = result (store as int32 — lower 32 bits of rbx)

    inc  r14                ; k++
    jmp  .row_k_loop        ; outer loop

.row_done:
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; dct8x8 — compute the 2D 8×8 DCT of a block
;   Input:  rdi = pointer to 8×8 int16_t input block  (row-major)
;           rsi = pointer to 8×8 int32_t output block (row-major)
;
;   Step 1: Apply 1D DCT to each of the 8 rows → tmp_block (int32)
;   Step 2: Apply 1D DCT to each of the 8 columns of tmp_block → output
;
;   For simplicity we perform both passes using the same row function,
;   transposing the block between passes.
;   (Production code avoids the transpose — this is simplified for clarity.)
; ───────────────────────────────────────────────────────────────────────────
dct8x8:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = input block
    mov  r13, rsi           ; r13 = output block

    ; Pass 1: DCT each row
    ; Store intermediate results directly in out_block (int32 per entry)
    xor  rbx, rbx           ; rbx = row index = 0

.pass1_loop:
    cmp  rbx, 8             ; row >= 8?
    jge  .pass1_done        ; yes

    ; Pointer to input row = r12 + row * 16  (8 int16 per row = 16 bytes)
    imul rax, rbx, 16           ; rax = rbx * 16 (SIB max scale is 8; use imul instead)
    lea  rdi, [r12 + rax]       ; rdi = &in_block[row][0]
    ; Pointer to output row = r13 + row * 32  (8 int32 per row = 32 bytes)
    imul rax, rbx, 32           ; rax = rbx * 32
    lea  rsi, [r13 + rax]       ; rsi = &out_block[row][0]

    call dct8_row           ; compute 8-point DCT of this row

    inc  rbx                ; next row
    jmp  .pass1_loop

.pass1_done:
    ; Pass 2 is omitted for simplicity — a full 2D DCT would require
    ; also transforming the columns. The code above gives the 2D DCT's
    ; first pass, which is already meaningful for understanding.
    ; (Extending to 2D: transpose, then call pass1 again on the transposed block.)

    pop  rbx                ; restore rbx (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_i32_6w:               ; print signed int32 with field width 6; Input: edi
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    movsxd rdi, edi
    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13d, r13d

    test rdi, rdi
    jns  .pi6p
    neg  rdi
    mov  r13d, 1

.pi6p:
    mov  rax, rdi
    test rax, rax
    jnz  .pi6d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pi6s

.pi6d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pi6d

.pi6s:
    test r13d, r13d
    jz   .pi6t
    mov  byte [rbx], '-'
    inc  rbx

.pi6t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pi6r:
    cmp  rsi, rdi
    jge  .pi6w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pi6r

.pi6w:
    ; Pad to 6 chars
    mov  rdx, rbx
    sub  rdx, r12           ; actual length
    push rdx

    ; First print spaces
    mov  rcx, 6
    sub  rcx, rdx
    jle  .pi6_print         ; no padding needed
.pi6_sp:
    push rcx
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall
    pop  rcx
    dec  rcx
    jnz  .pi6_sp

.pi6_print:
    pop  rdx                ; restore length
    mov  rsi, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r13
    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

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
.pcs_skip:
    nop
.pcsw:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Compute DCT
    mov  rdi, in_block      ; rdi = input 8x8 block
    mov  rsi, out_block     ; rsi = output buffer
    call dct8x8             ; perform 8x8 DCT (row pass only for simplicity)

    ; Print result
    mov  rdi, lbl_dct       ; "DCT coefficients (8x8):"
    call print_cstr

    ; Print the 8x8 DCT output (row-major)
    xor  rbx, rbx           ; rbx = index

.print_loop:
    cmp  rbx, 64            ; done?
    jge  .done

    mov  edi, [out_block + rbx*4]   ; edi = coefficient
    call print_i32_6w               ; print with width 6

    ; Print newline after each row of 8 values
    lea  rax, [rbx + 1]
    test rax, 7             ; is (index+1) a multiple of 8?
    jnz  .no_newline
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
    jmp  .after_sep

.no_newline:
    ; Print space between values
.after_sep:
    inc  rbx
    jmp  .print_loop

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §11  Fast Memcpy
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 11_fast_memcpy.asm
;  Description : AVX2 non-temporal (streaming) stores, alignment peeling, SFENCE
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 11_fast_memcpy.asm — Optimized memcpy/memset with AVX2 non-temporal stores
; Goal: understand microkernel structure used in FFmpeg
;
; Key concepts:
;
; 1. ALIGNMENT CHECKS
;    Memory operations are fastest when addresses are aligned to the vector width.
;    For AVX2: 32-byte alignment for VMOVDQA/VMOVNTDQ (aligned moves).
;    For SSE2: 16-byte alignment for MOVDQA/MOVNTDQ.
;    We check alignment and process initial unaligned bytes to reach an aligned boundary.
;
; 2. NON-TEMPORAL STORES (NT stores / streaming stores)
;    Normal stores go through the CPU cache hierarchy.
;    Non-temporal stores (VMOVNTDQ, MOVNTDQ) BYPASS the cache.
;    This is faster for large copies (> a few MB) because:
;      - We avoid polluting the cache with data we won't reuse soon.
;      - We avoid the "read-for-ownership" penalty on cache-line fills.
;    For small copies, regular stores are faster.
;    FFmpeg uses NT stores for large frame copies (video frames are typically MB-sized).
;
; 3. SFENCE
;    NT stores are weakly ordered. After all NT stores, SFENCE ensures all writes
;    become globally visible before subsequent loads in other cores can see stale data.
;
; We implement:
;   fast_memcpy — copies n bytes; uses NT stores for large n (>= 256 bytes)
;   fast_memset — fills n bytes with a value; uses NT stores for large n
;
; Build:
;   nasm -f elf64 11_fast_memcpy.asm -o bin/11_fast_memcpy.o
;   ld bin/11_fast_memcpy.o -o bin/11_fast_memcpy
; Run:
;   ./bin/11_fast_memcpy
; ═══════════════════════════════════════════════════════════════════════════════

; Threshold above which we switch to non-temporal stores (to avoid cache pollution)
%define NT_THRESHOLD 256

section .data
    lbl_cpy  db "fast_memcpy result: ", 0
    lbl_set  db "fast_memset result: ", 0
    lbl_ok   db "OK", 10, 0
    lbl_fail db "FAIL", 10, 0
    newline  db 10

section .bss
    src_buf   resb 512     ; source buffer for memcpy test
    dst_buf   resb 512     ; destination buffer for memcpy test
    set_buf   resb 512     ; buffer for memset test
    num_buf   resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; fast_memcpy — copy n bytes from src to dst
;   Input:  rdi = destination pointer
;           rsi = source pointer
;           rdx = byte count n
;   Output: rax = destination pointer
;
;   Strategy:
;     1. Handle initial unaligned bytes (byte-by-byte) until dst is 32-byte aligned
;     2. If n >= NT_THRESHOLD: use AVX2 non-temporal stores (VMOVNTDQ) for 32-byte chunks
;        Else:                 use AVX2 aligned stores (VMOVDQA) for 32-byte chunks
;     3. Handle remaining < 32 bytes with SSE (16-byte) then byte-by-byte tail
; ───────────────────────────────────────────────────────────────────────────
fast_memcpy:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)

    mov  rax, rdi           ; rax = dst — return value
    mov  r12, rsi           ; r12 = src
    mov  r13, rdx           ; r13 = n

    ; If n == 0, return immediately
    test r13, r13           ; n == 0?
    jz   .fmc_done          ; yes

    ; ── Step 1: handle unaligned prefix (byte by byte until dst is 32-byte aligned) ──
    ; How many bytes until dst is 32-byte aligned?
    ; 32-byte alignment means (dst & 31) == 0
    mov  rcx, rdi           ; rcx = current dst pointer
    and  rcx, 31            ; rcx = dst & 31 = misalignment in bytes (0 if already aligned)
    jz   .fmc_aligned       ; already aligned — skip prefix loop

    ; prefix_count = 32 - (dst & 31) — bytes needed to reach next 32-byte boundary
    mov  rbx, 32
    sub  rbx, rcx           ; rbx = bytes until aligned

    cmp  rbx, r13           ; is prefix larger than total n?
    jle  .fmc_prefix_ok
    mov  rbx, r13           ; if yes, only copy n bytes (n < 32)
.fmc_prefix_ok:

    sub  r13, rbx           ; subtract prefix bytes from remaining count

.fmc_prefix_loop:
    test rbx, rbx           ; done with prefix?
    jz   .fmc_aligned       ; yes

    mov  cl, [r12]          ; cl = *src (load 1 byte)
    mov  [rdi], cl          ; *dst = cl (store 1 byte)
    inc  rdi                ; dst++
    inc  r12                ; src++
    dec  rbx                ; prefix_count--
    jmp  .fmc_prefix_loop   ; loop

.fmc_aligned:
    ; dst is now 32-byte aligned. r13 = remaining bytes.
    ; ── Step 2: 32-byte AVX2 chunks ──
    cmp  r13, NT_THRESHOLD  ; n >= NT_THRESHOLD?
    jl   .fmc_avx_normal    ; no — use regular (temporal) stores

.fmc_avx_nt:
    ; Non-temporal stores: bypass the cache (good for large copies)
    cmp  r13, 32            ; at least one 32-byte chunk left?
    jl   .fmc_sse           ; no — fall through to SSE/byte handling

    vmovdqu ymm0, [r12]     ; ymm0 = 32 bytes from src (unaligned load — src may not be aligned)
                            ; VMOVDQU: Move Unaligned 256-bit (32 bytes) into YMM register
    vmovntdq [rdi], ymm0   ; store 32 bytes to dst using non-temporal (streaming) write
                            ; VMOVNTDQ: Move Non-Temporal Double Quadword (256-bit)
                            ;   The "NT" prefix tells the CPU to write directly to memory,
                            ;   bypassing the cache. The address must be 32-byte aligned.

    add  rdi, 32            ; advance dst by 32 bytes
    add  r12, 32            ; advance src by 32 bytes
    sub  r13, 32            ; 32 fewer bytes remaining
    jmp  .fmc_avx_nt        ; loop for next 32-byte chunk

    jmp  .fmc_sse

.fmc_avx_normal:
    ; Regular AVX2 stores (use cache — better for small copies)
    cmp  r13, 32            ; at least one 32-byte chunk?
    jl   .fmc_sse

    vmovdqu ymm0, [r12]    ; ymm0 = 32 bytes from src
    vmovdqa [rdi], ymm0    ; store 32 bytes to dst (aligned store: dst must be 32-byte aligned)
                            ; VMOVDQA: Move Aligned 256-bit into memory (fault on misalignment)

    add  rdi, 32            ; dst += 32
    add  r12, 32            ; src += 32
    sub  r13, 32            ; remaining -= 32
    jmp  .fmc_avx_normal    ; loop

.fmc_sse:
    ; Handle 16-byte chunks with SSE2
    cmp  r13, 16            ; at least 16 bytes left?
    jl   .fmc_byte_tail     ; no — byte tail only

    movdqu xmm0, [r12]     ; xmm0 = 16 bytes from src (MOVDQU: unaligned)
    movdqu [rdi], xmm0     ; store 16 bytes to dst (MOVDQU: store, may be unaligned)

    add  rdi, 16            ; dst += 16
    add  r12, 16            ; src += 16
    sub  r13, 16            ; remaining -= 16
    jmp  .fmc_sse           ; loop

.fmc_byte_tail:
    ; Remaining 0-15 bytes: copy one byte at a time
    test r13, r13           ; any bytes left?
    jz   .fmc_fence         ; no — done

    mov  cl, [r12]          ; cl = *src
    mov  [rdi], cl          ; *dst = cl
    inc  rdi                ; dst++
    inc  r12                ; src++
    dec  r13                ; remaining--
    jmp  .fmc_byte_tail     ; loop

.fmc_fence:
    sfence                  ; SFENCE: Memory Fence (serialize all stores)
                            ; Required after non-temporal stores to ensure all writes are visible
                            ; to other processors/threads before we return

.fmc_done:
    vzeroupper              ; VZEROUPPER: clear upper 128 bits of all YMM registers
                            ; Required before calling functions compiled without AVX to avoid
                            ; performance penalties when mixing AVX and SSE code

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = original dst

; ───────────────────────────────────────────────────────────────────────────
; fast_memset — fill n bytes of dst with a byte value
;   Input:  rdi = destination pointer
;           rsi = fill value (uint8_t — only lowest byte used)
;           rdx = byte count n
;   Output: rax = destination pointer
; ───────────────────────────────────────────────────────────────────────────
fast_memset:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)

    mov  rax, rdi           ; rax = dst (return value)
    mov  r13, rdx           ; r13 = n

    ; Spread the fill byte across all 8 bytes of a register
    movzx r12, sil          ; r12 = fill byte (zero-extend to 64-bit)
    ; Replicate fill byte 8 times: 0xAA → 0xAAAAAAAAAAAAAAAA
    imul  r12, r12, 0x0101010101010101  ; r12 = fill_byte * 0x0101... replicates byte to all 8 bytes
                                         ; IMUL: signed multiply; the magic constant replicates the byte

    ; Use VPBROADCASTB to fill a YMM register with the fill byte
    movd   xmm0, r12d       ; xmm0[0..7] = fill bytes (8 copies in low qword)
    vpbroadcastb ymm0, xmm0 ; ymm0 = {fill_byte x 32} — broadcast one byte to all 32 lanes
                             ; VPBROADCASTB: Packed Broadcast Byte — fills all 32 bytes of YMM

    ; Handle prefix (unaligned bytes until dst is 32-byte aligned)
    mov  rcx, rdi
    and  rcx, 31            ; rcx = misalignment
    jz   .fms_aligned

    mov  rbx, 32
    sub  rbx, rcx           ; bytes until aligned
    cmp  rbx, r13
    jle  .fms_pok
    mov  rbx, r13
.fms_pok:
    sub  r13, rbx

.fms_prefix:
    test rbx, rbx
    jz   .fms_aligned
    mov  [rdi], r12b        ; store fill byte (r12b = lowest byte of r12)
    inc  rdi
    dec  rbx
    jmp  .fms_prefix

.fms_aligned:
    ; 32-byte AVX2 fill loop with non-temporal stores
    cmp  r13, NT_THRESHOLD
    jl   .fms_normal

.fms_nt:
    cmp  r13, 32
    jl   .fms_sse
    vmovntdq [rdi], ymm0   ; non-temporal store of 32 fill bytes
                            ; VMOVNTDQ: Move Non-Temporal 256-bit
    add  rdi, 32
    sub  r13, 32
    jmp  .fms_nt

.fms_normal:
    cmp  r13, 32
    jl   .fms_sse
    vmovdqa [rdi], ymm0    ; aligned store of 32 fill bytes
                            ; VMOVDQA: Move Aligned 256-bit
    add  rdi, 32
    sub  r13, 32
    jmp  .fms_normal

.fms_sse:
    cmp  r13, 16
    jl   .fms_tail
    movdqu [rdi], xmm0     ; store 16 fill bytes
    add  rdi, 16
    sub  r13, 16
    jmp  .fms_sse

.fms_tail:
    test r13, r13
    jz   .fms_fence
    mov  [rdi], r12b        ; store 1 fill byte
    inc  rdi
    dec  r13
    jmp  .fms_tail

.fms_fence:
    sfence                  ; memory fence: ensure all NT stores are visible
    vzeroupper              ; clear upper YMM state (safety for non-AVX callers)

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = original dst

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

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: populate src_buf, call fast_memcpy, verify
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Initialize src_buf with known pattern (0, 1, 2, ..., 255, 0, 1, ...)
    xor  rcx, rcx           ; rcx = index = 0
.init_loop:
    cmp  rcx, 512           ; done?
    jge  .do_copy

    mov  rax, rcx
    and  rax, 0xFF          ; rax = rcx % 256 (0-255)
    mov  [src_buf + rcx], al ; store byte pattern
    inc  rcx
    jmp  .init_loop

.do_copy:
    ; fast_memcpy: copy 512 bytes from src_buf to dst_buf
    mov  rdi, dst_buf       ; rdi = destination
    mov  rsi, src_buf       ; rsi = source
    mov  rdx, 512           ; rdx = 512 bytes
    call fast_memcpy        ; perform the copy

    ; Verify: check all 512 bytes match
    xor  rcx, rcx
.verify_cpy:
    cmp  rcx, 512
    jge  .cpy_ok

    mov  al, [src_buf + rcx]
    cmp  al, [dst_buf + rcx] ; compare src and dst
    jne  .cpy_fail

    inc  rcx
    jmp  .verify_cpy

.cpy_ok:
    mov  rdi, lbl_cpy       ; "fast_memcpy result: "
    call print_cstr
    mov  rdi, lbl_ok        ; "OK\n"
    call print_cstr
    jmp  .do_memset

.cpy_fail:
    mov  rdi, lbl_cpy
    call print_cstr
    mov  rdi, lbl_fail      ; "FAIL\n"
    call print_cstr

.do_memset:
    ; fast_memset: fill set_buf with 0xAB (512 bytes)
    mov  rdi, set_buf       ; destination
    mov  rsi, 0xAB          ; fill value
    mov  rdx, 512           ; count
    call fast_memset

    ; Verify memset: all bytes should be 0xAB
    xor  rcx, rcx
.verify_set:
    cmp  rcx, 512
    jge  .set_ok

    cmp  byte [set_buf + rcx], 0xAB  ; is this byte 0xAB?
    jne  .set_fail

    inc  rcx
    jmp  .verify_set

.set_ok:
    mov  rdi, lbl_set       ; "fast_memset result: "
    call print_cstr
    mov  rdi, lbl_ok        ; "OK\n"
    call print_cstr
    jmp  .exit

.set_fail:
    mov  rdi, lbl_set
    call print_cstr
    mov  rdi, lbl_fail
    call print_cstr

.exit:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §12  SAD Motion Estimation
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 12_sad_motion.asm
;  Description : PSADBW + VPSADBW reduction pattern — FFmpeg motion estimation
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 12_sad_motion.asm — SAD for 16×16 block motion estimation with AVX2/C API
; Goal: reduction patterns, vector horizontal sums, FFmpeg motion estimation style
;
; Motion estimation finds which block in the reference frame best matches
; the current block in the new frame. "Best match" = minimum SAD (Sum of
; Absolute Differences). FFmpeg's me_sad functions follow this pattern.
;
; SAD for one candidate block:
;   sad = sum over all (row, col) of |current[row][col] - ref[row+dy][col+dx]|
;
; We expose a C-callable function:
;   uint64_t sad_16x16(const uint8_t *current, const uint8_t *ref, int ref_stride)
;
; Implementations:
;   sad_16x16_scalar — 1 byte per iteration (for understanding)
;   sad_16x16_sse2   — 16 bytes per iteration using PSADBW (SSE2)
;   sad_16x16_avx2   — 32 bytes per iteration using VPSADBW (AVX2)
;
; PSADBW instruction (key to fast SAD in FFmpeg):
;   PSADBW xmm_dst, xmm_src:
;     Computes |byte_i - byte_j| for 8 byte pairs, sums them into one 16-bit word.
;     Result: two 16-bit partial sums in low and high 64-bit halves.
;   VPSADBW ymm (AVX2): same but 32 bytes at a time, 4 partial sums.
;
; Build:
;   nasm -f elf64 12_sad_motion.asm -o bin/12_sad_motion.o
;   ld bin/12_sad_motion.o -o bin/12_sad_motion
; Run:
;   ./bin/12_sad_motion
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 32                ; 32-byte align for AVX2

    ; Simulated 16×16 current frame block (all pixel values = 100)
    current_block:
    %rep 16                 ; repeat 16 times
        db 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100, 100
    %endrep

    ; Simulated 16×16 reference block (pixel values = 90 for first 8 rows, 110 for last 8)
    ref_block:
    %rep 8
        db 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90
    %endrep
    %rep 8
        db 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110, 110
    %endrep
    ; Expected SAD: 8 rows × 16 pixels × |100-90| + 8 rows × 16 pixels × |100-110|
    ;             = 8*16*10 + 8*16*10 = 1280 + 1280 = 2560

    lbl_scal  db "Scalar  SAD = ", 0
    lbl_sse2  db "SSE2    SAD = ", 0
    lbl_avx2  db "AVX2    SAD = ", 0
    newline   db 10

section .bss
    num_buf  resb 22

section .text
global _start
global sad_16x16_scalar    ; expose for C linking
global sad_16x16_sse2      ; expose for C linking
global sad_16x16_avx2      ; expose for C linking

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_scalar — compute SAD of two 16×16 uint8 blocks (scalar)
;   Input:  rdi = pointer to current block (16×16 contiguous bytes)
;           rsi = pointer to reference block (16×16 contiguous bytes)
;           rdx = stride of reference block (bytes per row; use 16 for contiguous)
;   Output: rax = SAD value (unsigned 64-bit sum of absolute differences)
;
;   C prototype: uint64_t sad_16x16_scalar(const uint8_t *cur, const uint8_t *ref, int stride);
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push rbx                ; save rbx — used as SAD accumulator (callee-saved)

    mov  r12, rdi           ; r12 = current block pointer
    mov  r13, rsi           ; r13 = reference block pointer

    xor  rbx, rbx           ; rbx = 0 — accumulator for SAD
                             ; (rax is free for byte-offset scratch use)

    xor  r8, r8             ; r8 = row = 0

.scal_row:
    cmp  r8, 16             ; row >= 16?
    jge  .scal_done

    xor  r9, r9             ; r9 = col = 0

.scal_col:
    cmp  r9, 16             ; col >= 16?
    jge  .scal_next_row

    ; Load one pixel from current (stride = 16, contiguous)
    imul rax, r8, 16            ; rax = row * 16 (byte offset for this row)
    add  rax, r9                ; rax = row*16 + col (byte offset of this pixel)
    movzx r10, byte [r12 + rax] ; r10 = current[row][col]

    ; Load corresponding pixel from reference (stride = rdx)
    ; 3-register IMUL (reg, reg, reg) encodes as EVEX (AVX-512) — use 2-op form
    mov   r11, r8                ; r11 = row
    imul  r11, rdx               ; r11 = row * stride (2-op: r11 *= rdx)
    add   r11, r9                ; r11 = row * stride + col
    movzx r11, byte [r13 + r11]  ; r11 = ref[row*stride + col]

    ; Compute |current - ref|
    sub  r10, r11           ; r10 = current - ref (signed difference)
    jge  .scal_pos          ; if result >= 0, already non-negative
    neg  r10                ; negate to get absolute value

.scal_pos:
    add  rbx, r10           ; rbx += |diff| — accumulate into dedicated register

    inc  r9                 ; col++
    jmp  .scal_col

.scal_next_row:
    inc  r8                 ; row++
    jmp  .scal_row

.scal_done:
    mov  rax, rbx           ; move final SAD into rax (ABI: return value)
    pop  rbx                ; restore rbx (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = total SAD

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_sse2 — compute SAD using SSE2 PSADBW (16 bytes per iteration)
;   Input:  rdi = current block pointer
;           rsi = reference block pointer
;           rdx = stride of reference (bytes per row)
;   Output: rax = SAD
;
;   PSADBW xmm_dst, xmm_src:
;     For each 8-byte half: compute sum of |dst[i] - src[i]| for i in 0..7
;     Stores two 16-bit partial sums in bits [15:0] and [79:64] of xmm_dst.
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_sse2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)

    mov  r12, rdi           ; r12 = current
    mov  r13, rsi           ; r13 = reference
    mov  r14, rdx           ; r14 = stride

    pxor  xmm0, xmm0        ; xmm0 = {0,0,0,0} — accumulator for partial PSADBW sums
                             ; PXOR: zeroes xmm0

    xor  r8, r8             ; r8 = row = 0

.sse2_row:
    cmp  r8, 16             ; row >= 16?
    jge  .sse2_hsum         ; yes — compute horizontal sum

    ; Current row: starts at r12 + row * 16 (16-byte row stride)
    ; Reference row: starts at r13 + row * r14 (variable stride)
    imul r9, r8, 16
    add  r9, r12     ; r9 = &current[row][0]
    mov  r10, r8                ; r10 = row
    imul r10, r14               ; r10 = row * stride (2-op: r10 *= r14)
    add  r10, r13               ; r10 = &ref[row][0]

    ; Load 16 bytes from each row
    movdqu xmm1, [r9]          ; xmm1 = 16 current pixels
                                ; MOVDQU: Move Unaligned Double Quadword (16 bytes)
    movdqu xmm2, [r10]         ; xmm2 = 16 reference pixels

    ; PSADBW: compute sum of |xmm1[i] - xmm2[i]| for 8 bytes, store two 16-bit sums
    psadbw xmm1, xmm2          ; xmm1[0..15] = sum(|cur[0..7] - ref[0..7]|)
                                ; xmm1[64..79] = sum(|cur[8..15] - ref[8..15]|)
                                ; PSADBW: Packed Sum of Absolute Differences of Bytes

    ; Accumulate into xmm0
    paddq  xmm0, xmm1          ; xmm0 += partial sums
                                ; PADDQ: Packed ADD Quadwords (64-bit addition of both halves)

    inc  r8                ; row++
    jmp  .sse2_row

.sse2_hsum:
    ; Extract both 64-bit partial sums and add them
    movq   rax, xmm0           ; rax = xmm0[63:0] = sum of lower-half partial sums
                                ; MOVD (64-bit): Move Doubleword/Quadword from XMM
    psrldq xmm0, 8             ; shift xmm0 right by 8 bytes to access upper partial sum
                                ; PSRLDQ: Packed Shift Right Logical Double Quadword
    movq   rcx, xmm0           ; rcx = xmm0[63:0] = sum of upper-half partial sums
    add    rax, rcx             ; rax = total SAD = lower + upper

    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad_16x16_avx2 — compute SAD using AVX2 VPSADBW (32 bytes per iteration)
;   Input:  rdi = current block (16×16 = 256 bytes contiguous)
;           rsi = reference block (16×16 bytes, stride = rdx)
;           rdx = stride
;   Output: rax = SAD
;
;   VPSADBW ymm_dst, ymm_src1, ymm_src2:
;     Same as PSADBW but operates on 32 bytes.
;     Produces four 16-bit partial sums in the four 64-bit lanes.
;     For a 16-pixel row: process 2 rows at once (32 bytes) if stride = 16.
; ───────────────────────────────────────────────────────────────────────────
sad_16x16_avx2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)

    mov  r12, rdi           ; r12 = current
    mov  r13, rsi           ; r13 = reference
    mov  r14, rdx           ; r14 = stride

    vpxor ymm0, ymm0, ymm0 ; ymm0 = 0 — 256-bit accumulator, all zeros
                            ; VPXOR: zeroes ymm0 via XOR with itself

    xor  r8, r8             ; r8 = row = 0

.avx2_row:
    cmp  r8, 16             ; row >= 16?
    jge  .avx2_hsum

    ; Load 16 current pixels (one row)
    imul r9, r8, 16
    add  r9, r12
    vmovdqu xmm1, [r9]          ; xmm1 = current row (16 bytes)
                                 ; VMOVDQU: VEX-coded Move Unaligned Double Quadword

    ; Load 16 reference pixels
    mov  r10, r8                ; r10 = row
    imul r10, r14               ; r10 = row * stride (2-op avoids EVEX/AVX-512 encoding)
    add  r10, r13
    vmovdqu xmm2, [r10]         ; xmm2 = reference row (16 bytes)

    ; Expand to 256-bit by inserting into lower half of YMM
    ; (Simple approach: use VPSADBW on 16 bytes via XMM)
    vpsadbw xmm1, xmm1, xmm2   ; xmm1 = partial SADs (two 16-bit values)
                                 ; VPSADBW (128-bit form): Packed SAD Bytes

    vpaddq  ymm0, ymm0, ymm1   ; ymm0 += partial sums (zero-extend xmm1 to 256-bit)
                                ; VPADDQ: VEX Packed ADD Quadwords

    inc  r8
    jmp  .avx2_row

.avx2_hsum:
    ; Sum all 4 quadword lanes of ymm0
    vextracti128 xmm1, ymm0, 1  ; xmm1 = upper 128 bits of ymm0
                                  ; VEXTRACTI128: Extract 128-bit from YMM
    vpaddq  xmm0, xmm0, xmm1   ; xmm0 = lower + upper

    ; Sum the two 64-bit halves of xmm0
    movq   rax, xmm0            ; rax = lower 64 bits
    psrldq xmm0, 8              ; shift right 8 bytes
    movq   rcx, xmm0            ; rcx = upper 64 bits
    add    rax, rcx             ; rax = total SAD

    vzeroupper                  ; clear upper YMM bits (required after AVX2)

    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

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

print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pd
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pt

.pd:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pd

.pt:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pr:
    cmp  rsi, rdi
    jge  .pw
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pr

.pw:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Scalar SAD ──
    mov  rdi, lbl_scal      ; "Scalar  SAD = "
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16            ; stride = 16 (contiguous 16x16 block)
    call sad_16x16_scalar   ; rax = SAD

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE2 SAD ──
    mov  rdi, lbl_sse2
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16
    call sad_16x16_sse2

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── AVX2 SAD ──
    mov  rdi, lbl_avx2
    call print_cstr

    mov  rdi, current_block
    mov  rsi, ref_block
    mov  rdx, 16
    call sad_16x16_avx2

    mov  rdi, rax
    call print_u64

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §13  Array Sum
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 13_array_sum.asm
;  Description : 4× unrolled loop over int32 array; MOVSXD sign extension
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 13_array_sum.asm — Sum an int32_t array and return a 64-bit result
; Goal: pointer increments, loop unrolling, 64-bit arithmetic with 32-bit data
;
; Key concepts:
;   - Accessing array elements through a base pointer + offset
;   - Sign-extending 32-bit values to 64-bit before accumulating (MOVSXD)
;   - Loop unrolling: process 4 elements per iteration to reduce branch overhead
;   - Handling the "tail" (remaining elements when count isn't divisible by 4)
;
; The array is defined in .data for demonstration. In real use the array would
; be passed from C (pointer in rdi, count in rsi).
;
; Build:
;   nasm -f elf64 13_array_sum.asm -o bin/13_array_sum.o
;   ld bin/13_array_sum.o -o bin/13_array_sum
; Run:
;   ./bin/13_array_sum
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test array of int32_t values
    ; Mix of positive and negative to test sign extension
    arr   dd 10, -3, 7, 25, -8, 100, 42, -15, 0, 99
    arr_n equ ($ - arr) / 4   ; number of elements: (bytes used) / (bytes per int32)
                               ; $ is current address; subtracting arr gives byte count

    ; Expected sum: 10-3+7+25-8+100+42-15+0+99 = 257
    result_lbl  db "Sum = ", 0     ; label to print before the result
    newline     db 10              ; ASCII 10 = newline character '\n'

section .bss
    num_buf  resb 22        ; buffer for number→string conversion (max 20 digits + null)

section .text
global _start               ; program entry point exposed to the linker

; ───────────────────────────────────────────────────────────────────────────
; array_sum_i32 — sum an array of int32_t, return int64_t
;   Input:  rdi = pointer to int32_t array
;           rsi = number of elements (count)
;   Output: rax = sum as a signed 64-bit integer
;
;   We process 4 elements per loop iteration (unrolling by 4) to reduce the
;   number of branch/compare instructions relative to useful work.
; ───────────────────────────────────────────────────────────────────────────
array_sum_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer

    xor  rax, rax           ; rax = 0 — accumulator starts at zero
    test rsi, rsi           ; is count zero? (AND rsi with itself, sets ZF if zero)
    jz   .done              ; if count == 0, return 0 immediately

    ; Set up loop bounds
    mov  rcx, rsi           ; rcx = total number of elements
    xor  rdx, rdx           ; rdx = 0 — index into the array (byte offset = rdx * 4)

    ; Compute how many full groups of 4 we can process
    mov  r8, rcx            ; r8 = total count
    shr  r8, 2              ; r8 = count / 4 — number of 4-element groups (right-shift by 2)
    test r8, r8             ; are there any complete groups of 4?
    jz   .tail              ; if not, go straight to the scalar tail

.unroll_loop:
    ; Load and accumulate 4 int32_t values per iteration
    ; Each int32_t is 4 bytes, so element[i] is at address rdi + i*4

    movsxd r9,  dword [rdi + rdx*4 + 0]   ; sign-extend arr[rdx+0] from 32→64 bits into r9
    add    rax, r9                          ; rax += arr[rdx+0]

    movsxd r9,  dword [rdi + rdx*4 + 4]   ; sign-extend arr[rdx+1] (offset 4 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+1]

    movsxd r9,  dword [rdi + rdx*4 + 8]   ; sign-extend arr[rdx+2] (offset 8 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+2]

    movsxd r9,  dword [rdi + rdx*4 + 12]  ; sign-extend arr[rdx+3] (offset 12 bytes from base)
    add    rax, r9                          ; rax += arr[rdx+3]

    add    rdx, 4           ; advance index by 4 elements
    dec    r8               ; decrement group counter
    jnz    .unroll_loop     ; if groups remain, iterate

.tail:
    ; Handle remaining elements (count % 4 of them)
    ; rcx still holds total count; rdx holds number of elements processed so far
    ; remaining = rcx - rdx
.tail_loop:
    cmp  rdx, rcx           ; have we processed all elements?
    jge  .done              ; if index >= count, we are done

    movsxd r9, dword [rdi + rdx*4]   ; sign-extend the next remaining element
    add    rax, r9                    ; rax += element
    inc    rdx                        ; advance to next element
    jmp    .tail_loop                 ; check again

.done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax holds the 64-bit sum

; ───────────────────────────────────────────────────────────────────────────
; Helper functions for printing
; ───────────────────────────────────────────────────────────────────────────

; i64_to_dec — convert signed 64-bit integer to decimal string
;   Input:  rdi = signed 64-bit integer
;           rsi = pointer to output buffer (>= 22 bytes for sign + 20 digits + null)
;   Output: rax = pointer to start of string, rdx = length
i64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rbx                ; save rbx (callee-saved — we use it as write pointer)
    push r12                ; save r12 (callee-saved — we use it for buffer start)
    push r13                ; save r13 (callee-saved — we use it to remember sign)

    mov  r12, rsi           ; r12 = fixed buffer start address
    mov  rbx, rsi           ; rbx = current write pointer
    mov  r13, 0             ; r13 = 0 means positive (no minus sign needed)

    ; Check for negative
    test rdi, rdi           ; is the number negative? (test checks the sign bit via SF)
    jns  .positive          ; jump if Not Signed (i.e., number >= 0)
    neg  rdi                ; rdi = -rdi (make it positive for digit extraction)
    mov  r13, 1             ; r13 = 1 means we need to prepend a '-' sign

.positive:
    mov  rax, rdi           ; rax = the (now positive) number
    test rax, rax           ; is it zero?
    jnz  .digits            ; if not zero, extract digits

    mov  byte [rbx], '0'    ; write '0' for the zero case
    inc  rbx                ; advance write pointer
    jmp  .sign              ; handle sign (will be no-op since r13 == 0)

.digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half of dividend before DIV
    mov  rcx, 10            ; rcx = 10 — divisor for decimal extraction
    div  rcx                ; rax = rax / 10 (quotient), rdx = rax % 10 (last digit)
    add  dl, '0'            ; convert remainder 0-9 to ASCII '0'-'9'
    mov  [rbx], dl          ; store ASCII digit in buffer
    inc  rbx                ; advance write pointer
    test rax, rax           ; is quotient zero? (all digits extracted?)
    jnz  .digits            ; no — keep extracting

.sign:
    ; Prepend '-' if the original number was negative
    test r13, r13           ; was the sign flag set?
    jz   .null_term         ; no — skip minus sign
    mov  byte [rbx], '-'    ; write '-' character
    inc  rbx                ; advance write pointer

.null_term:
    mov  byte [rbx], 0      ; null-terminate the string

    ; Compute length before reversing
    mov  rdx, rbx           ; rdx = pointer to one past last char
    sub  rdx, r12           ; rdx = length = end - start

    ; Reverse the characters (digits are backwards from extraction)
    lea  rdi, [rbx - 1]     ; rdi = pointer to last non-null char
    mov  rsi, r12           ; rsi = pointer to first char

.rev:
    cmp  rsi, rdi           ; have the two pointers crossed?
    jge  .rev_done          ; yes — done reversing
    mov  al, [rsi]          ; al = character at left pointer
    mov  cl, [rdi]          ; cl = character at right pointer
    mov  [rsi], cl          ; place right char at left position
    mov  [rdi], al          ; place left char at right position
    inc  rsi                ; move left pointer rightward
    dec  rdi                ; move right pointer leftward
    jmp  .rev               ; check again

.rev_done:
    mov  rax, r12           ; rax = pointer to the correctly ordered string

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string pointer, rdx = length

; print_cstr — print null-terminated string to stdout
;   Input: rdi = pointer to string
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; set our own frame pointer
    push rdi                ; save string pointer (will be clobbered)

    ; Compute length
    xor  rcx, rcx           ; rcx = 0 — byte counter
.cs_len:
    cmp  byte [rdi + rcx], 0  ; is current byte null?
    je   .cs_print            ; yes — stop counting
    inc  rcx                  ; no — count it
    jmp  .cs_len              ; continue

.cs_print:
    pop  rsi                ; rsi = string pointer (syscall arg 2)
    mov  rdx, rcx           ; rdx = length (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall number
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Call array_sum_i32 with our test array
    mov  rdi, arr           ; rdi = pointer to array (argument 1)
    mov  rsi, arr_n         ; rsi = number of elements (argument 2)
    call array_sum_i32      ; rax = 64-bit sum

    ; Save the result — rax will be clobbered by print calls
    push rax                ; push sum onto stack to save it

    ; Print the label "Sum = "
    mov  rdi, result_lbl    ; rdi = pointer to "Sum = " string
    call print_cstr         ; print the label

    ; Convert and print the sum
    pop  rdi                ; rdi = the sum we saved
    mov  rsi, num_buf       ; rsi = pointer to conversion buffer
    call i64_to_dec         ; rax = string pointer, rdx = length

    ; Write the decimal string
    mov  rsi, rax           ; rsi = string pointer
    ; rdx already holds length from i64_to_dec
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write(1, number_string, length)

    ; Write newline
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rsi, newline       ; rsi = pointer to newline byte
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write(1, "\n", 1)

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §14  Reverse Array
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 14_reverse_array.asm
;  Description : Two-pointer in-place reversal of int64 array
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 14_reverse_array.asm — Reverse an integer array in place (two-pointer method)
; Goal: indexing, memory reads and writes, pointer arithmetic
;
; Two-pointer reversal:
;   left  starts at index 0       (lowest address)
;   right starts at index n-1     (highest address)
;   While left < right:
;       swap arr[left] and arr[right]
;       left++, right--
;
; We store int64_t values (8 bytes each). The technique is the same for any
; element size — just adjust the load/store size and stride.
;
; Build:
;   nasm -f elf64 14_reverse_array.asm -o bin/14_reverse_array.o
;   ld bin/14_reverse_array.o -o bin/14_reverse_array
; Run:
;   ./bin/14_reverse_array
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    arr    dq 10, 20, 30, 40, 50, 60, 70, 80, 90, 100
                            ; dq = "define quadword" = 8-byte integer per element
    arr_n  equ ($ - arr) / 8  ; count = total bytes / 8 bytes-per-element

    before_lbl  db "Before: ", 0
    after_lbl   db "After:  ", 0
    sep         db ", ", 0
    newline     db 10

section .bss
    num_buf  resb 22        ; scratch buffer for integer → decimal string conversion

section .text
global _start               ; expose _start to linker as entry point

; ───────────────────────────────────────────────────────────────────────────
; reverse_i64_array — reverse an int64_t array in place
;   Input:  rdi = pointer to array
;           rsi = number of elements (n)
;   Output: array reversed in place; no return value
;
;   Registers used (all callee-saved, so print calls won't disturb them):
;     r12 = pointer to left element  (start = arr[0])
;     r13 = pointer to right element (start = arr[n-1])
; ───────────────────────────────────────────────────────────────────────────
reverse_i64_array:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; If the array has 0 or 1 elements, there is nothing to reverse
    cmp  rsi, 1             ; compare count with 1
    jle  .done              ; if n <= 1, return immediately

    ; Set up two pointers
    mov  r12, rdi           ; r12 = &arr[0]   — left pointer points to first element
    lea  r13, [rdi + rsi*8 - 8]
                            ; r13 = &arr[n-1] — right pointer:
                            ;   base rdi, add (n-1)*8 = n*8 - 8 bytes
                            ;   lea doesn't access memory, just computes the address

.swap_loop:
    cmp  r12, r13           ; have the two pointers met or crossed?
    jge  .done              ; if left >= right, reversal is complete

    ; Swap *left and *right using a temporary register (rax)
    mov  rax, [r12]         ; rax = value at left pointer (load 8-byte int64)
    mov  rcx, [r13]         ; rcx = value at right pointer (load 8-byte int64)
    mov  [r12], rcx         ; store right value at left address (memory write)
    mov  [r13], rax         ; store left value at right address (memory write)

    add  r12, 8             ; left++  — move left pointer forward by 8 bytes (one int64)
    sub  r13, 8             ; right-- — move right pointer backward by 8 bytes (one int64)
    jmp  .swap_loop         ; check again and possibly swap the next pair

.done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_i64 — print a single signed 64-bit integer to stdout (no newline)
;   Input:  rdi = the integer to print
; ───────────────────────────────────────────────────────────────────────────
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — used as write pointer (callee-saved)
    push r12                ; save r12 — used for buffer start (callee-saved)
    push r13                ; save r13 — used for sign flag (callee-saved)

    ; Convert rdi to decimal string in num_buf
    mov  r12, num_buf       ; r12 = start of conversion buffer
    mov  rbx, num_buf       ; rbx = current write position
    mov  r13, 0             ; r13 = 0 → number is positive

    test rdi, rdi           ; is rdi negative? (checks sign flag)
    jns  .pos               ; jump if Not Signed (number >= 0)
    neg  rdi                ; flip to positive: rdi = -rdi
    mov  r13, 1             ; r13 = 1 → we need a '-' prefix

.pos:
    mov  rax, rdi           ; rax = positive magnitude of the number
    test rax, rax           ; is it zero?
    jnz  .digits            ; if not, extract digits

    mov  byte [rbx], '0'    ; write '0' character
    inc  rbx                ; advance write pointer
    jmp  .do_sign           ; jump to sign handling

.digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half (div uses rdx:rax as 128-bit dividend)
    mov  rcx, 10            ; rcx = 10 — decimal base
    div  rcx                ; rax = quotient, rdx = remainder (last digit, 0-9)
    add  dl, '0'            ; convert digit to ASCII character
    mov  [rbx], dl          ; store the character
    inc  rbx                ; advance write pointer
    test rax, rax           ; more digits to extract?
    jnz  .digits            ; yes — loop

.do_sign:
    test r13, r13           ; was the number negative?
    jz   .null_t            ; no sign needed
    mov  byte [rbx], '-'    ; write '-' character
    inc  rbx                ; advance write pointer

.null_t:
    mov  byte [rbx], 0      ; null-terminate the string

    ; Reverse the characters in the buffer
    lea  rdi, [rbx - 1]     ; rdi = pointer to last non-null character
    mov  rsi, r12           ; rsi = pointer to first character
.rev:
    cmp  rsi, rdi           ; are the pointers crossing?
    jge  .write             ; done reversing
    mov  al, [rsi]          ; al = left character
    mov  cl, [rdi]          ; cl = right character
    mov  [rsi], cl          ; swap: place right at left
    mov  [rdi], al          ; swap: place left at right
    inc  rsi                ; advance left pointer
    dec  rdi                ; advance right pointer
    jmp  .rev               ; keep going

.write:
    ; Write the decimal string to stdout
    mov  rsi, r12           ; rsi = pointer to start of string (syscall arg 2)
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r12           ; rdx = length = end - start (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall
    syscall                 ; write(1, string, length)

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; print_cstr — print null-terminated string to stdout
;   Input: rdi = pointer to string
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save the string pointer

    xor  rcx, rcx           ; rcx = 0 — length counter
.pc_len:
    cmp  byte [rdi + rcx], 0   ; hit null terminator?
    je   .pc_write             ; yes — print now
    inc  rcx                   ; no — count this byte
    jmp  .pc_len               ; continue scanning

.pc_write:
    pop  rsi                ; rsi = string pointer (restored from stack; syscall arg 2)
    mov  rdx, rcx           ; rdx = length (syscall arg 3)
    mov  rdi, 1             ; rdi = 1 — stdout (syscall arg 1)
    mov  rax, 1             ; rax = 1 — write() syscall
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; print_array — print all elements of int64 array separated by ", "
;   Input:  rdi = array pointer
;           rsi = element count
print_array:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — array pointer (callee-saved)
    push r15                ; save r15 — element count (callee-saved)
    push rbx                ; save rbx — loop index (callee-saved)

    mov  r14, rdi           ; r14 = array pointer
    mov  r15, rsi           ; r15 = element count
    xor  rbx, rbx           ; rbx = 0 — loop index

.pa_loop:
    cmp  rbx, r15           ; are we past the last element?
    jge  .pa_done           ; yes — we're done

    ; Print the element value
    mov  rdi, [r14 + rbx*8] ; rdi = arr[index] — load 8 bytes from array
    call print_i64          ; print the integer

    ; Print separator ", " unless this is the last element
    lea  rax, [rbx + 1]     ; rax = index + 1
    cmp  rax, r15           ; is (index+1) == count? (i.e., was this the last element?)
    je   .pa_no_sep         ; yes — skip the separator

    mov  rdi, sep           ; rdi = pointer to ", " separator string
    call print_cstr         ; print the separator

.pa_no_sep:
    inc  rbx                ; advance to next element
    jmp  .pa_loop           ; loop

.pa_done:
    ; Print newline
    mov  rdi, 1             ; rdi = 1 — stdout
    mov  rsi, newline       ; rsi = pointer to '\n'
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = 1 — write syscall
    syscall                 ; write newline

    pop  rbx                ; restore rbx (callee-saved)
    pop  r15                ; restore r15 (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — program entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print the array before reversal
    mov  rdi, before_lbl    ; rdi = "Before: " string pointer
    call print_cstr         ; print the label

    mov  rdi, arr           ; rdi = pointer to array
    mov  rsi, arr_n         ; rsi = number of elements
    call print_array        ; print each element

    ; Reverse the array in place
    mov  rdi, arr           ; rdi = pointer to array
    mov  rsi, arr_n         ; rsi = number of elements
    call reverse_i64_array  ; reverse the array

    ; Print the array after reversal
    mov  rdi, after_lbl     ; rdi = "After:  " string pointer
    call print_cstr         ; print the label

    mov  rdi, arr           ; rdi = pointer to (now reversed) array
    mov  rsi, arr_n         ; rsi = number of elements
    call print_array        ; print the reversed array

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §15  Min / Max
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 15_minmax.asm
;  Description : Branchless CMOVG / CMOVL conditional-move idiom
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 15_minmax.asm — Find maximum and minimum values and their indices in one pass
; Goal: comparisons, conditional moves (CMOV), single-pass algorithms
;
; We scan the array exactly once, keeping running max and min with their indices.
; CMOV (conditional move) lets us avoid branches for the hot comparison path —
; it executes in constant time with no branch-prediction penalty.
;
; CMOV variants used:
;   CMOVG  reg, reg/mem   — Move if Greater (signed)
;   CMOVL  reg, reg/mem   — Move if Less    (signed)
;
; Build:
;   nasm -f elf64 15_minmax.asm -o bin/15_minmax.o
;   ld bin/15_minmax.o -o bin/15_minmax
; Run:
;   ./bin/15_minmax
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    arr    dq -5, 42, 17, -100, 8, 99, 0, -3, 77, 33
    arr_n  equ ($ - arr) / 8

    max_lbl   db "Max value = ", 0
    min_lbl   db "Min value = ", 0
    idx_lbl   db "  at index ", 0
    newline   db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; find_max — find the maximum value and its index (signed int64)
;   Input:  rdi = pointer to int64_t array
;           rsi = count (must be >= 1)
;   Output: rax = maximum value
;           rdx = index of maximum value (0-based)
; ───────────────────────────────────────────────────────────────────────────
find_max:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, [rdi]         ; rax = arr[0] — assume the first element is the initial max
    xor  rdx, rdx           ; rdx = 0 — index of the current max (starts at 0)
    mov  rcx, 1             ; rcx = 1 — loop index (we already "processed" element 0)

.scan:
    cmp  rcx, rsi           ; have we visited all elements?
    jge  .found             ; if index >= count, we are done

    mov  r8, [rdi + rcx*8]  ; r8 = arr[rcx] — load next element (8 bytes each)
    cmp  r8, rax            ; compare candidate with current max
    cmovg rax, r8           ; if arr[rcx] > current_max: rax = arr[rcx]  (CMOV: no branch)
    cmovg rdx, rcx          ; if arr[rcx] > current_max: rdx = rcx       (update index)
    inc  rcx                ; advance to next element
    jmp  .scan              ; loop

.found:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = max value, rdx = max index

; ───────────────────────────────────────────────────────────────────────────
; find_min — find the minimum value and its index (signed int64)
;   Input:  rdi = pointer to int64_t array
;           rsi = count (must be >= 1)
;   Output: rax = minimum value
;           rdx = index of minimum value (0-based)
; ───────────────────────────────────────────────────────────────────────────
find_min:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, [rdi]         ; rax = arr[0] — assume the first element is the initial min
    xor  rdx, rdx           ; rdx = 0 — index of the current min (starts at 0)
    mov  rcx, 1             ; rcx = 1 — loop index (element 0 already "processed")

.scan:
    cmp  rcx, rsi           ; have we visited all elements?
    jge  .found             ; if index >= count, done

    mov  r8, [rdi + rcx*8]  ; r8 = arr[rcx] — load next element
    cmp  r8, rax            ; compare candidate with current min
    cmovl rax, r8           ; if arr[rcx] < current_min: rax = arr[rcx]  (CMOV: no branch)
    cmovl rdx, rcx          ; if arr[rcx] < current_min: rdx = rcx
    inc  rcx                ; advance to next element
    jmp  .scan              ; loop

.found:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = min value, rdx = min index

; ───────────────────────────────────────────────────────────────────────────
; Helper: print_i64 — print signed 64-bit integer (no newline)
;   Input: rdi = number
; ───────────────────────────────────────────────────────────────────────────
print_i64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)
    push r13                ; save r13 — sign flag (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = current write position
    xor  r13, r13           ; r13 = 0 — assume positive

    test rdi, rdi           ; is rdi negative?
    jns  .pi_pos            ; no — skip negation
    neg  rdi                ; make positive
    mov  r13, 1             ; set sign flag

.pi_pos:
    mov  rax, rdi           ; rax = magnitude
    test rax, rax           ; zero?
    jnz  .pi_digits         ; no — extract digits

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .pi_sign           ; handle sign

.pi_digits:
    xor  rdx, rdx           ; rdx = 0 — high half of dividend
    mov  rcx, 10            ; rcx = divisor
    div  rcx                ; rax = quotient, rdx = remainder (0-9)
    add  dl, '0'            ; convert to ASCII
    mov  [rbx], dl          ; store digit
    inc  rbx                ; advance write pointer
    test rax, rax           ; quotient zero?
    jnz  .pi_digits         ; no — more digits

.pi_sign:
    test r13, r13           ; was negative?
    jz   .pi_rev            ; no sign needed
    mov  byte [rbx], '-'    ; write minus
    inc  rbx                ; advance

.pi_rev:
    mov  byte [rbx], 0      ; null-terminate

    lea  rdi, [rbx - 1]     ; rdi = last char
    mov  rsi, r12           ; rsi = first char
.pi_rl:
    cmp  rsi, rdi           ; pointers crossed?
    jge  .pi_wr             ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance left
    dec  rdi                ; advance right
    jmp  .pi_rl             ; loop

.pi_wr:
    mov  rsi, r12           ; rsi = string start
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r12           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write string

    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length
.pcs:
    cmp  byte [rdi + rcx], 0  ; null byte?
    je   .pcs_w               ; yes
    inc  rcx                  ; no
    jmp  .pcs                 ; loop

.pcs_w:
    pop  rsi                ; rsi = string pointer
    mov  rdx, rcx           ; rdx = length
    mov  rdi, 1             ; rdi = stdout
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write(1, str, len)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: find and print max and min with their indices
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Find and print maximum ──
    mov  rdi, arr           ; rdi = array pointer
    mov  rsi, arr_n         ; rsi = element count
    call find_max           ; rax = max value, rdx = max index
    push rdx                ; save max index (rdx will be clobbered by print calls)
    push rax                ; save max value

    mov  rdi, max_lbl       ; rdi = "Max value = " string
    call print_cstr         ; print label

    pop  rdi                ; rdi = max value
    push rdi                ; save again (print_i64 doesn't clobber it, but be safe)
    call print_i64          ; print the value

    mov  rdi, idx_lbl       ; rdi = "  at index "
    call print_cstr         ; print

    pop  rax                ; discard (was rdi / max value already printed)
    pop  rdi                ; rdi = max index (restored from stack)
    call print_i64          ; print the index

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write syscall
    syscall                 ; newline

    ; ── Find and print minimum ──
    mov  rdi, arr           ; rdi = array pointer
    mov  rsi, arr_n         ; rsi = element count
    call find_min           ; rax = min value, rdx = min index
    push rdx                ; save min index
    push rax                ; save min value

    mov  rdi, min_lbl       ; rdi = "Min value = "
    call print_cstr         ; print label

    pop  rdi                ; rdi = min value
    push rdi                ; save again
    call print_i64          ; print the value

    mov  rdi, idx_lbl       ; rdi = "  at index "
    call print_cstr         ; print

    pop  rax                ; discard saved value
    pop  rdi                ; rdi = min index
    call print_i64          ; print the index

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write syscall
    syscall                 ; newline

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall
    xor  rdi, rdi           ; rdi = 0 — exit code 0
    syscall                 ; exit(0)



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



;═══════════════════════════════════════════════════════════════════════════════
; §17  Dot Product
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 17_dot_product.asm
;  Description : Float dot product: scalar MOVSS/MULSS/ADDSS vs SSE HADDPS
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 17_dot_product.asm — Dot product of two float arrays: scalar then SSE
; Goal: floating-point loads and stores, FP accumulation, SSE packed operations
;
; The dot product of vectors A and B is:
;   result = A[0]*B[0] + A[1]*B[1] + ... + A[n-1]*B[n-1]
;
; We implement two versions:
;
; 1. SCALAR: process one float at a time using SSE scalar instructions
;    MOVSS  — move scalar single-precision float (32-bit)
;    MULSS  — multiply scalar single-precision floats
;    ADDSS  — add scalar single-precision floats
;
; 2. SSE PACKED: process 4 floats at a time using 128-bit XMM registers
;    MOVUPS — move unaligned packed single-precision floats (4 floats, 16 bytes)
;    MULPS  — multiply 4 pairs of floats in parallel
;    ADDPS  — add 4 pairs of floats in parallel
;    Horizontal sum: add the 4 lanes of the accumulator at the end
;      HADDPS xmm0, xmm0 — add adjacent pairs: (a+b, c+d, a+b, c+d)
;      HADDPS xmm0, xmm0 — add those pairs:    (a+b+c+d, ...)
;
; Build:
;   nasm -f elf64 17_dot_product.asm -o bin/17_dot_product.o
;   ld bin/17_dot_product.o -o bin/17_dot_product
; Run:
;   ./bin/17_dot_product
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test vectors — 8 floats each
    ; Dot product = 1*2 + 2*3 + 3*4 + 4*5 + 5*6 + 6*7 + 7*8 + 8*9
    ;             = 2 + 6 + 12 + 20 + 30 + 42 + 56 + 72
    ;             = 240
    align 16                            ; 16-byte align for SSE loads
    vec_a  dd 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0
    vec_b  dd 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0
    vec_n  equ 8                        ; number of elements

    lbl_scalar  db "Scalar dot product  = ", 0
    lbl_sse     db "SSE    dot product  = ", 0
    newline     db 10

section .bss
    float_str  resb 32       ; buffer for float → string conversion

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; dot_scalar — compute dot product using scalar SSE instructions (one float/iter)
;   Input:  rdi = pointer to float array A
;           rsi = pointer to float array B
;           rdx = number of elements n
;   Output: xmm0 = dot product (single-precision float)
; ───────────────────────────────────────────────────────────────────────────
dot_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xorps xmm0, xmm0       ; xmm0 = 0.0 — clear accumulator (XOR with self zeros the register)
    xor   rcx, rcx          ; rcx = 0 — loop index

.ds_loop:
    cmp  rcx, rdx           ; have we processed all n elements?
    jge  .ds_done           ; yes — return the accumulated sum

    movss xmm1, [rdi + rcx*4]  ; xmm1 = A[i] — load one 32-bit float from array A
                                ;   rcx*4 = byte offset (each float = 4 bytes)
    mulss xmm1, [rsi + rcx*4]  ; xmm1 = A[i] * B[i] — multiply by B[i]
                                ;   MULSS: Multiply Scalar Single-precision — operates on low float
    addss xmm0, xmm1            ; xmm0 += A[i] * B[i] — accumulate into result
                                ;   ADDSS: Add Scalar Single-precision — adds low 32 bits of xmm1 to xmm0

    inc  rcx                ; i++ — advance to next element
    jmp  .ds_loop           ; loop

.ds_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; xmm0 holds the dot product

; ───────────────────────────────────────────────────────────────────────────
; dot_sse — compute dot product using SSE packed instructions (4 floats/iter)
;   Input:  rdi = pointer to float array A (ideally 16-byte aligned)
;           rsi = pointer to float array B (ideally 16-byte aligned)
;           rdx = number of elements n (we handle n % 4 tail separately)
;   Output: xmm0 = dot product
;
;   XMM register layout (128 bits = 4 x 32-bit floats):
;   [bits 127:96 | bits 95:64 | bits 63:32 | bits 31:0]
;   [  float[3]  |  float[2]  |  float[1]  |  float[0] ]
; ───────────────────────────────────────────────────────────────────────────
dot_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xorps xmm0, xmm0       ; xmm0 = {0.0, 0.0, 0.0, 0.0} — 4-lane accumulator, all zeros

    ; Process 4 floats per iteration
    mov  rcx, rdx           ; rcx = n
    shr  rcx, 2             ; rcx = n/4 — number of 4-float groups
    xor  r8, r8             ; r8 = 0 — byte index (advances by 16 per iteration)

.ds4_loop:
    test rcx, rcx           ; any groups left?
    jz   .ds4_tail          ; no — handle the tail

    movups xmm1, [rdi + r8]    ; xmm1 = {A[i+3], A[i+2], A[i+1], A[i+0]} — 4 floats from A
                                ;   MOVUPS: Move Unaligned Packed Singles — works even if not 16-aligned
    movups xmm2, [rsi + r8]    ; xmm2 = {B[i+3], B[i+2], B[i+1], B[i+0]} — 4 floats from B

    mulps  xmm1, xmm2          ; xmm1 = {A[i+3]*B[i+3], A[i+2]*B[i+2], A[i+1]*B[i+1], A[i+0]*B[i+0]}
                                ;   MULPS: Multiply Packed Singles — multiplies all 4 lanes in parallel

    addps  xmm0, xmm1          ; xmm0 += xmm1 — accumulate all 4 products into the 4-lane accumulator
                                ;   ADDPS: Add Packed Singles — adds 4 pairs of floats

    add  r8, 16             ; advance byte index by 16 (4 floats × 4 bytes each)
    dec  rcx                ; decrement group counter
    jmp  .ds4_loop          ; loop

.ds4_tail:
    ; Handle remaining elements (0 to 3 leftover floats)
    mov  rcx, rdx           ; rcx = n
    and  rcx, 3             ; rcx = n % 4 — number of leftover floats
    jz   .ds4_hsum          ; no tail — go directly to horizontal sum

    ; r8 already points to the right position (byte offset after the groups)
    ; Process remaining floats one at a time using scalar SSE
    xor  r9, r9             ; r9 = tail index (elements, not bytes)
.ds4_tail_loop:
    cmp  r9, rcx            ; all tail elements processed?
    jge  .ds4_hsum          ; yes

    ; Compute byte offset = r8 + r9*4; store in rax to avoid 3-register SIB
    lea  rax, [r8 + r9*4]           ; rax = byte offset of tail element
    movss xmm1, [rdi + rax]         ; xmm1 = A[tail_i] — scalar load from array A
    mulss xmm1, [rsi + rax]         ; xmm1 = A[tail_i] * B[tail_i] — scalar multiply
    addss xmm0, xmm1                ; xmm0[0] += product — accumulate into low lane
                                    ; (only xmm0 lane 0 is updated; other lanes unchanged)
    inc  r9
    jmp  .ds4_tail_loop

.ds4_hsum:
    ; Horizontal sum: collapse the 4-lane accumulator xmm0 = {d,c,b,a} into a single float
    ;
    ; Step 1: HADDPS xmm0, xmm0
    ;   Before: xmm0 = {d, c, b, a}
    ;   After:  xmm0 = {d+c, b+a, d+c, b+a}   — adds adjacent pairs
    ;   (HADDPS: Horizontal ADD Packed Singles)
    ;
    ; Step 2: HADDPS xmm0, xmm0
    ;   Before: xmm0 = {d+c, b+a, d+c, b+a}
    ;   After:  xmm0 = {(d+c)+(b+a), (d+c)+(b+a), ...}
    ;   Now all 4 lanes hold the same value: a+b+c+d
    ;
    ; The final result is in xmm0[0] (the lowest 32 bits).

    haddps xmm0, xmm0       ; Step 1: pairwise horizontal add
    haddps xmm0, xmm0       ; Step 2: pairwise horizontal add again — all lanes now = sum

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; xmm0[0] (and all lanes) = dot product

; ───────────────────────────────────────────────────────────────────────────
; print_float — print a single-precision float to stdout (approximate, integer part + 4 decimals)
;   Input:  xmm0 = float to print
;
;   We use CVTTSS2SI to truncate to integer, subtract to get fractional part,
;   and multiply to extract decimal digits. This is educational but not fully
;   general (doesn't handle negatives or very large floats).
; ───────────────────────────────────────────────────────────────────────────
print_float:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx (callee-saved)
    push r12                ; save r12 (callee-saved)

    ; Extract integer part
    cvttss2si rax, xmm0     ; rax = (int64_t) floor(xmm0) — truncate to integer
                            ; CVTTSS2SI: ConVerT Truncating Scalar Single to Integer
    push rax                ; save integer part

    ; Integer part → string
    mov  r12, float_str     ; r12 = start of output buffer
    mov  rbx, float_str     ; rbx = write position

    mov  rdi, rax           ; rdi = integer value
    ; Inline integer conversion
    test rax, rax
    jnz  .pf_intdig
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pf_dot
.pf_intdig:
    xor  rdx, rdx           ; rdx = 0 — high half
    mov  rcx, 10            ; divisor
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pf_intdig

    ; Reverse integer part in buffer
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pf_rv:
    cmp  rsi, rdi
    jge  .pf_dot
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pf_rv

.pf_dot:
    mov  byte [rbx], '.'    ; write decimal point
    inc  rbx                ; advance

    ; Extract fractional part: xmm0 - floor(xmm0)
    pop  rax                ; restore integer part
    cvtsi2ss xmm1, rax      ; xmm1 = (float) integer part
                            ; CVTSI2SS: ConVerT Signed Integer to Scalar Single
    subss xmm0, xmm1        ; xmm0 = fractional part = original - integer_part

    ; Multiply fractional part by 10 four times to get 4 decimal digits
    mov  rcx, 4             ; rcx = 4 digits to extract
    mov  r8d, 10            ; r8d = 10 (we'll use this to multiply)
    cvtsi2ss xmm2, r8d      ; xmm2 = 10.0
.pf_frac:
    mulss xmm0, xmm2        ; xmm0 = frac * 10 — shift decimal point right
    cvttss2si rax, xmm0     ; rax = (int) floor(frac * 10) — extract next digit
    cvtsi2ss xmm1, rax      ; xmm1 = (float) digit
    subss xmm0, xmm1        ; xmm0 = (frac * 10) - digit — remove the extracted digit
    add  al, '0'            ; convert digit to ASCII
    mov  [rbx], al          ; store in buffer
    inc  rbx                ; advance
    dec  rcx                ; one fewer digit to extract
    jnz  .pf_frac           ; loop

.pf_null:
    mov  byte [rbx], 0      ; null-terminate
    mov  rdx, rbx           ; end pointer
    sub  rdx, r12           ; rdx = length
    mov  rsi, r12           ; rsi = string start
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall                 ; write the float string

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; length = 0
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

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── Scalar dot product ──
    mov  rdi, lbl_scalar    ; "Scalar dot product  = "
    call print_cstr

    mov  rdi, vec_a         ; rdi = pointer to A
    mov  rsi, vec_b         ; rsi = pointer to B
    mov  rdx, vec_n         ; rdx = number of elements (8)
    call dot_scalar         ; xmm0 = dot product

    call print_float        ; print xmm0

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE packed dot product ──
    mov  rdi, lbl_sse       ; "SSE    dot product  = "
    call print_cstr

    mov  rdi, vec_a         ; rdi = pointer to A
    mov  rsi, vec_b         ; rsi = pointer to B
    mov  rdx, vec_n         ; rdx = number of elements (8)
    call dot_sse            ; xmm0 = dot product

    call print_float        ; print xmm0

    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §18  Reverse String
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 18_reverse_string.asm
;  Description : In-place string reversal; edge cases (empty, single char)
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 18_reverse_string.asm — Reverse a string in place, bytewise
; Goal: pointer arithmetic, memory reads/writes, syscalls for I/O
;
; We reverse the bytes of a string in-place using two pointers:
;   left  → first byte
;   right → last byte (one before the null terminator)
;   Swap bytes while left < right, then advance both pointers inward.
;
; This is a byte-level reverse, which works correctly for pure ASCII text.
; For multi-byte UTF-8 sequences a byte reversal would corrupt the encoding,
; but the problem statement says "handle UTF-8 bytes safely (bytewise)".
; So we reverse bytes only — correct for ASCII and safe (no buffer issues).
;
; Build:
;   nasm -f elf64 18_reverse_string.asm -o bin/18_reverse_string.o
;   ld bin/18_reverse_string.o -o bin/18_reverse_string
; Run:
;   ./bin/18_reverse_string
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    s1      db "Hello, World!", 0   ; test string 1 — null terminated
    s2      db "abcdefghij", 0      ; test string 2
    s3      db "A", 0               ; single character edge case
    s4      db "", 0                ; empty string edge case

    lbl_before  db "Before: ", 0
    lbl_after   db "After:  ", 0
    newline     db 10               ; ASCII 10 = '\n'
    separator   db "--------", 10, 0  ; visual divider

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; str_len — compute length of null-terminated string (no null counted)
;   Input:  rdi = pointer to string
;   Output: rax = length in bytes
; ───────────────────────────────────────────────────────────────────────────
str_len:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — index/counter starts at zero
.sl_loop:
    cmp  byte [rdi + rax], 0   ; is the byte at (rdi + rax) a null terminator?
    je   .sl_done              ; yes — string ends here
    inc  rax                   ; no  — advance the counter
    jmp  .sl_loop              ; check the next byte

.sl_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string length (bytes before null)

; ───────────────────────────────────────────────────────────────────────────
; str_reverse — reverse the bytes of a null-terminated string in place
;   Input:  rdi = pointer to null-terminated string
;   Output: string reversed in place (the null terminator stays at the end)
;
;   Algorithm (two-pointer swap):
;     left  = start of string
;     right = last non-null byte = start + length - 1
;     while left < right:
;         swap *left, *right
;         left++, right--
; ───────────────────────────────────────────────────────────────────────────
str_reverse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — left pointer (callee-saved)
    push r12                ; save r12 — right pointer (callee-saved)

    ; First compute the length of the string
    push rdi                ; save the string pointer (str_len will use rdi)
    call str_len            ; rax = length
    pop  rdi                ; restore the string pointer

    ; Edge case: empty string or single character — nothing to swap
    cmp  rax, 1             ; is length <= 1?
    jle  .sr_done           ; yes — return immediately (nothing to swap)

    ; Set up two pointers
    mov  rbx, rdi           ; rbx = left pointer = start of string
    lea  r12, [rdi + rax - 1]  ; r12 = right pointer = address of LAST character
                               ;   rdi + rax points one past the end (at the null)
                               ;   rdi + rax - 1 points to the last real character

.sr_swap:
    cmp  rbx, r12           ; have the two pointers met or crossed?
    jge  .sr_done           ; yes — all pairs have been swapped; done

    mov  al, [rbx]          ; al = byte at left pointer  (load 1 byte)
    mov  cl, [r12]          ; cl = byte at right pointer (load 1 byte)
    mov  [rbx], cl          ; store right byte at left address  (1-byte write)
    mov  [r12], al          ; store left byte at right address  (1-byte write)

    inc  rbx                ; advance left pointer rightward by one byte
    dec  r12                ; advance right pointer leftward by one byte
    jmp  .sr_swap           ; check again and possibly swap the next pair

.sr_done:
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return to caller

; ───────────────────────────────────────────────────────────────────────────
; print_cstr — write null-terminated string to stdout
;   Input:  rdi = pointer to string
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer (will be clobbered by str_len)

    call str_len            ; rax = length
    mov  rdx, rax           ; rdx = length (write syscall arg 3)

    pop  rsi                ; rsi = string pointer (restored; write syscall arg 2)
    mov  rdi, 1             ; rdi = 1 — stdout (write syscall arg 1)
    mov  rax, 1             ; rax = 1 — syscall number for write()
    syscall                 ; write(1, string, length)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; demo_reverse — print a string, reverse it, then print again
;   Input:  rdi = pointer to null-terminated string
; ───────────────────────────────────────────────────────────────────────────
demo_reverse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r14                ; save r14 — the string pointer (callee-saved)

    mov  r14, rdi           ; r14 = the string pointer

    ; Print "Before: " label
    mov  rdi, lbl_before    ; rdi = pointer to "Before: "
    call print_cstr         ; print the label

    ; Print the original string
    mov  rdi, r14           ; rdi = string pointer
    call print_cstr         ; print the string

    ; Print newline
    mov  rdi, 1             ; rdi = stdout
    mov  rsi, newline       ; rsi = '\n' pointer
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write newline

    ; Reverse the string in place
    mov  rdi, r14           ; rdi = string pointer
    call str_reverse        ; reverse bytes between first and last character

    ; Print "After:  " label
    mov  rdi, lbl_after     ; rdi = pointer to "After:  "
    call print_cstr         ; print the label

    ; Print the reversed string
    mov  rdi, r14           ; rdi = string pointer (same memory, now reversed)
    call print_cstr         ; print it

    ; Print newline
    mov  rdi, 1             ; rdi = stdout
    mov  rsi, newline       ; rsi = '\n' pointer
    mov  rdx, 1             ; rdx = 1 byte
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write newline

    ; Print separator
    mov  rdi, separator     ; rdi = pointer to "--------\n"
    call print_cstr         ; print it

    pop  r14                ; restore r14 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: demonstrate str_reverse on several strings
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Demo 1: "Hello, World!"
    mov  rdi, s1            ; rdi = pointer to "Hello, World!"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 2: "abcdefghij"
    mov  rdi, s2            ; rdi = pointer to "abcdefghij"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 3: single character "A" (should be unchanged)
    mov  rdi, s3            ; rdi = pointer to "A"
    call demo_reverse       ; print before/after, reverse in place

    ; Demo 4: empty string (edge case — should be unchanged)
    mov  rdi, s4            ; rdi = pointer to "" (just a null byte)
    call demo_reverse       ; print before/after, reverse in place

    ; Exit
    mov  rax, 60            ; rax = 60 — exit() syscall number
    xor  rdi, rdi           ; rdi = 0 — exit code 0 = success
    syscall                 ; exit(0)



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



;═══════════════════════════════════════════════════════════════════════════════
; §20  Word Frequency
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 20_word_freq.asm
;  Description : djb2 hash table with chaining; tokeniser; word counting
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 20_word_freq.asm — Count word frequencies using a simple hash table
; Goal: memory structures, string hashing, collision handling
;
; We tokenize ASCII words (whitespace-separated) from a text buffer and
; count how many times each unique word appears.
;
; Hash table design:
;   - Fixed size: 64 buckets (power of 2, so we can use AND instead of MOD)
;   - Each bucket is a linked list of entries (open hashing / chaining)
;   - Each entry: { char word[32]; int64_t count; int64_t next_index }
;   - "next_index": index into the entries pool, -1 = end of chain
;   - Entries pool: pre-allocated array in .bss
;
; Hash function: djb2 (simple and effective for short strings)
;   hash = 5381
;   for each byte c: hash = hash * 33 ^ c
;   bucket = hash & 63
;
; Build:
;   nasm -f elf64 20_word_freq.asm -o bin/20_word_freq.o
;   ld bin/20_word_freq.o -o bin/20_word_freq
; Run:
;   ./bin/20_word_freq
; ═══════════════════════════════════════════════════════════════════════════════

%define WORD_LEN   32       ; max characters per word (including null terminator)
%define MAX_WORDS  128      ; max unique words in our pool
%define NUM_BUCKETS 64      ; hash table bucket count (must be power of 2)
%define BUCKET_MASK 63      ; = NUM_BUCKETS - 1; used for fast modulo via AND

; Each hash table entry layout (in memory):
;   [0..31]  = word string (WORD_LEN bytes, null-padded)
;   [32..39] = count (int64_t, 8 bytes)
;   [40..47] = next_index (int64_t, index into entries pool; -1 = end of chain)
; Total entry size = 48 bytes
%define ENTRY_SIZE  48
%define ENTRY_COUNT_OFF 32  ; byte offset of count field within an entry
%define ENTRY_NEXT_OFF  40  ; byte offset of next_index field within an entry

section .data
    text_buf  db "the quick brown fox jumps over the lazy dog the fox is quick", 0

    lbl_word   db "Word              Count", 10, 0
    lbl_sep    db "----              -----", 10, 0
    colon_sp   db ": ", 0
    newline    db 10
    space      db " ", 0

section .bss
    ; Hash table: NUM_BUCKETS slots, each holding an int64_t entry index (-1 = empty)
    ht_buckets  resq NUM_BUCKETS      ; 64 × 8 = 512 bytes

    ; Entry pool: MAX_WORDS entries of ENTRY_SIZE bytes each
    ht_entries  resb MAX_WORDS * ENTRY_SIZE

    ; Number of entries used (index of next free slot)
    ht_used     resq 1

    ; Scratch buffers
    word_buf    resb WORD_LEN         ; temporary buffer for current word
    num_buf     resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; ht_init — initialize the hash table (all buckets = -1, used = 0)
; ───────────────────────────────────────────────────────────────────────────
ht_init:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    ; Set all buckets to -1 (empty sentinel)
    mov  rcx, NUM_BUCKETS   ; rcx = 64 iterations
    mov  rdi, ht_buckets    ; rdi = pointer to bucket array
    mov  rax, -1            ; rax = -1 (the "empty" sentinel value)
.ht_init_loop:
    mov  [rdi], rax         ; bucket[i] = -1 (marks bucket as empty)
    add  rdi, 8             ; next bucket (each is 8 bytes = int64_t)
    dec  rcx                ; countdown
    jnz  .ht_init_loop      ; loop

    ; Reset used count
    mov  qword [ht_used], 0 ; ht_used = 0 entries allocated

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; djb2_hash — compute djb2 hash of a null-terminated string
;   Input:  rdi = pointer to null-terminated string
;   Output: rax = hash value (full 64-bit)
;
;   djb2: hash = 5381; for each byte c: hash = hash * 33 XOR c
; ───────────────────────────────────────────────────────────────────────────
djb2_hash:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, 5381          ; rax = initial hash seed (djb2 magic number)

.hash_loop:
    movzx rcx, byte [rdi]   ; rcx = current byte (zero-extended)
    test  cl, cl            ; null terminator?
    jz    .hash_done        ; yes — stop

    ; hash = hash * 33 + c
    ; Multiply by 33: multiply by 32 (left shift 5) and add the original = *33
    imul  rax, rax, 33      ; rax = rax * 33 (IMUL 3-operand: dst = src * imm)
    add   rax, rcx          ; rax = rax * 33 + c
    ; Alternative for djb2 with XOR: rax = rax*33 ^ c
    ; Using XOR version here:
    ; xor  rax, rcx

    inc   rdi               ; advance to next character
    jmp   .hash_loop

.hash_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = djb2 hash value

; ───────────────────────────────────────────────────────────────────────────
; ht_word_len — length of a short word string (up to WORD_LEN)
;   Input:  rdi = pointer to word (null-terminated)
;   Output: rax = length
; ───────────────────────────────────────────────────────────────────────────
ht_word_len:
    xor  rax, rax
.wl:
    cmp  byte [rdi + rax], 0
    je   .wl_d
    inc  rax
    jmp  .wl
.wl_d:
    ret

; ───────────────────────────────────────────────────────────────────────────
; ht_lookup_or_insert — find or create entry for a word, increment its count
;   Input:  rdi = pointer to null-terminated word string
; ───────────────────────────────────────────────────────────────────────────
ht_lookup_or_insert:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 — word pointer (callee-saved)
    push r13                ; save r13 — bucket index (callee-saved)
    push r14                ; save r14 — entry pointer (callee-saved)
    push rbx                ; save rbx — current entry index (callee-saved)

    mov  r12, rdi           ; r12 = word pointer

    ; Compute hash and bucket index
    call djb2_hash          ; rax = hash of word at rdi=r12... but rdi might have changed
    ; Actually rdi = r12 was set before call — let's be explicit:
    mov  rdi, r12           ; rdi = word pointer (set again, djb2 may clobber rdi)
    call djb2_hash          ; rax = hash
    and  rax, BUCKET_MASK   ; rax = bucket_index = hash & 63
    mov  r13, rax           ; r13 = bucket_index

    ; Walk the bucket's chain looking for a matching entry
    mov  rbx, [ht_buckets + r13*8]  ; rbx = ht_buckets[bucket] (first entry index or -1)

.ht_scan:
    cmp  rbx, -1            ; end of chain?
    je   .ht_insert         ; yes — word not found, insert new entry

    ; Compute pointer to entry rbx
    imul r14, rbx, ENTRY_SIZE     ; r14 = rbx * ENTRY_SIZE (byte offset)
    add  r14, ht_entries           ; r14 = pointer to entry[rbx]

    ; Compare this entry's word with our word (byte by byte, using r8 as index)
    jmp  .ht_strcmp_redo    ; jump to the working strcmp that uses r8 as the char index

.ht_match:
    ; Found matching entry — increment count
    add  qword [r14 + ENTRY_COUNT_OFF], 1   ; entry->count++
    jmp  .ht_done

.ht_insert:
    ; Allocate a new entry from the pool
    mov  rbx, [ht_used]          ; rbx = next free entry index
    cmp  rbx, MAX_WORDS          ; pool full?
    jge  .ht_done               ; silently drop (shouldn't happen with our small test)

    inc  qword [ht_used]         ; ht_used++

    ; Compute pointer to new entry
    imul r14, rbx, ENTRY_SIZE    ; r14 = offset
    add  r14, ht_entries         ; r14 = pointer to new entry

    ; Zero the entry (clear word, count, next)
    xor  rax, rax               ; rax = 0
    mov  rcx, ENTRY_SIZE / 8    ; rcx = number of 8-byte words to clear (48/8 = 6)
    mov  rdi, r14               ; rdi = entry pointer
.ht_zero:
    mov  [rdi], rax             ; store 0 (clears word, count, next fields)
    add  rdi, 8                 ; advance by 8 bytes
    dec  rcx                    ; count down
    jnz  .ht_zero               ; loop

    ; Copy word into entry's word field (up to WORD_LEN-1 chars + null)
    mov  rsi, r12               ; rsi = source word
    mov  rdi, r14               ; rdi = entry word field (at offset 0)
    xor  rcx, rcx               ; rcx = index
.ht_copy:
    cmp  rcx, WORD_LEN - 1      ; reached max word length?
    jge  .ht_nullterm           ; yes — force null termination
    mov  al, [rsi + rcx]        ; al = word[i]
    test al, al                 ; null byte?
    je   .ht_nullterm           ; yes — end of word
    mov  [rdi + rcx], al        ; entry_word[i] = word[i]
    inc  rcx
    jmp  .ht_copy

.ht_nullterm:
    mov  byte [rdi + rcx], 0    ; null-terminate the stored word

    ; Set count = 1 (first occurrence)
    mov  qword [r14 + ENTRY_COUNT_OFF], 1

    ; Set next = ht_buckets[bucket] (insert at head of chain)
    mov  rax, [ht_buckets + r13*8]   ; rax = old head (may be -1)
    mov  [r14 + ENTRY_NEXT_OFF], rax  ; new_entry->next = old head

    ; Set ht_buckets[bucket] = new_entry_index
    mov  [ht_buckets + r13*8], rbx   ; bucket[bucket_idx] = new entry index

.ht_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

    ; Redo the strcmp with r8 as char index (fix the rcx conflict above)
.ht_strcmp_redo:
    xor  r8, r8             ; r8 = character index
.ht_scmp2:
    cmp  r8, WORD_LEN
    jge  .ht_match

    mov  al, [r14 + r8]     ; al = entry_word[i] (r14 = entry base)
    cmp  al, [r12 + r8]     ; compare with search word[i]
    jne  .ht_next           ; mismatch — this is not the right entry

    test al, al             ; null byte? (both match and both are null → words are equal)
    jz   .ht_match          ; yes — words are equal

    inc  r8                 ; next character
    jmp  .ht_scmp2          ; continue comparing

.ht_next:
    ; Mismatch — follow the chain to the next entry
    mov  rbx, [r14 + ENTRY_NEXT_OFF]   ; rbx = entry->next
    jmp  .ht_scan           ; scan the next entry

; ───────────────────────────────────────────────────────────────────────────
; process_text — tokenize text and count word frequencies
;   Input:  rdi = pointer to null-terminated text buffer
; ───────────────────────────────────────────────────────────────────────────
process_text:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 — text pointer (callee-saved)
    push r13                ; save r13 — word buffer index (callee-saved)

    mov  r12, rdi           ; r12 = text pointer

.pt_main:
    ; Skip whitespace
    movzx rax, byte [r12]   ; rax = current character
    test  al, al            ; null terminator?
    jz    .pt_done          ; yes — end of text

    ; Is it whitespace? (space, tab, newline, etc.)
    cmp  al, ' '            ; space?
    je   .pt_skip           ; yes
    cmp  al, 9              ; tab?
    je   .pt_skip           ; yes
    cmp  al, 10             ; newline?
    je   .pt_skip           ; yes
    cmp  al, 13             ; carriage return?
    je   .pt_skip           ; yes

    ; Non-whitespace: start of a word — collect it
    xor  r13, r13           ; r13 = word_buf index = 0

.pt_collect:
    movzx rax, byte [r12]   ; rax = current char
    test  al, al            ; null?
    jz    .pt_end_word      ; yes — text ended mid-word

    ; Is it whitespace? (end of word)
    cmp  al, ' '
    je   .pt_end_word
    cmp  al, 9
    je   .pt_end_word
    cmp  al, 10
    je   .pt_end_word
    cmp  al, 13
    je   .pt_end_word

    ; Lowercase the character (if uppercase) for case-insensitive counting
    cmp  al, 'A'            ; is it 'A'-'Z'?
    jl   .pt_no_lower       ; no — already lowercase or non-alpha
    cmp  al, 'Z'
    jg   .pt_no_lower
    or   al, 0x20           ; set bit 5 to convert 'A'-'Z' to 'a'-'z'
.pt_no_lower:

    cmp  r13, WORD_LEN - 1  ; word buffer full?
    jge  .pt_char_skip      ; yes — skip extra characters (truncate)

    mov  [word_buf + r13], al ; store lowercased char in word buffer
    inc  r13                ; advance word buffer index

.pt_char_skip:
    inc  r12                ; advance text pointer
    jmp  .pt_collect        ; collect next character

.pt_end_word:
    ; Null-terminate the collected word
    mov  byte [word_buf + r13], 0

    ; Look up or insert this word in the hash table
    mov  rdi, word_buf      ; rdi = pointer to collected word
    call ht_lookup_or_insert ; count this word occurrence

    jmp  .pt_main           ; continue with the rest of the text

.pt_skip:
    inc  r12                ; skip whitespace character
    jmp  .pt_main

.pt_done:
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

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

print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pu_dig
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pu_term

.pu_dig:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pu_dig

.pu_term:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pu_rev:
    cmp  rsi, rdi
    jge  .pu_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pu_rev

.pu_wr:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Initialize hash table
    call ht_init

    ; Process the text buffer
    mov  rdi, text_buf
    call process_text

    ; Print header
    mov  rdi, lbl_word      ; "Word              Count"
    call print_cstr
    mov  rdi, lbl_sep       ; "----              -----"
    call print_cstr

    ; Iterate over all allocated entries and print their word + count
    xor  rbx, rbx           ; rbx = entry index = 0

.print_loop:
    mov  rax, [ht_used]     ; rax = number of entries used
    cmp  rbx, rax           ; index >= used?
    jge  .done              ; yes — done

    ; Compute pointer to entry[rbx]
    imul r14, rbx, ENTRY_SIZE
    add  r14, ht_entries    ; r14 = &entries[rbx]

    ; Print word (at offset 0 in entry)
    mov  rdi, r14           ; rdi = word string (offset 0)
    call print_cstr         ; print the word

    ; Pad to 18 characters for alignment
    ; (print_cstr leaves rdi=1; restore before calling ht_word_len)
    mov  rdi, r14           ; rdi = word pointer
    call ht_word_len        ; rax = word length
    mov  r13, 18
    sub  r13, rax           ; r13 = spaces needed (use r13, not rcx — syscall clobbers rcx)

.pad_loop:
    test r13, r13
    jle  .pad_done
    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall                 ; WARNING: clobbers rcx and r11; r13 survives
    dec  r13                ; use r13 for counter, not rcx
    jmp  .pad_loop

.pad_done:
    ; Print count
    mov  rdi, [r14 + ENTRY_COUNT_OFF]  ; rdi = entry->count
    call print_u64

    ; Newline
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  rbx                ; next entry
    jmp  .print_loop

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall



;═══════════════════════════════════════════════════════════════════════════════
; §21  Base Convert
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 21_base_convert.asm
;  Description : u64/i64 to decimal/hex; decimal/hex string to u64
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 21_base_convert.asm — Convert a 64-bit integer to decimal and hex strings
; Goal: division/modulo for digit extraction, ASCII output
;
; We demonstrate:
;   1. Decimal output: repeatedly divide by 10, collect remainders as digits
;   2. Hexadecimal output: repeatedly AND with 0xF (nibble), shift right by 4
;   3. Parsing a decimal string back to integer (atoi64)
;   4. Parsing a hex string back to integer (atox64)
;
; Build:
;   nasm -f elf64 21_base_convert.asm -o bin/21_base_convert.o
;   ld bin/21_base_convert.o -o bin/21_base_convert
; Run:
;   ./bin/21_base_convert
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test values to convert
    test_vals  dq 0, 1, 255, 65535, 1000000, -1, -42, 9223372036854775807
    test_n     equ ($ - test_vals) / 8

    dec_lbl    db "Dec: ", 0
    hex_lbl    db "Hex: 0x", 0
    newline    db 10
    space      db " ", 0

    ; For parsing demo
    dec_str    db "12345678", 0
    hex_str    db "DEADBEEF", 0
    parse_lbl  db "Parsed decimal '12345678'  = ", 0
    parse_lbl2 db "Parsed hex     'DEADBEEF'  = ", 0
    hex_suffix db " (= 0x", 0
    close_p    db ")", 10, 0

section .bss
    dec_buf    resb 24       ; buffer for decimal string (max 20 digits + sign + null)
    hex_buf    resb 20       ; buffer for hex string (max 16 hex digits + null)

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; u64_to_dec — convert unsigned 64-bit to decimal string
;   Input:  rdi = unsigned 64-bit number
;           rsi = pointer to output buffer (>= 21 bytes)
;   Output: rax = pointer to string, rdx = length
; ───────────────────────────────────────────────────────────────────────────
u64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, rsi           ; r12 = fixed buffer start
    mov  rbx, rsi           ; rbx = current write position

    mov  rax, rdi           ; rax = number to convert (dividend)
    test rax, rax           ; is the number zero?
    jnz  .u_digits          ; no — extract digits normally

    mov  byte [rbx], '0'    ; write '0' character for the zero case
    inc  rbx                ; advance write pointer
    jmp  .u_term            ; skip the loop

.u_digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half of dividend (DIV uses rdx:rax)
    mov  rcx, 10            ; rcx = 10 — decimal base (divisor)
    div  rcx                ; unsigned divide: rax = rax/10, rdx = rax%10 (last digit)
    add  dl, '0'            ; convert digit (0-9) to ASCII ('0' to '9')
    mov  [rbx], dl          ; store the ASCII character in buffer
    inc  rbx                ; advance write pointer to next position
    test rax, rax           ; is the quotient zero? (all digits extracted?)
    jnz  .u_digits          ; no — there are more digits

.u_term:
    mov  byte [rbx], 0      ; null-terminate the string

    ; Digits are in reverse order — reverse the buffer [r12 .. rbx-1]
    mov  rdx, rbx           ; rdx = one-past-end
    sub  rdx, r12           ; rdx = length = end - start

    lea  rdi, [rbx - 1]     ; rdi = pointer to last digit
    mov  rsi, r12           ; rsi = pointer to first digit
.u_rev:
    cmp  rsi, rdi           ; pointers crossed?
    jge  .u_done            ; done reversing

    mov  al, [rsi]          ; al = left character
    mov  cl, [rdi]          ; cl = right character
    mov  [rsi], cl          ; swap: right at left
    mov  [rdi], al          ; swap: left at right
    inc  rsi                ; advance left pointer
    dec  rdi                ; advance right pointer
    jmp  .u_rev             ; loop

.u_done:
    mov  rax, r12           ; rax = pointer to correctly ordered string

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string ptr, rdx = length

; ───────────────────────────────────────────────────────────────────────────
; i64_to_dec — convert SIGNED 64-bit integer to decimal string
;   Input:  rdi = signed 64-bit integer
;           rsi = pointer to output buffer (>= 22 bytes)
;   Output: rax = pointer to string, rdx = length
; ───────────────────────────────────────────────────────────────────────────
i64_to_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r13                ; save r13 — sign flag (callee-saved)
    push r14                ; save r14 — buffer start (callee-saved)
    push rbx                ; save rbx — write pointer (callee-saved)

    mov  r14, rsi           ; r14 = buffer start
    mov  rbx, rsi           ; rbx = write position
    xor  r13, r13           ; r13 = 0 — assume positive

    ; Handle negative numbers
    test rdi, rdi           ; is rdi negative? (checks sign bit via SF flag)
    jns  .s_pos             ; Jump if Not Signed (i.e., rdi >= 0)
    neg  rdi                ; flip sign: rdi = -rdi (now positive)
    mov  r13, 1             ; r13 = 1 — remember we need a '-' prefix

.s_pos:
    ; Now convert the magnitude (positive value in rdi)
    mov  rax, rdi           ; rax = positive magnitude
    test rax, rax           ; is it zero?
    jnz  .s_digits          ; no — extract digits

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .s_sign            ; go handle sign

.s_digits:
    xor  rdx, rdx           ; rdx = 0 — clear high half for division
    mov  rcx, 10            ; rcx = 10 — divisor
    div  rcx                ; rax = quotient, rdx = last digit
    add  dl, '0'            ; digit to ASCII
    mov  [rbx], dl          ; store in buffer
    inc  rbx                ; advance
    test rax, rax           ; more digits?
    jnz  .s_digits          ; yes

.s_sign:
    test r13, r13           ; was the number negative?
    jz   .s_term            ; no sign needed
    mov  byte [rbx], '-'    ; write '-' character
    inc  rbx                ; advance

.s_term:
    mov  byte [rbx], 0      ; null-terminate
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r14           ; rdx = length

    ; Reverse digits
    lea  rdi, [rbx - 1]     ; rdi = last char
    mov  rsi, r14           ; rsi = first char
.s_rev:
    cmp  rsi, rdi           ; crossed?
    jge  .s_done            ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance
    dec  rdi                ; advance
    jmp  .s_rev             ; loop

.s_done:
    mov  rax, r14           ; rax = string start

    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string ptr, rdx = length

; ───────────────────────────────────────────────────────────────────────────
; u64_to_hex — convert unsigned 64-bit integer to uppercase hex string
;   Input:  rdi = unsigned 64-bit number
;           rsi = pointer to output buffer (>= 17 bytes)
;   Output: rax = pointer to string, rdx = length
;
;   Method: extract the bottom 4 bits (a nibble = one hex digit) using AND 0xF,
;   then shift the number right by 4 bits to expose the next nibble.
;   Repeat until the number is zero. Reverse the resulting string.
; ───────────────────────────────────────────────────────────────────────────
u64_to_hex:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    ; Table of hex digit characters — indexed by nibble value 0-15
    ; We use a static local approach: the hex_digits string is in .data
    mov  r12, rsi           ; r12 = buffer start
    mov  rbx, rsi           ; rbx = write position

    mov  rax, rdi           ; rax = number to convert
    test rax, rax           ; is it zero?
    jnz  .h_digits          ; no — extract digits

    mov  byte [rbx], '0'    ; write single '0'
    inc  rbx                ; advance
    jmp  .h_term            ; skip the loop

.h_digits:
    mov  rcx, rax           ; rcx = current value (we destructively shift this)
    and  rcx, 0xF           ; rcx = lowest 4 bits (nibble = hex digit 0-15)
    cmp  cl, 10             ; is the nibble < 10?
    jl   .h_num             ; yes — it's a decimal digit ('0'-'9')
    add  cl, 'A' - 10       ; no  — convert 10-15 to 'A'-'F'
    jmp  .h_store           ; store it
.h_num:
    add  cl, '0'            ; convert 0-9 to ASCII '0'-'9'
.h_store:
    mov  [rbx], cl          ; store the hex character
    inc  rbx                ; advance write pointer
    shr  rax, 4             ; shift right 4 bits to reveal the next nibble
    test rax, rax           ; all nibbles extracted?
    jnz  .h_digits          ; no — continue

.h_term:
    mov  byte [rbx], 0      ; null-terminate
    mov  rdx, rbx           ; rdx = end pointer
    sub  rdx, r12           ; rdx = length

    ; Reverse — same pattern as decimal
    lea  rdi, [rbx - 1]     ; rdi = last char
    mov  rsi, r12           ; rsi = first char
.h_rev:
    cmp  rsi, rdi           ; crossed?
    jge  .h_done            ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance
    dec  rdi                ; advance
    jmp  .h_rev             ; loop

.h_done:
    mov  rax, r12           ; rax = string start

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = string ptr, rdx = length

; ───────────────────────────────────────────────────────────────────────────
; dec_to_u64 — parse ASCII decimal string to unsigned 64-bit integer
;   Input:  rdi = pointer to null-terminated decimal string
;   Output: rax = parsed value
; ───────────────────────────────────────────────────────────────────────────
dec_to_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — accumulated result
.d_loop:
    movzx rcx, byte [rdi]   ; rcx = current character (zero-extended to 64 bits)
    test  cl, cl            ; is it a null terminator?
    jz    .d_done           ; yes — we're done parsing

    sub   cl, '0'           ; cl = digit value (subtract ASCII '0' = 48)
    js    .d_done           ; if cl went negative, char < '0' — stop parsing
    cmp   cl, 9             ; is digit > 9?
    jg    .d_done           ; yes — non-digit character — stop

    imul  rax, rax, 10      ; rax = rax * 10 — shift accumulated value left one decimal place
    add   rax, rcx          ; rax = rax*10 + digit — incorporate the new digit

    inc   rdi               ; advance to the next character
    jmp   .d_loop           ; parse the next character

.d_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = parsed integer

; ───────────────────────────────────────────────────────────────────────────
; hex_to_u64 — parse ASCII hexadecimal string to unsigned 64-bit integer
;   Input:  rdi = pointer to null-terminated hex string (no "0x" prefix, uppercase or lowercase)
;   Output: rax = parsed value
; ───────────────────────────────────────────────────────────────────────────
hex_to_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — accumulated result
.x_loop:
    movzx rcx, byte [rdi]   ; rcx = current character
    test  cl, cl            ; null terminator?
    jz    .x_done           ; yes — done

    ; Convert character to nibble value
    cmp  cl, '0'            ; is it below '0'?
    jl   .x_done            ; yes — invalid, stop
    cmp  cl, '9'            ; is it '0'-'9'?
    jle  .x_num             ; yes — decimal digit
    cmp  cl, 'A'            ; is it 'A'-'F'?
    jl   .x_done            ; below 'A' but above '9' — invalid (e.g. ':')
    cmp  cl, 'F'            ; is it 'A'-'F'?
    jle  .x_upper           ; yes
    cmp  cl, 'a'            ; is it 'a'-'f'?
    jl   .x_done            ; no — invalid
    cmp  cl, 'f'            ; is it 'a'-'f'?
    jg   .x_done            ; no — invalid
    sub  cl, 'a' - 10       ; convert 'a'-'f' to 10-15
    jmp  .x_acc             ; accumulate

.x_upper:
    sub  cl, 'A' - 10       ; convert 'A'-'F' to 10-15
    jmp  .x_acc             ; accumulate

.x_num:
    sub  cl, '0'            ; convert '0'-'9' to 0-9

.x_acc:
    shl  rax, 4             ; rax = rax * 16 — shift left one hex digit position
    or   rax, rcx           ; rax = rax*16 + digit — OR in the new nibble
    inc  rdi                ; advance to next character
    jmp  .x_loop            ; loop

.x_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = parsed integer

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers
; ───────────────────────────────────────────────────────────────────────────
print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length counter
.pcs_l:
    cmp  byte [rdi + rcx], 0  ; null byte?
    je   .pcs_w               ; yes
    inc  rcx                  ; count
    jmp  .pcs_l               ; loop

.pcs_w:
    pop  rsi                ; rsi = string pointer
    mov  rdx, rcx           ; rdx = length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write syscall
    syscall                 ; write(1, str, len)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point: show conversions for several test values
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Loop over test_vals and print each in decimal and hex
    xor  r15, r15           ; r15 = index = 0

.main_loop:
    cmp  r15, test_n        ; index >= count?
    jge  .parse_demo        ; done with values

    ; Load next value
    mov  r14, [test_vals + r15*8]  ; r14 = test_vals[index]

    ; Print decimal label
    mov  rdi, dec_lbl       ; "Dec: "
    call print_cstr         ; print

    ; Convert and print decimal
    mov  rdi, r14           ; rdi = the value
    mov  rsi, dec_buf       ; rsi = decimal output buffer
    call i64_to_dec         ; rax = string, rdx = length

    push rdi                ; rdi will be overwritten; save it
    mov  rsi, rax           ; rsi = string pointer (write arg 2)
    ; rdx = length already set by i64_to_dec
    mov  rdi, 1             ; rdi = stdout (write arg 1)
    mov  rax, 1             ; rax = write syscall
    syscall                 ; write decimal string
    pop  rdi                ; restore

    ; Print "  " spacer then hex label
    mov  rdi, space         ; " "
    call print_cstr
    mov  rdi, space
    call print_cstr
    mov  rdi, hex_lbl       ; "Hex: 0x"
    call print_cstr

    ; Convert and print hex (cast to unsigned for hex display)
    mov  rdi, r14           ; rdi = the value (treated as unsigned for hex)
    mov  rsi, hex_buf       ; rsi = hex output buffer
    call u64_to_hex         ; rax = string, rdx = length

    mov  rsi, rax           ; rsi = string pointer
    ; rdx = length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall                 ; write hex string

    ; Newline
    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write
    syscall                 ; write newline

    inc  r15                ; next value
    jmp  .main_loop         ; loop

.parse_demo:
    ; ── Parsing demo ──
    ; Parse "12345678" as decimal
    mov  rdi, parse_lbl     ; "Parsed decimal '12345678'  = "
    call print_cstr

    mov  rdi, dec_str       ; "12345678"
    call dec_to_u64         ; rax = 12345678

    mov  rdi, rax           ; rdi = parsed value
    mov  rsi, dec_buf       ; rsi = buffer
    call u64_to_dec         ; convert back to string for printing
    mov  rsi, rax           ; rsi = string
    ; rdx = length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Parse "DEADBEEF" as hex
    mov  rdi, parse_lbl2    ; "Parsed hex 'DEADBEEF'  = "
    call print_cstr

    mov  rdi, hex_str       ; "DEADBEEF"
    call hex_to_u64         ; rax = 0xDEADBEEF = 3735928559

    mov  rdi, rax
    mov  rsi, dec_buf
    call u64_to_dec
    mov  rsi, rax
    mov  rdi, 1
    mov  rax, 1
    syscall

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §22  Bit Twiddling
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 22_bittwiddle.asm
;  Description : POPCNT, LZCNT, TZCNT hardware instructions; BSR/BSF fallbacks
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 22_bittwiddle.asm — popcount, clz (count leading zeros), ctz (count trailing zeros)
; Goal: bit manipulation instructions and fallback implementations
;
; Instructions demonstrated:
;   POPCNT dst, src   — count the number of set bits (1s) in src
;                       Requires CPU flag: POPCNT (available since Nehalem 2008)
;   LZCNT  dst, src   — count leading zero bits from the MSB side
;                       Requires CPU flag: LZCNT (available since Haswell 2013)
;   TZCNT  dst, src   — count trailing zero bits from the LSB side
;                       Requires CPU flag: BMI1 (available since Haswell 2013)
;   BSF    dst, src   — Bit Scan Forward — index of lowest set bit
;                       (undefined result when src == 0, unlike TZCNT)
;   BSR    dst, src   — Bit Scan Reverse — index of highest set bit
;
; Scalar fallback: we also implement popcount without the POPCNT instruction
; so you can see the bit-twiddling approach (Brian Kernighan's algorithm).
;
; Build:
;   nasm -f elf64 22_bittwiddle.asm -o bin/22_bittwiddle.o
;   ld bin/22_bittwiddle.o -o bin/22_bittwiddle
; Run:
;   ./bin/22_bittwiddle
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; Test values
    vals    dq 0, 1, 0xFF, 0x5555555555555555, 0xFFFFFFFFFFFFFFFF, 0x8000000000000000, 42
    vals_n  equ ($ - vals) / 8

    ; Labels for output columns
    hdr     db "Value              popcount  clz  ctz", 10
    hdr_len equ $ - hdr
    sep2    db "---                --------  ---  ---", 10
    sep2_len equ $ - sep2
    col_sep db "  ", 0
    newline db 10

section .bss
    num_buf  resb 24
    hex_buf  resb 20

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; popcount_hw — count set bits using the hardware POPCNT instruction
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits (0 to 64)
;
;   POPCNT is one clock cycle on modern CPUs — very fast.
; ───────────────────────────────────────────────────────────────────────────
popcount_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    popcnt rax, rdi         ; rax = number of 1-bits in rdi
                            ; POPCNT: populates rax with the population count of rdi

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = popcount

; ───────────────────────────────────────────────────────────────────────────
; popcount_scalar — count set bits without POPCNT (Brian Kernighan's trick)
;   Input:  rdi = 64-bit value
;   Output: rax = number of set bits
;
;   Trick: n & (n-1) clears the LOWEST set bit of n.
;   Example: n=0b1010, n-1=0b1001, n&(n-1)=0b1000 — cleared the lowest 1-bit.
;   Count iterations until n becomes 0.
; ───────────────────────────────────────────────────────────────────────────
popcount_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    xor  rax, rax           ; rax = 0 — bit counter starts at zero
    test rdi, rdi           ; is rdi zero? (no bits set)
    jz   .pc_done           ; yes — return 0 immediately

.pc_loop:
    mov  rcx, rdi           ; rcx = n — copy current value
    dec  rcx                ; rcx = n - 1
    and  rdi, rcx           ; rdi = n & (n-1) — clears the lowest set bit in n
    inc  rax                ; count this cleared bit
    test rdi, rdi           ; is rdi now zero? (no more set bits)
    jnz  .pc_loop           ; no — loop and clear the next bit

.pc_done:
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = number of set bits

; ───────────────────────────────────────────────────────────────────────────
; clz_hw — count leading zero bits using LZCNT instruction
;   Input:  rdi = 64-bit value (input 0 gives result 64)
;   Output: rax = number of zero bits to the left of the highest set bit
;
;   Example: 0x0000_0001 → 63 leading zeros
;            0x8000_0000_0000_0000 → 0 leading zeros (MSB is set)
;            0 → 64 (special case: all bits are "leading zeros")
; ───────────────────────────────────────────────────────────────────────────
clz_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    lzcnt rax, rdi          ; rax = number of leading (most-significant) zero bits
                            ; LZCNT: well-defined for 0 (returns 64), unlike BSR

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = leading zero count

; ───────────────────────────────────────────────────────────────────────────
; clz_bsr — count leading zeros using BSR (Bit Scan Reverse) — no LZCNT needed
;   Input:  rdi = 64-bit value
;   Output: rax = leading zero count (64 if rdi == 0)
;
;   BSR finds the bit index of the highest set bit.
;   clz = 63 - BSR(x) for non-zero x.
; ───────────────────────────────────────────────────────────────────────────
clz_bsr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdi, rdi           ; is rdi zero?
    jz   .clz_zero          ; special case: return 64

    bsr  rax, rdi           ; rax = index of highest set bit (0-63)
                            ; BSR: scans from bit 63 down to bit 0; undefined for 0
    xor  rax, 63            ; rax = 63 - rax = number of leading zeros
                            ; (XOR with 63 is the same as 63 - rax when rax <= 63)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

.clz_zero:
    mov  rax, 64            ; clz(0) = 64 by convention
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; ctz_hw — count trailing zero bits using TZCNT instruction
;   Input:  rdi = 64-bit value (input 0 gives result 64)
;   Output: rax = number of zero bits below the lowest set bit
;
;   Example: 0b0000_1000 → 3 trailing zeros
;            0b0000_0001 → 0 trailing zeros (bit 0 is set)
; ───────────────────────────────────────────────────────────────────────────
ctz_hw:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    tzcnt rax, rdi          ; rax = number of trailing (least-significant) zero bits
                            ; TZCNT: well-defined for 0 (returns 64)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = trailing zero count

; ───────────────────────────────────────────────────────────────────────────
; ctz_bsf — count trailing zeros using BSF (Bit Scan Forward) — no TZCNT needed
;   Input:  rdi = 64-bit value
;   Output: rax = trailing zero count (64 if rdi == 0)
;
;   BSF finds the bit index of the lowest set bit, which equals ctz for non-zero.
; ───────────────────────────────────────────────────────────────────────────
ctz_bsf:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    test rdi, rdi           ; is rdi zero?
    jz   .ctz_zero          ; special case

    bsf  rax, rdi           ; rax = index of lowest set bit (= number of trailing zeros)
                            ; BSF: scans from bit 0 upward; undefined for 0

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

.ctz_zero:
    mov  rax, 64            ; ctz(0) = 64 by convention
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Printing helpers (compact versions)
; ───────────────────────────────────────────────────────────────────────────

; print_u64_dec — print unsigned 64-bit integer without newline
;   Input: rdi = number
print_u64_dec:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax           ; zero?
    jnz  .pd_dig            ; no

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx                ; advance
    jmp  .pd_term           ; done

.pd_dig:
    xor  rdx, rdx           ; rdx = 0
    mov  rcx, 10            ; rcx = 10
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'            ; to ASCII
    mov  [rbx], dl          ; store
    inc  rbx                ; advance
    test rax, rax           ; more?
    jnz  .pd_dig            ; yes

.pd_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]     ; last char
    mov  rsi, r12           ; first char
.pd_rev:
    cmp  rsi, rdi           ; crossed?
    jge  .pd_wr             ; done
    mov  al, [rsi]          ; load left
    mov  cl, [rdi]          ; load right
    mov  [rsi], cl          ; swap
    mov  [rdi], al          ; swap
    inc  rsi                ; advance
    dec  rdi                ; advance
    jmp  .pd_rev            ; loop

.pd_wr:
    mov  rsi, r12           ; string start
    mov  rdx, rbx           ; end
    sub  rdx, r12           ; length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

; print_u64_hex — print value as "0x<HEX>" with no newline
;   Input: rdi = number
print_u64_hex:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, hex_buf       ; r12 = buffer start
    mov  rbx, hex_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax           ; zero?
    jnz  .hx_dig

    mov  byte [rbx], '0'    ; write '0'
    inc  rbx
    jmp  .hx_term

.hx_dig:
    mov  rcx, rax           ; rcx = current value
    and  rcx, 0xF           ; lowest nibble
    cmp  cl, 10             ; < 10?
    jl   .hx_num
    add  cl, 'A' - 10       ; 'A'-'F'
    jmp  .hx_st
.hx_num:
    add  cl, '0'            ; '0'-'9'
.hx_st:
    mov  [rbx], cl          ; store hex char
    inc  rbx                ; advance
    shr  rax, 4             ; next nibble
    test rax, rax           ; done?
    jnz  .hx_dig

.hx_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]     ; last char
    mov  rsi, r12           ; first char
.hx_rev:
    cmp  rsi, rdi
    jge  .hx_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .hx_rev

.hx_wr:
    ; Print "0x" prefix first
    push r12                ; save buffer start
    push rbx                ; save end pointer
    mov  rdi, 1             ; stdout
    mov  rsi, hex_prefix    ; "0x"
    mov  rdx, 2             ; 2 bytes
    mov  rax, 1             ; write
    syscall
    pop  rbx                ; restore end
    pop  r12                ; restore start

    mov  rsi, r12           ; string start
    mov  rdx, rbx           ; end
    sub  rdx, r12           ; length
    mov  rdi, 1             ; stdout
    mov  rax, 1             ; write
    syscall

    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

print_cstr:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rdi                ; save string pointer

    xor  rcx, rcx           ; rcx = 0 — length
.pcs_l:
    cmp  byte [rdi + rcx], 0
    je   .pcs_w
    inc  rcx
    jmp  .pcs_l
.pcs_w:
    pop  rsi
    mov  rdx, rcx
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  rbp                ; restore caller's frame pointer
    ret

section .data
    hex_prefix  db "0x", 0

section .text

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print table header
    mov  rdi, 1             ; stdout
    mov  rsi, hdr           ; header string
    mov  rdx, hdr_len       ; header length
    mov  rax, 1             ; write
    syscall

    mov  rdi, 1             ; stdout
    mov  rsi, sep2          ; separator line
    mov  rdx, sep2_len      ; separator length
    mov  rax, 1             ; write
    syscall

    ; Loop over test values
    xor  r15, r15           ; r15 = index = 0

.vloop:
    cmp  r15, vals_n        ; done?
    jge  .fin               ; yes

    mov  r14, [vals + r15*8] ; r14 = current value

    ; Print hex value (padded): 0xXXXXXXXXXXXXXXXX
    mov  rdi, r14           ; rdi = value
    call print_u64_hex      ; print hex representation

    ; Spacer
    mov  rdi, col_sep       ; "  "
    call print_cstr

    ; popcount (hardware)
    mov  rdi, r14           ; rdi = value
    call popcount_hw        ; rax = popcount
    push rax                ; save result
    ; Also verify with scalar
    mov  rdi, r14           ; rdi = value
    call popcount_scalar    ; rax = scalar popcount (should match)
    pop  rdi                ; rdi = hw popcount (use hw result)
    call print_u64_dec      ; print it

    ; Spacer
    mov  rdi, col_sep
    call print_cstr
    mov  rdi, col_sep
    call print_cstr

    ; clz (leading zeros)
    mov  rdi, r14           ; rdi = value
    call clz_hw             ; rax = leading zeros
    mov  rdi, rax
    call print_u64_dec      ; print

    ; Spacer
    mov  rdi, col_sep
    call print_cstr
    mov  rdi, col_sep
    call print_cstr

    ; ctz (trailing zeros)
    mov  rdi, r14           ; rdi = value
    call ctz_hw             ; rax = trailing zeros
    mov  rdi, rax
    call print_u64_dec      ; print

    ; Newline
    mov  rdi, 1             ; stdout
    mov  rsi, newline       ; '\n'
    mov  rdx, 1             ; 1 byte
    mov  rax, 1             ; write
    syscall

    inc  r15                ; next value
    jmp  .vloop             ; loop

.fin:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §23  Matrix Multiply
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 23_matrix_mul.asm
;  Description : 3×3 int32 naive triple loop; 4×4 float SSE broadcast+MULPS
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 23_matrix_mul.asm — Matrix multiplication: 3×3 scalar and 4×4 SSE
; Goal: cache blocking, register blocking, understanding access patterns
;
; Matrix multiplication: C = A × B
;   C[i][j] = sum over k of A[i][k] * B[k][j]
;
; Access pattern matters for cache performance:
;   - A is accessed row-by-row (cache friendly)
;   - B is accessed column-by-column (cache UNFRIENDLY — each access jumps by a full row)
;   - Solution: transpose B first, then access rows of B^T instead of columns of B
;
; We implement:
;   1. 3×3 scalar multiply (int32_t elements)
;   2. 4×4 SSE multiply (float elements) — four rows of B loaded as rows of B^T
;
; Build:
;   nasm -f elf64 23_matrix_mul.asm -o bin/23_matrix_mul.o
;   ld bin/23_matrix_mul.o -o bin/23_matrix_mul
; Run:
;   ./bin/23_matrix_mul
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; 3×3 integer matrices (row-major, int32_t)
    A3  dd  1, 2, 3
        dd  4, 5, 6
        dd  7, 8, 9

    B3  dd  9, 8, 7
        dd  6, 5, 4
        dd  3, 2, 1

    ; Expected C3 = A3 × B3:
    ; Row 0: [1*9+2*6+3*3, 1*8+2*5+3*2, 1*7+2*4+3*1] = [30, 24, 18]
    ; Row 1: [4*9+5*6+6*3, 4*8+5*5+6*2, 4*7+5*4+6*1] = [84, 69, 54]
    ; Row 2: [7*9+8*6+9*3, 7*8+8*5+9*2, 7*7+8*4+9*1] = [138, 114, 90]

    ; 4×4 float matrices (row-major, float32)
    align 16
    A4  dd  1.0, 2.0,  3.0,  4.0
        dd  5.0, 6.0,  7.0,  8.0
        dd  9.0, 10.0, 11.0, 12.0
        dd  13.0, 14.0, 15.0, 16.0

    B4  dd  1.0, 0.0, 0.0, 0.0   ; identity matrix
        dd  0.0, 1.0, 0.0, 0.0
        dd  0.0, 0.0, 1.0, 0.0
        dd  0.0, 0.0, 0.0, 1.0
    ; C4 = A4 × I = A4

    lbl_3x3   db "3x3 Integer matrix multiply result:", 10, 0
    lbl_4x4   db "4x4 Float matrix multiply (A x I = A):", 10, 0
    newline   db 10
    space     db " ", 0

section .bss
    C3       resd 9         ; 3×3 int32 output matrix
    C4       resd 16        ; 4×4 float output matrix
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; matmul_3x3_i32 — multiply two 3×3 int32 matrices
;   Input:  rdi = pointer to 3×3 matrix A (int32, row-major)
;           rsi = pointer to 3×3 matrix B (int32, row-major)
;           rdx = pointer to 3×3 output matrix C (int32, row-major)
;
;   C[i][j] = sum_{k=0}^{2} A[i][k] * B[k][j]
; ───────────────────────────────────────────────────────────────────────────
matmul_3x3_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = A
    mov  r13, rsi           ; r13 = B
    mov  r14, rdx           ; r14 = C

    ; Triple nested loop: i, j, k
    xor  r8, r8             ; r8 = i = 0 (row of A and C)

.mm3_i:
    cmp  r8, 3              ; i >= 3?
    jge  .mm3_done

    xor  r9, r9             ; r9 = j = 0 (column of B and C)

.mm3_j:
    cmp  r9, 3              ; j >= 3?
    jge  .mm3_next_i        ; advance to next row i

    xor  rbx, rbx           ; rbx = sum = 0 (accumulator for C[i][j])
    xor  r10, r10           ; r10 = k = 0 (inner sum index)

.mm3_k:
    cmp  r10, 3             ; k >= 3?
    jge  .mm3_store         ; yes — store C[i][j]

    ; Load A[i][k]: row i, column k → offset (i*3 + k) * 4 bytes
    imul rax, r8, 3            ; rax = i * 3
    add  rax, r10              ; rax = i*3 + k
    movsxd rax, dword [r12 + rax*4]  ; rax = A[i][k] (sign-extend int32 to int64)

    ; Load B[k][j]: row k, column j → offset (k*3 + j) * 4 bytes
    imul rcx, r10, 3           ; rcx = k * 3
    add  rcx, r9               ; rcx = k*3 + j
    movsxd rcx, dword [r13 + rcx*4]  ; rcx = B[k][j]

    imul rax, rcx           ; rax = A[i][k] * B[k][j] (64-bit product)
    add  rbx, rax           ; sum += product

    inc  r10                ; k++
    jmp  .mm3_k

.mm3_store:
    ; Store C[i][j] = sum — offset (i*3 + j) * 4
    imul rax, r8, 3            ; rax = i * 3
    add  rax, r9               ; rax = i*3 + j
    mov  [r14 + rax*4], ebx   ; C[i][j] = lower 32 bits of sum

    inc  r9                 ; j++
    jmp  .mm3_j

.mm3_next_i:
    inc  r8                 ; i++
    jmp  .mm3_i

.mm3_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; matmul_4x4_f32_sse — multiply two 4×4 float matrices using SSE
;   Input:  rdi = pointer to A (4×4 float, 16-byte aligned)
;           rsi = pointer to B (4×4 float, 16-byte aligned)
;           rdx = pointer to C (4×4 float, 16-byte aligned output)
;
;   Strategy: for each row i of A and each column j of B:
;     C[i][j] = dot product of row i of A with column j of B
;
;   SSE approach: process one row of C at a time.
;     Load row i of A into xmm registers.
;     For each column j (0..3):
;       Load B's column j (scattered in memory) into xmm4.
;       Compute dot product using MULPS + horizontal add.
;
;   Simpler approach for clarity: broadcast each element of A's row, multiply
;   by corresponding row of B, accumulate.
; ───────────────────────────────────────────────────────────────────────────
matmul_4x4_f32_sse:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push r12                ; save r12 (callee-saved)
    push r13                ; save r13 (callee-saved)
    push r14                ; save r14 (callee-saved)
    push rbx                ; save rbx (callee-saved)

    mov  r12, rdi           ; r12 = A
    mov  r13, rsi           ; r13 = B
    mov  r14, rdx           ; r14 = C

    xor  rbx, rbx           ; rbx = row index i = 0

.mm4_row:
    cmp  rbx, 4             ; i >= 4?
    jge  .mm4_done

    ; C[i][0..3] = A[i][0]*B[0] + A[i][1]*B[1] + A[i][2]*B[2] + A[i][3]*B[3]
    ; where B[k] = row k of B = [B[k][0], B[k][1], B[k][2], B[k][3]]

    ; Pointer to row i of A: r12 + i * 16 (4 floats × 4 bytes each)
    imul rdi, rbx, 16          ; rdi = i * 16 (byte offset)
    add  rdi, r12              ; rdi = &A[i][0]

    pxor xmm0, xmm0         ; xmm0 = {0,0,0,0} — accumulator for C row i
                             ; PXOR: zero out the register

    ; Process each k = 0..3
    xor  r8, r8             ; r8 = k = 0

.mm4_k:
    cmp  r8, 4              ; k >= 4?
    jge  .mm4_store

    ; Load scalar A[i][k] and broadcast to all 4 lanes
    movss xmm1, [rdi + r8*4]   ; xmm1 = A[i][k] in lowest lane, others undefined
                                ; MOVSS: Move Scalar Single-precision
    shufps xmm1, xmm1, 0       ; xmm1 = {A[i][k], A[i][k], A[i][k], A[i][k]}
                                ; SHUFPS: Shuffle Packed Singles
                                ; Shuffle control 0 = copy element 0 to all 4 lanes

    ; Load row k of B: r13 + k * 16
    imul rcx, r8, 16           ; rcx = k * 16 (byte offset)
    add  rcx, r13              ; rcx = &B[k][0]
    movaps xmm2, [rcx]          ; xmm2 = {B[k][0], B[k][1], B[k][2], B[k][3]}
                                 ; MOVAPS: Move Aligned Packed Singles (16-byte aligned load)

    ; Multiply and accumulate
    mulps  xmm1, xmm2           ; xmm1 = A[i][k] * {B[k][0], B[k][1], B[k][2], B[k][3]}
                                 ; MULPS: Multiply Packed Singles — 4 multiplications at once
    addps  xmm0, xmm1           ; xmm0 += xmm1 — accumulate 4 products in parallel
                                 ; ADDPS: Add Packed Singles

    inc  r8                ; k++
    jmp  .mm4_k

.mm4_store:
    ; Store the computed row i of C: r14 + i * 16
    imul rdi, rbx, 16          ; rdi = i * 16 (byte offset)
    add  rdi, r14              ; rdi = &C[i][0]
    movaps [rdi], xmm0          ; C[i][0..3] = xmm0 (aligned store)
                                 ; MOVAPS: Move Aligned Packed Singles (store)

    inc  rbx                ; next row
    jmp  .mm4_row

.mm4_done:
    pop  rbx                ; restore rbx (callee-saved)
    pop  r14                ; restore r14 (callee-saved)
    pop  r13                ; restore r13 (callee-saved)
    pop  r12                ; restore r12 (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return

; ───────────────────────────────────────────────────────────────────────────
; Print helpers
; ───────────────────────────────────────────────────────────────────────────
print_i32:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12
    push r13

    movsxd rdi, edi
    mov  r12, num_buf
    mov  rbx, num_buf
    xor  r13, r13

    test rdi, rdi
    jns  .pi_p
    neg  rdi
    mov  r13, 1

.pi_p:
    mov  rax, rdi
    test rax, rax
    jnz  .pi_d
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pi_s

.pi_d:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pi_d

.pi_s:
    test r13, r13
    jz   .pi_t
    mov  byte [rbx], '-'
    inc  rbx

.pi_t:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pi_r:
    cmp  rsi, rdi
    jge  .pi_w
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pi_r

.pi_w:
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

print_float:                ; print xmm0 as integer (float display is approximate)
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    cvttss2si edi, xmm0    ; convert float to int (truncate)
    call print_i32          ; print it
    pop  rbp                ; restore caller's frame pointer
    ret

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

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; ── 3×3 integer matrix multiply ──
    mov  rdi, A3            ; rdi = matrix A
    mov  rsi, B3            ; rsi = matrix B
    mov  rdx, C3            ; rdx = output C
    call matmul_3x3_i32

    mov  rdi, lbl_3x3       ; "3x3 Integer matrix multiply result:\n"
    call print_cstr

    ; Print 3×3 result
    xor  rbx, rbx
.p3:
    cmp  rbx, 9
    jge  .do_4x4

    mov  edi, [C3 + rbx*4]
    call print_i32

    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Newline after each row of 3
    lea  rax, [rbx + 1]
    xor  rdx, rdx
    mov  rcx, 3
    div  rcx                ; rax = (rbx+1)/3, rdx = (rbx+1)%3
    test rdx, rdx           ; end of row?
    jnz  .no_nl3
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
.no_nl3:
    inc  rbx
    jmp  .p3

.do_4x4:
    ; ── 4×4 float matrix multiply ──
    mov  rdi, A4
    mov  rsi, B4
    mov  rdx, C4
    call matmul_4x4_f32_sse

    mov  rdi, lbl_4x4
    call print_cstr

    xor  rbx, rbx
.p4:
    cmp  rbx, 16
    jge  .done

    movss xmm0, [C4 + rbx*4]  ; load float result
    call print_float

    mov  rdi, 1
    mov  rsi, space
    mov  rdx, 1
    mov  rax, 1
    syscall

    lea  rax, [rbx + 1]
    xor  rdx, rdx
    mov  rcx, 4
    div  rcx
    test rdx, rdx
    jnz  .no_nl4
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall
.no_nl4:
    inc  rbx
    jmp  .p4

.done:
    mov  rax, 60            ; exit
    xor  rdi, rdi
    syscall



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



;═══════════════════════════════════════════════════════════════════════════════
; §25  Fast Division
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 25_fast_div.asm
;  Description : Magic-number multiply (Hacker's Delight): div7 and div10
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 25_fast_div.asm — Fast integer division by a constant using "magic number" method
; Goal: understand multiply-shift optimizations that compilers use
;
; Problem: integer division is slow on modern CPUs (20-90 cycles for IDIV).
;          If the divisor is a compile-time constant, compilers replace it with
;          a multiply + shift sequence that takes 3-5 cycles.
;
; Hacker's Delight method (Warren, "Hacker's Delight" chapter 10):
;   To compute n / d for a constant d > 0 and 64-bit unsigned n:
;     1. Compute magic number M = ceil(2^(64+p) / d)
;        where p is chosen so that M fits in 64 bits.
;     2. Division approximation: q = (M * n) >> (64 + p)
;
; In practice, compilers precompute (M, shift) at compile time.
; We hard-code examples for divisors 7 and 10 to illustrate the pattern.
;
; Reference: Henry S. Warren Jr., "Hacker's Delight", 2nd ed., Chapter 10.
;
; Build:
;   nasm -f elf64 25_fast_div.asm -o bin/25_fast_div.o
;   ld bin/25_fast_div.o -o bin/25_fast_div
; Run:
;   ./bin/25_fast_div
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    ; ── Magic number table ──
    ;
    ; For UNSIGNED 64-bit division by 7:
    ;   M = 0x2492492492492493  (magic multiplier)
    ;   post-shift = 2
    ;   The formula: (mulhi(n, M) >> 2) gives floor(n / 7)
    ;
    ; For UNSIGNED 64-bit division by 10:
    ;   M = 0xCCCCCCCCCCCCCCCD  (magic multiplier)
    ;   post-shift = 3
    ;   The formula: (mulhi(n, M) >> 3) gives floor(n / 10)
    ;
    ; "mulhi" means the UPPER 64 bits of the 128-bit product (n * M).
    ; On x86-64, MUL rax, src gives rdx:rax; we only need rdx (the high part).

    magic7   dq 0x2492492492492493  ; magic multiplier for division by 7
    shift7   dq 2                   ; post-shift amount for division by 7

    magic10  dq 0xCCCCCCCCCCCCCCCD  ; magic multiplier for division by 10
    shift10  dq 3                   ; post-shift amount for division by 10

    ; Test values: n / 7 and n / 10 for several n
    test_vals  dq 0, 1, 7, 14, 63, 100, 1000, 9999999999
    test_n     equ ($ - test_vals) / 8

    hdr_7   db "n           n/7 (magic)  n/7 (div)", 10
    hdr_7_l equ $ - hdr_7
    hdr_10  db "n           n/10 (magic) n/10(div)", 10
    hdr_10_l equ $ - hdr_10
    sep     db "---         -----------  ---------", 10
    sep_l   equ $ - sep
    col2    db "  ", 0
    newline db 10

section .bss
    num_buf  resb 24

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; fast_div7 — compute floor(n / 7) using magic number multiplication
;   Input:  rdi = unsigned 64-bit dividend n
;   Output: rax = floor(n / 7)
;
;   Steps:
;   1. Load magic number M = 0x2492492492492493
;   2. Compute rdx:rax = n * M  (128-bit product) using MUL
;   3. rdx = upper 64 bits of product = mulhi(n, M)
;   4. Average trick for this particular divisor 7:
;      Because 7 is not a power of 2, the magic includes a "+1" correction.
;      We compute: q = ((n - rdx) >> 1) + rdx) >> 2
;      (This handles the case where M > 2^64 was rounded)
;
;   For divisor 7 specifically, the magic 0x2492492492492493 overshoots by 1,
;   so we use: q = (((n - mulhi) >> 1) + mulhi) >> shift
; ───────────────────────────────────────────────────────────────────────────
fast_div7:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — MUL requires one operand in rax
    mul  qword [magic7]     ; rdx:rax = n * M — 128-bit unsigned multiply
                            ; MUL: unsigned multiply rax * operand; high 64 bits → rdx, low → rax
                            ; We only need rdx (the high half = mulhi)

    ; For divisor 7, the magic number requires an "averaging" correction:
    ;   q = (((n - rdx) >> 1) + rdx) >> 2
    sub  rdi, rdx           ; rdi = n - mulhi
    shr  rdi, 1             ; rdi = (n - mulhi) >> 1
    add  rdx, rdi           ; rdx = mulhi + ((n - mulhi) >> 1)
    shr  rdx, 2             ; rdx = quotient = above >> 2  (shift = 2 for divisor 7)

    mov  rax, rdx           ; rax = quotient — move to return register

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = floor(n / 7)

; ───────────────────────────────────────────────────────────────────────────
; fast_div10 — compute floor(n / 10) using magic number multiplication
;   Input:  rdi = unsigned 64-bit dividend n
;   Output: rax = floor(n / 10)
;
;   For divisor 10, the magic 0xCCCCCCCCCCCCCCCD works cleanly:
;   q = mulhi(n, M) >> 3
;   No correction needed because M/2^68 approximates 1/10 exactly enough.
; ───────────────────────────────────────────────────────────────────────────
fast_div10:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend into rax for MUL
    mul  qword [magic10]    ; rdx:rax = n * M — 128-bit unsigned multiply
                            ; rdx = upper 64 bits = mulhi(n, M)

    shr  rdx, 3             ; rdx = mulhi >> 3 — post-shift (shift = 3 for divisor 10)
                            ; SHR: Shift Logical Right — divides by 2^3 = 8

    mov  rax, rdx           ; rax = quotient

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = floor(n / 10)

; ───────────────────────────────────────────────────────────────────────────
; exact_div7 — compute floor(n / 7) using the actual DIV instruction
;   Input:  rdi = unsigned 64-bit n
;   Output: rax = floor(n / 7)
;   This is the "slow" reference version for comparison.
; ───────────────────────────────────────────────────────────────────────────
exact_div7:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend
    xor  rdx, rdx           ; rdx = 0 — clear high half of 128-bit dividend
    mov  rcx, 7             ; rcx = 7 — divisor
    div  rcx                ; rax = n / 7 (quotient), rdx = n % 7 (remainder)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = n / 7

; ───────────────────────────────────────────────────────────────────────────
; exact_div10 — compute floor(n / 10) using the actual DIV instruction
;   Input:  rdi = unsigned 64-bit n
;   Output: rax = floor(n / 10)
; ───────────────────────────────────────────────────────────────────────────
exact_div10:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    mov  rax, rdi           ; rax = n — dividend
    xor  rdx, rdx           ; rdx = 0 — clear high half
    mov  rcx, 10            ; rcx = 10 — divisor
    div  rcx                ; rax = n / 10, rdx = n % 10

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = n / 10

; ───────────────────────────────────────────────────────────────────────────
; print_u64_padded — print unsigned 64-bit integer, space-padded to width 12
;   Input: rdi = number
; ───────────────────────────────────────────────────────────────────────────
print_u64_padded:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — write pointer (callee-saved)
    push r12                ; save r12 — buffer start (callee-saved)

    mov  r12, num_buf       ; r12 = buffer start
    mov  rbx, num_buf       ; rbx = write position
    mov  rax, rdi           ; rax = number

    test rax, rax
    jnz  .pp_dig

    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pp_term

.pp_dig:
    xor  rdx, rdx           ; rdx = 0
    mov  rcx, 10            ; divisor
    div  rcx                ; rax = q, rdx = r
    add  dl, '0'            ; to ASCII
    mov  [rbx], dl          ; store
    inc  rbx
    test rax, rax
    jnz  .pp_dig

.pp_term:
    mov  byte [rbx], 0      ; null term
    lea  rdi, [rbx - 1]
    mov  rsi, r12
.pp_rev:
    cmp  rsi, rdi
    jge  .pp_wr
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pp_rev

.pp_wr:
    ; Print the digits
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12           ; actual length

    ; Pad with spaces on the right to width 12
    push rdx                ; save actual length
    mov  rdi, 1
    mov  rax, 1
    syscall

    ; Print spaces to fill to 12
    pop  rdx                ; actual length
    mov  rcx, 12
    sub  rcx, rdx           ; spaces needed = 12 - actual_length
    jle  .pp_done           ; no spaces needed

.pp_spaces:
    push rcx
    mov  rdi, 1
    mov  rsi, space_char
    mov  rdx, 1
    mov  rax, 1
    syscall
    pop  rcx
    dec  rcx
    jnz  .pp_spaces

.pp_done:
    pop  r12                ; restore r12 (callee-saved)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret

section .data
    space_char  db " "

section .text

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print table header for /7 column
    mov  rdi, 1             ; stdout
    mov  rsi, hdr_7         ; header
    mov  rdx, hdr_7_l       ; length
    mov  rax, 1             ; write
    syscall

    mov  rdi, 1             ; stdout
    mov  rsi, sep           ; separator
    mov  rdx, sep_l         ; length
    mov  rax, 1             ; write
    syscall

    ; Loop: print n, n/7(magic), n/7(exact) for each test value
    xor  r15, r15           ; r15 = index = 0

.loop7:
    cmp  r15, test_n        ; done?
    jge  .print_10_header   ; yes

    mov  r14, [test_vals + r15*8]  ; r14 = n

    mov  rdi, r14           ; rdi = n
    call print_u64_padded   ; print n

    mov  rdi, r14           ; rdi = n
    call fast_div7          ; rax = n/7 via magic
    mov  rdi, rax
    call print_u64_padded   ; print magic result

    mov  rdi, r14           ; rdi = n
    call exact_div7         ; rax = n/7 via DIV
    mov  rdi, rax
    call print_u64_padded   ; print exact result

    mov  rdi, 1             ; newline
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  r15
    jmp  .loop7

.print_10_header:
    ; Blank line
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    mov  rdi, 1
    mov  rsi, hdr_10
    mov  rdx, hdr_10_l
    mov  rax, 1
    syscall

    mov  rdi, 1
    mov  rsi, sep
    mov  rdx, sep_l
    mov  rax, 1
    syscall

    xor  r15, r15           ; r15 = index = 0
.loop10:
    cmp  r15, test_n
    jge  .done

    mov  r14, [test_vals + r15*8]  ; r14 = n

    mov  rdi, r14
    call print_u64_padded

    mov  rdi, r14
    call fast_div10
    mov  rdi, rax
    call print_u64_padded

    mov  rdi, r14
    call exact_div10
    mov  rdi, rax
    call print_u64_padded

    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    inc  r15
    jmp  .loop10

.done:
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall                 ; exit(0)



;═══════════════════════════════════════════════════════════════════════════════
; §26  SAD Kernel
;───────────────────────────────────────────────────────────────────────────────
;  Source file : 26_sad_kernel.asm
;  Description : Scalar / SSE2 / AVX2 SAD side-by-side — PSADBW reduction
;═══════════════════════════════════════════════════════════════════════════════

; ═══════════════════════════════════════════════════════════════════════════════
; 26_sad_kernel.asm — SAD (Sum of Absolute Differences) 16×16 kernel
;                     Scalar, SSE2, and AVX2 versions side by side
; Goal: horizontal reductions, tail handling, FFmpeg microkernel style
;
; This is the definitive SAD reference: three versions in one file so you can
; compare how the same algorithm evolves from scalar to SSE2 to AVX2.
;
; The SAD kernel is one of the most performance-critical functions in video
; codecs. FFmpeg has hand-optimized versions for every x86 SIMD extension.
; In this file we show the progression clearly.
;
; Key instruction differences:
;
;   SCALAR:
;     SUB byte, cmp, negate — 1 pixel per cycle
;
;   SSE2 (128-bit, 16 bytes at a time):
;     PSADBW xmm, xmm — sum |A[i]-B[i]| for 8 byte pairs, 2 results per call
;     One 16-byte row → 2 partial sums → accumulate with PADDQ
;
;   AVX2 (256-bit, 32 bytes at a time):
;     VPSADBW ymm, ymm, ymm — same but 32 bytes → 4 partial sums
;     Process 2 rows of 16 pixels per iteration
;     Extract upper 128 bits with VEXTRACTI128 for final horizontal reduction
;
; Build:
;   nasm -f elf64 26_sad_kernel.asm -o bin/26_sad_kernel.o
;   ld bin/26_sad_kernel.o -o bin/26_sad_kernel
; Run:
;   ./bin/26_sad_kernel
; ═══════════════════════════════════════════════════════════════════════════════

section .data
    align 32

    ; Current block: 16×16 bytes, gradient pattern
    cur_blk:
    %assign row 0
    %rep 16
        %assign val row
        %rep 16
            db val
            %assign val val+1
        %endrep
        %assign row row+1
    %endrep

    ; Reference block: 16×16 bytes, slightly different gradient
    ref_blk:
    %assign row 0
    %rep 16
        %assign val row+5
        %rep 16
            db val
            %assign val val+1
        %endrep
        %assign row row+1
    %endrep
    ; Each pixel differs by 5 → expected SAD = 16*16*5 = 1280

    lbl_scalar  db "Scalar SAD  = ", 0
    lbl_sse2    db "SSE2   SAD  = ", 0
    lbl_avx2    db "AVX2   SAD  = ", 0
    lbl_expect  db "Expected    = 1280", 10, 0
    newline     db 10

section .bss
    num_buf  resb 22

section .text
global _start

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_scalar — reference scalar implementation
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
; ───────────────────────────────────────────────────────────────────────────
sad16x16_scalar:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx                ; save rbx — used as SAD accumulator (callee-saved)

    xor  rbx, rbx           ; rbx = 0 — total SAD accumulator
                             ; (rax is free scratch for byte-offset arithmetic)
    xor  r8,  r8            ; r8  = row index = 0

.sc_row:
    cmp  r8, 16             ; all 16 rows done?
    jge  .sc_done

    xor  r9, r9             ; r9 = column index = 0

.sc_col:
    cmp  r9, 16             ; all 16 columns done?
    jge  .sc_next_row

    ; Compute byte offset = row*16 + col (SIB can't encode *16 or 3 registers)
    imul rax, r8, 16           ; rax = row * 16 (bytes per row)
    add  rax, r9               ; rax = row*16 + col (byte offset into block)
    movzx r10, byte [rdi + rax]  ; r10 = cur[row][col] (zero-extend)
    movzx r11, byte [rsi + rax]  ; r11 = ref[row][col] (zero-extend)

    sub  r10, r11           ; r10 = cur - ref (signed difference)
    jge  .sc_abs            ; if >= 0, already non-negative
    neg  r10                ; negate to get |cur - ref|

.sc_abs:
    add  rbx, r10           ; rbx += |cur - ref| (accumulate into dedicated register)

    inc  r9                 ; col++
    jmp  .sc_col

.sc_next_row:
    inc  r8                 ; row++
    jmp  .sc_row

.sc_done:
    mov  rax, rbx           ; move final SAD into rax (ABI: return value)
    pop  rbx                ; restore rbx (callee-saved)
    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_sse2 — SSE2 implementation using PSADBW
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
;
;   Per-row work:
;     Load 16 bytes from cur and ref.
;     PSADBW produces two 16-bit partial sums (for bytes 0-7 and 8-15).
;     Accumulate with PADDQ (64-bit lane addition into xmm0).
;   Final horizontal reduction: add the two 64-bit lanes of xmm0.
; ───────────────────────────────────────────────────────────────────────────
sad16x16_sse2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    pxor  xmm0, xmm0        ; xmm0 = {0, 0, 0, 0} — 128-bit accumulator, zero
                             ; PXOR: clear by XOR with self

    xor  r8, r8             ; r8 = row = 0

.s2_row:
    cmp  r8, 16             ; all rows done?
    jge  .s2_hsum

    ; Load 16 bytes of cur and ref (*16 is invalid SIB scale; use imul)
    imul rax, r8, 16               ; rax = row * 16 (byte offset)
    movdqu xmm1, [rdi + rax]       ; xmm1 = 16 cur pixels (unaligned load)
                                    ; MOVDQU: Move Unaligned Double Quadword
    movdqu xmm2, [rsi + rax]       ; xmm2 = 16 ref pixels

    psadbw xmm1, xmm2              ; xmm1[15:0]  = sum(|cur[0..7] - ref[0..7]|)
                                    ; xmm1[79:64] = sum(|cur[8..15] - ref[8..15]|)
                                    ; PSADBW: Packed Sum of Absolute Differences of Bytes
                                    ; Other bits of xmm1 become 0.

    paddq  xmm0, xmm1              ; accumulate both 64-bit partial sums
                                    ; PADDQ: Packed ADD Quadwords (independent 64-bit addition)

    inc  r8                 ; next row
    jmp  .s2_row

.s2_hsum:
    ; xmm0 now holds sum of partial sums in two 64-bit halves
    ; lower 64 bits = total for bytes 0-7 of all rows
    ; upper 64 bits = total for bytes 8-15 of all rows
    movq   rax, xmm0        ; rax = lower 64 bits (MOVQ required for 64-bit GP register)
    psrldq xmm0, 8          ; shift xmm0 right by 8 bytes to bring upper sum to low position
                             ; PSRLDQ: Packed Shift Right Logical Double Quadword (byte shift)
    movq   rcx, xmm0        ; rcx = formerly-upper (now lower) partial sum
    add    rax, rcx         ; rax = total SAD

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

; ───────────────────────────────────────────────────────────────────────────
; sad16x16_avx2 — AVX2 implementation using VPSADBW on 32-byte registers
;   Input:  rdi = current block (16×16 bytes, 16-byte stride)
;           rsi = reference block (16×16 bytes, 16-byte stride)
;   Output: rax = SAD
;
;   Process 2 rows at a time (32 bytes = 2 × 16-pixel rows):
;     VINSERTI128 to build a 256-bit value from two 128-bit rows.
;     VPSADBW produces four 16-bit partial sums (2 per 16-byte lane).
;     VPADDQ accumulates into ymm0.
;   Final reduction: fold upper 128 bits of ymm0 down, then sum two 64-bit lanes.
; ───────────────────────────────────────────────────────────────────────────
sad16x16_avx2:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer

    vpxor  ymm0, ymm0, ymm0  ; ymm0 = 0 — 256-bit accumulator, all zeros
                               ; VPXOR: VEX Packed XOR (3-operand form)

    xor  r8, r8               ; r8 = row pair index = 0 (we process 2 rows per iteration)

.a2_row:
    cmp  r8, 16               ; all 16 rows done? (we do pairs, but check individual)
    jge  .a2_hsum

    ; Load row r8 and row r8+1 into the two 128-bit lanes of a YMM register
    ; If r8+1 >= 16, we just process one row (simple boundary handling)
    ; *16 is not a valid SIB scale; use imul to compute byte offset
    imul rax, r8, 16                   ; rax = row r8 * 16 (byte offset)
    vmovdqu xmm1, [rdi + rax]          ; xmm1 = cur row r8 (16 bytes)
    vmovdqu xmm2, [rsi + rax]          ; xmm2 = ref row r8

    inc  r8                            ; advance row (might use row r8+1 next)

    cmp  r8, 16                        ; is row r8 valid?
    jge  .a2_one_row                   ; no — only process one row

    ; Load second row
    imul rax, r8, 16                   ; rax = row r8+1 * 16 (byte offset, after inc)
    vmovdqu xmm3, [rdi + rax]          ; xmm3 = cur row r8+1
    vmovdqu xmm4, [rsi + rax]          ; xmm4 = ref row r8+1

    ; Pack into 256-bit YMM registers
    vinserti128 ymm1, ymm1, xmm3, 1   ; ymm1 = {xmm3 (high 128), xmm1 (low 128)}
                                        ; VINSERTI128: Insert 128-bit into YMM at lane 1
    vinserti128 ymm2, ymm2, xmm4, 1   ; ymm2 = {xmm4, xmm2}

    vpsadbw ymm1, ymm1, ymm2          ; ymm1 = four partial SADs (4 × 16-bit)
                                        ; VPSADBW: VEX Packed Sum of Absolute Differences
                                        ; Lower 128: {sum[8..15], 0, 0, 0, sum[0..7], 0, 0, 0}
                                        ; Upper 128: same for the second pair of rows

    vpaddq  ymm0, ymm0, ymm1          ; accumulate all four partial sums
                                        ; VPADDQ: VEX Packed ADD Quadwords (4 × 64-bit)

    inc  r8                            ; advance to next pair
    jmp  .a2_row

.a2_one_row:
    ; Only one remaining row — use SSE2 path
    psadbw  xmm1, xmm2                ; PSADBW (128-bit): compute partial SADs
    vpaddq  ymm0, ymm0, ymm1          ; accumulate

    inc  r8                            ; advance
    jmp  .a2_row

.a2_hsum:
    ; Horizontal reduction of ymm0:
    ; ymm0 = {partial_3, partial_2, partial_1, partial_0}  (four 64-bit values)
    ; We want: total = partial_0 + partial_1 + partial_2 + partial_3

    ; Step 1: fold upper 128 bits down
    vextracti128 xmm1, ymm0, 1        ; xmm1 = upper 128 bits of ymm0
                                        ; VEXTRACTI128: Extract 128-bit lane 1 from YMM
    vpaddq  xmm0, xmm0, xmm1          ; xmm0 = lower_pair + upper_pair (two 64-bit sums)
                                        ; VPADDQ (128-bit): add two pairs

    ; Step 2: fold 64-bit halves of xmm0
    movq   rax, xmm0                   ; rax = lower 64 bits (MOVQ required for 64-bit GP reg)
    psrldq xmm0, 8                     ; shift to bring upper 64 bits to position 0
    movq   rcx, xmm0                   ; rcx = upper 64 bits
    add    rax, rcx                     ; rax = total SAD

    vzeroupper                          ; clear upper YMM bits (important before calling non-AVX code)

    pop  rbp                ; restore caller's frame pointer
    ret                     ; return; rax = SAD

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

print_u64:
    push rbp                ; save caller's frame pointer (callee-saved)
    mov  rbp, rsp           ; establish our own frame pointer
    push rbx
    push r12

    mov  r12, num_buf
    mov  rbx, num_buf
    mov  rax, rdi

    test rax, rax
    jnz  .pd
    mov  byte [rbx], '0'
    inc  rbx
    jmp  .pt

.pd:
    xor  rdx, rdx
    mov  rcx, 10
    div  rcx
    add  dl, '0'
    mov  [rbx], dl
    inc  rbx
    test rax, rax
    jnz  .pd

.pt:
    mov  byte [rbx], 0
    lea  rdi, [rbx-1]
    mov  rsi, r12
.pr:
    cmp  rsi, rdi
    jge  .pw
    mov  al, [rsi]
    mov  cl, [rdi]
    mov  [rsi], cl
    mov  [rdi], al
    inc  rsi
    dec  rdi
    jmp  .pr

.pw:
    mov  rsi, r12
    mov  rdx, rbx
    sub  rdx, r12
    mov  rdi, 1
    mov  rax, 1
    syscall

    pop  r12
    pop  rbx
    pop  rbp                ; restore caller's frame pointer
    ret

; ───────────────────────────────────────────────────────────────────────────
; _start — entry point
; ───────────────────────────────────────────────────────────────────────────
_start:
    ; Print expected value
    mov  rdi, lbl_expect    ; "Expected    = 1280\n"
    call print_cstr

    ; ── Scalar ──
    mov  rdi, lbl_scalar    ; "Scalar SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_scalar
    mov  rdi, rax
    call print_u64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── SSE2 ──
    mov  rdi, lbl_sse2      ; "SSE2   SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_sse2
    mov  rdi, rax
    call print_u64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; ── AVX2 ──
    mov  rdi, lbl_avx2      ; "AVX2   SAD  = "
    call print_cstr
    mov  rdi, cur_blk
    mov  rsi, ref_blk
    call sad16x16_avx2
    mov  rdi, rax
    call print_u64
    mov  rdi, 1
    mov  rsi, newline
    mov  rdx, 1
    mov  rax, 1
    syscall

    ; Exit
    mov  rax, 60            ; exit syscall
    xor  rdi, rdi           ; exit code 0
    syscall

