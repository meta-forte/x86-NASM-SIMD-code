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
