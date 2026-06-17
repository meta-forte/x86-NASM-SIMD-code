# Prompt: Add New Programs to the x86 NASM Learning Collection

Copy everything below this line and paste it as your opening message in a new
conversation with Claude Code (run from the repo root).

---

## Context

I have an x86-64 NASM assembly self-learning repository at the current working
directory. It currently contains **41 programs** organised in 8 sections by
increasing complexity:

| # | Section | Programs |
|---|---------|----------|
| 01 | Hello World & I/O | 01–05 |
| 02 | Arithmetic | 06–10 |
| 03 | Strings & Memory | 11–17 |
| 04 | Sorting & Algorithms | 18–25 |
| 05 | Bit Manipulation | 26–27 |
| 06 | Matrices | 28–31 |
| 07 | SIMD Basics | 32–37 |
| 08 | Image & Signal Processing | 38–41 |

### Directory layout

```
src/          — NNN_name.asm  (41 files, 01_hello_world.asm … 41_sad_kernel.asm)
comments/     — NNN_name.json (41 files, matching the src/ names)
webapp/       — index.html    (static single-page app, lists all files)
Makefile      — auto-discovers src/*.asm; links with gcc or ld based on entry point
GITHUB_PAGES.md — how to deploy via GitHub Actions
```

### ASM coding standards (must follow for every new program)

1. **Entry point**: use `global main` + link with `gcc -no-pie -lm` (not `_start`/`ld`).
2. **No .bss for local arrays**: allocate stack space with `sub rsp, N`. Reserve `.bss`
   only for truly global state.
3. **I/O subroutines**: wrap every `printf`/`scanf` call in a named subroutine
   (e.g. `print_int`, `read_int`, `print_str`) so call sites stay readable.
4. **Stack alignment**: keep `rsp` 16-byte aligned before every `call`. Track the
   alignment as a comment: `; (ret 8)+(rbp 8)+(pushed regs N*8)+(sub rsp M) = total`.
5. **Callee-saved registers**: use `rbx`, `r12`–`r15` for values that must survive
   a `call`; push them in the prologue and pop (in reverse) before `ret`.
6. **Comments**: one comment per instruction line explaining WHAT it does. The JSON
   sidecar explains WHY (see annotation format below).
7. **Build comment block** at the top of each file:
   ```
   ; Build:
   ;   nasm -f elf64 NNN_name.asm -o obj/NNN_name.o
   ;   gcc   obj/NNN_name.o -o bin/NNN_name -no-pie
   ```

### JSON annotation format (`comments/NNN_name.json`)

Explain WHY each instruction exists — not what it does. Pick 15–30 key lines.

```json
{
  "LINE_NUMBER": {
    "instruction": "exact instruction text from that line",
    "why": "2–4 sentences: why this specific instruction, what breaks without it, why this form over alternatives.",
    "doc_url": "https://www.felixcloutier.com/x86/MNEMONIC"
  }
}
```

Good candidates to annotate: `push rbp`/`mov rbp,rsp`, `xor eax,eax` before variadic
calls (ABI float-count rule), `cqo` before `idiv` (sign-extension), callee-saved
register saves, `lea [rel ...]` (RIP-relative), SIMD instruction choice rationale.

### Webapp update (`webapp/index.html`)

The file list is in the `const FILES = [...]` array inside the `<script>` block.
Each group has a `label` and a `files` array. Add new entries in the correct section
or create a new section if the programs belong to a new topic.

---

## Task

Please add the following **N new programs** to the collection, continuing the
numbering from 42:

```
42_<name> — <one-line description>
43_<name> — <one-line description>
... (fill in the programs you want)
```

Suggested section placement:
- `<section name>` (or "create new section: <name>")

For each program:
1. Write `src/NNN_name.asm` following the coding standards above.
2. Write `comments/NNN_name.json` with WHY-focused annotations.
3. Add the filename to the correct group in `webapp/index.html`'s `FILES` array.

After writing the files, verify with:
```bash
ls src/ | wc -l      # should be 41 + N
ls comments/ | wc -l # should be 41 + N
```

---

## Program ideas by section (for reference)

### Extending existing sections

**Hello World & I/O (06+)**
- Read and print a float with scanf/printf `%lf`
- Print a formatted table with column alignment (`%-10s %5d`)
- Read a line with `fgets`, trim the newline, echo it back

**Arithmetic (11+)**
- Prime sieve (Sieve of Eratosthenes) up to N
- Integer square root (Newton's method in integer arithmetic)
- Modular exponentiation (`base^exp mod m`) — useful for crypto basics
- Arbitrary-precision add (two 128-bit numbers using ADC)

**Strings & Memory (18+)**
- Count vowels and consonants
- Run-length encoding (compress "aaabbc" → "3a2b1c")
- Caesar cipher encode/decode
- Levenshtein edit distance (DP table on stack)

**Sorting & Algorithms (26+)**
- Merge sort (recursive, stack-allocated temp buffer)
- Heap sort (in-place)
- Binary search on a sorted array
- Stack implementation (push/pop via array on stack)
- Queue implementation (circular buffer)

**Bit Manipulation (28+)**
- Gray code encode/decode
- Find next power of two
- Reverse bits of a 64-bit integer
- Detect if a number is a power of two

**Matrices (32+)**
- Determinant of a 3×3 matrix (cofactor expansion)
- Matrix-vector multiply (Ax = b)
- Strassen 2×2 matrix multiply
- LU decomposition (Doolittle, integer-scaled)

**SIMD Basics (38+)**
- SIMD string length (`pcmpeqb` + `pmovmskb`)
- SIMD horizontal max of an int32 array
- SIMD FP32 array scale-and-clamp
- AES-NI single round (`aesenc`)

**Image & Signal Processing (42+)**
- Box blur (3×3 mean filter) via SIMD horizontal sliding window
- Sobel edge detection (horizontal + vertical gradient)
- Bilinear interpolation (fixed-point 2× upscale)
- FIR low-pass filter (PMADDWD accumulation)
- JPEG-style zigzag scan of an 8×8 block

### New sections to consider (programs 60+)

**Floating-Point & Math**
- SSE/AVX scalar sqrt, sin approximation (Taylor series)
- Vectorised polynomial evaluation (Horner's method, `vfmadd`)

**Cryptography Primitives**
- AES-128 key expansion + encrypt block (AES-NI)
- SHA-256 message schedule (rotate, XOR, add)
- ChaCha20 quarter-round

**Systems & OS Interaction**
- Raw syscall wrappers (read, write, open, close without libc)
- `/proc/self/maps` parser (read virtual memory layout)
- `rdtsc`-based cycle counter microbenchmark

**Networking / Protocols**
- IP checksum (one's-complement sum)
- CRC-32 (table-based, then SIMD `crc32` instruction)
