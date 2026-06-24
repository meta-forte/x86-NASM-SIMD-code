# `_start` vs `main` — how Linux decides what to run first

<div class="kb-meta">Companion article for <code>02_hello_args.asm</code> · covers: ELF internals, crt0, ld vs gcc</div>

If you compare `01_hello_world.asm` and `02_hello_args.asm` side by side, two things look odd about `02_hello_args`:

1. The entry point is `_start`, not `main`.
2. `_start` has no `push rbp` / `mov rbp, rsp` prologue.

Neither is an oversight. They are consequences of a single architectural decision: whether the program is linked against the C runtime library.

---

## How the kernel decides what to run

When you type `./program` in the shell, the shell calls `execve()`. The kernel reads the binary — which is in **ELF format** — and looks for a program header of type `PT_INTERP`. That header, if present, contains a path like:

```
/lib64/ld-linux-x86-64.so.2
```

This is the **dynamic linker** (also called the ELF interpreter). Its presence or absence is the single switch:

| PT_INTERP present? | What happens |
|---|---|
| **No** | Kernel maps the ELF segments into memory, then jumps directly to the address in the `e_entry` field — your `_start` label |
| **Yes** | Kernel loads the dynamic linker first; the dynamic linker maps all `.so` dependencies (including `libc`), then runs the C runtime startup code, which eventually calls your `main()` |

You can inspect any binary yourself:

```bash
readelf -l bin/02_hello_args  | grep INTERP   # no output — bare binary
readelf -l bin/01_hello_world | grep INTERP   # prints the ld-linux path
file bin/02_hello_args    # "statically linked"
file bin/01_hello_world   # "dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2"
```

---

## The stack at `_start` — not what you expect

When the kernel jumps to `_start`, the stack looks like this:

```
rsp + 0         →  argc          (8-byte integer: number of arguments)
rsp + 8         →  argv[0]       (pointer to the program name string)
rsp + 16        →  argv[1]       (pointer to the first user argument)
rsp + 24        →  argv[2]       ...
rsp + 8*(argc+1) → NULL          (end-of-array sentinel)
```

The kernel set this up before the jump. There is **no return address** on the stack. The CPU did not execute a `call` instruction to get here — it executed a plain jump. This has two immediate consequences:

**You cannot `ret` from `_start`.** `ret` pops the top of the stack and jumps to it. The top of the stack is `argc` (a small integer like `1` or `2`). The CPU would try to jump to address `0x0000000000000002` — an instant segfault. You must terminate by calling `exit` via syscall:

```asm
mov  rax, 60   ; syscall number for exit()
xor  rdi, rdi  ; exit code 0
syscall
```

**You cannot save a "caller's rbp"** — there is no caller. If you wrote `push rbp` at `_start`, you'd be pushing whatever garbage happens to be in `rbp` at process start (undefined). The subroutines `str_len`, `sys_write`, etc. *do* have `push rbp` because they *are* called with `call`, so they have a real return address and a real caller whose `rbp` they must preserve.

---

## What `gcc` adds behind the scenes

When you link with `gcc`, it doesn't just call `ld` — it is a **compiler driver** that constructs a much longer `ld` invocation:

```bash
# What gcc -no-pie actually runs (simplified):
ld  \
  /usr/lib/x86_64-linux-gnu/crt1.o   \   # ← _start lives here
  /usr/lib/x86_64-linux-gnu/crti.o   \   # ← .init section prologue
  obj/hello_world.o                   \   # ← your code
  -lc                                 \   # ← libc.so.6 (printf, malloc, …)
  /usr/lib/x86_64-linux-gnu/crtn.o   \   # ← .init section epilogue
  --dynamic-linker /lib64/ld-linux-x86-64.so.2 \
  -o bin/hello_world
```

`crt1.o` contains the real `_start`. Its job is:

