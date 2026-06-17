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
