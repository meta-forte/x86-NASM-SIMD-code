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