1. Read `argc`, `argv`, `envp` from the stack.
2. Call `__libc_start_main(main, argc, argv, init, fini, rtld_fini)`.
3. `__libc_start_main` registers `atexit` handlers, runs C++ constructors, then calls **your** `main()`.
4. When `main()` returns, `__libc_start_main` calls `exit(rax)`.

So your `main` is not the entry point — it is a function that crt0's `_start` calls. That is why `main` gets the full `push rbp` / `mov rbp, rsp` prologue: it is a normal C function with a real caller (`__libc_start_main`) that expects the callee-save convention to be honoured.

---

## `ld` vs `gcc` — practical difference

| | `ld` (direct) | `gcc` (compiler driver) |
|---|---|---|
| Entry point | Your `_start` | `crt1.o`'s `_start` → your `main()` |
| libc available | No | Yes (`printf`, `scanf`, `malloc`, …) |
| `PT_INTERP` in binary | No | Yes |
| Termination | `syscall` (exit = 60) | `ret` from `main`, or `exit()` |
| Binary size | ~1 KB | ~15 KB (linked against libc) |
| `-no-pie` flag | Not needed | Needed to use fixed virtual addresses |

**`-no-pie`** tells gcc to produce a non-position-independent executable — the binary loads at a fixed virtual address (typically `0x401000`). The default on modern Linux is PIE (Position Independent Executable), which allows ASLR. Our programs use `[rel label]` (RIP-relative addressing) which is PIE-compatible, but `-no-pie` keeps the linker setup simpler for learning.

---

## Verify it yourself

```bash
# See the ELF entry point address
readelf -h bin/02_hello_args  | grep "Entry point"
# → 0x401000 — your _start

readelf -h bin/01_hello_world | grep "Entry point"
# → 0x401050 — crt1's _start (inside glibc startup code)

# See all program headers
readelf -l bin/02_hello_args
readelf -l bin/01_hello_world   # notice the INTERP segment
```

---

## What is `ld`?

`ld` is the **GNU linker**, part of a package called **GNU Binutils** (Binary Utilities). It is written almost entirely in **C** — you can browse the source at `sourceware.org/git/binutils-gdb.git`; the main files are `ld/ldmain.c`, `ld/ldelf.c`, and `ld/ldlang.c`.

The name comes from Unix history: Bell Labs called it the **"link editor"** in the 1970s. The name stuck even though modern linkers do far more than simple editing.

### What `ld` does, step by step

**1. Reads object files (`.o`)**
Each `.o` file produced by `nasm` contains machine code, a symbol table (names defined or referenced), and *relocation entries* — placeholders marking spots where a final address still needs to be filled in.

**2. Resolves symbols**
If `hello_world.o` calls `printf`, and `libc.so` defines `printf`, `ld` matches them up. If a symbol is referenced but never defined anywhere, you get the classic error:
```
undefined reference to 'foo'
```

**3. Assigns virtual addresses**
Decides where each section (`.text`, `.data`, `.bss`) lives in memory. This is controlled by a **linker script** — a text file describing the memory layout. `gcc` ships a default one; `-no-pie` selects the variant that uses fixed addresses starting at `0x401000`.

**4. Applies relocations**
Patches every placeholder in the machine code with the real address now that everything has been placed. For example, a `call printf` was assembled with a dummy offset of `0x00000000`; `ld` replaces it with the actual offset to `printf` in libc.

**5. Writes the ELF binary**
Produces the finished executable: ELF header, program headers (including `PT_INTERP` when linking against shared libraries), all sections at their assigned addresses, and an optional symbol table.

### The GNU Binutils family

`ld` lives alongside several tools you will use regularly:

| Tool | What it does |
|---|---|
| `ld` | Linker |
| `as` | GNU assembler (an alternative to `nasm`) |
| `objdump` | Disassemble a binary or dump its sections |
| `readelf` | Inspect ELF headers, sections, and symbols |
| `nm` | List symbols in an object file or library |
| `strip` | Remove the symbol table from a binary (shrinks file size) |
| `ar` | Bundle `.o` files into a static library (`.a`) |

