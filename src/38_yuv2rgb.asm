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
