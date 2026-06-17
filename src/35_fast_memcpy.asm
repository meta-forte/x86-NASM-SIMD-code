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