The full toolchain for your programs is therefore:

```
nasm (assembler, written in C)
  → produces .o  (object file — machine code + relocation entries)
    → ld or gcc (linker, written in C)
      → ELF binary (raw machine code the CPU executes directly)
```

---

## What is inside an object file?

An object file is **binary**, not plain text. It uses the same **ELF format** as the final executable — the difference is the type field in the ELF header says `ET_REL` (relocatable) instead of `ET_EXEC` (executable).

An `.o` file is a collection of named sections:

| Section | Contents |
|---|---|
| `.text` | The actual Intel opcodes — raw binary bytes, exactly what the CPU will execute |
| `.data` | Initialised globals and constants (your `db "Hello, World!", 10, 0`) |
| `.bss` | Uninitialised globals — recorded as a size only, zero bytes in the file |
| `.rodata` | Read-only data (string literals in C programs) |
| `.symtab` | Symbol table — names of every label defined or referenced, with offsets |
| `.strtab` | The actual name strings that `.symtab` points into |
| `.rela.text` | Relocation entries — the list of addresses still to be filled in |

You can inspect all of this:

```bash
readelf -S obj/01_hello_world.o   # list all sections and their sizes
readelf -s obj/01_hello_world.o   # symbol table
objdump -d obj/01_hello_world.o   # disassemble .text
objdump -r obj/01_hello_world.o   # relocation entries
hexdump -C obj/01_hello_world.o | head -4   # raw bytes (first 4: ELF magic)
```

The first four bytes of every ELF file are always `7f 45 4c 46` — that is `0x7f` followed by the ASCII letters `E`, `L`, `F`. The kernel's `execve()` checks for this magic sequence before doing anything else.

### The `.text` section — real opcodes, placeholder addresses

The `.text` section contains genuine Intel machine code. If you disassemble an object file before linking:

```bash
objdump -d obj/01_hello_world.o
```

You see something like:

```
0000000000000000 <print_str>:
   0:  55                      push   rbp
   1:  48 89 e5                mov    rbp, rsp
   4:  31 c0                   xor    eax, eax
   6:  e8 00 00 00 00          call   b <print_str+0xb>   ← placeholder!
   b:  5d                      pop    rbp
   c:  c3                      ret
```

That `e8 00 00 00 00` is the `call` instruction. `e8` is the real opcode for a near call. The four bytes `00 00 00 00` are the relative offset to the target — and they are a placeholder. `nasm` did not know where `printf` would live, so it wrote zeroes and recorded a note in the relocation table.

### The `.rela.text` section — the patch list

Each relocation entry says: *at this byte offset in `.text`, replace the placeholder with this symbol's address, adjusted by this addend.*

```bash
objdump -r obj/01_hello_world.o
```

Output:

```
RELOCATION RECORDS FOR [.text]:
OFFSET           TYPE              VALUE
0000000000000007 R_X86_64_PLT32    printf-0x4
```

| Field | Value | Meaning |
|---|---|---|
| `OFFSET` | `0x7` | Patch the 4 bytes starting at byte 7 of `.text` |
| `TYPE` | `R_X86_64_PLT32` | 32-bit relative address, routed via the PLT (shared-library call stub) |
| `VALUE` | `printf-0x4` | Use the address of `printf` minus 4 (accounts for how x86 relative calls measure from the *end* of the instruction) |

When `ld` runs, it works through every entry in `.rela.text`, computes the real address, and writes the correct bytes into the final binary. That is what "applying relocations" means.

### Before vs after linking

```bash
# Before linking — placeholder offset in the call instruction
objdump -d obj/01_hello_world.o
#   e8 00 00 00 00    call  <printf>       ← 0x00000000

# After linking — real relative offset
objdump -d bin/01_hello_world
#   e8 b5 fe ff ff    call  <printf@plt>   ← -0x14b (real offset to PLT stub)
```

The opcode `e8` is identical in both. Only the four address bytes changed — that is the entire job of the linker for that instruction.
