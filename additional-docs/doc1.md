#### when I compare 01_hello_world.asm and 02_hello_args.asm the \_start in the latter does not have the "push rbp" , "pop rbp" ceremony. why

The subroutines (str_len, sys_write, print_str) do have push rbp/pop rbp — because they are real functions that get called.
\_start itself skips it for a fundamental reason:

\_start is not a function. The kernel jumps to it — it doesn't call it.

When the kernel launches a process it doesn't push a return address before jumping to \_start. The stack at that moment looks like this:

```asm
    [rsp +  0]  → argc
    [rsp +  8]  → argv[0]   (pointer to program name)
    [rsp + 16]  → argv[1]   (pointer to first argument)
    ...
```

There is no return address, and there is no caller's rbp to save. If you wrote push rbp at \_start, you'd be pushing garbage (rbp is uninitialised). If you then tried to ret, you'd pop argc off the stack as if it were a return address and jump to address 2 — instant crash.

This is why \_start must terminate with an explicit exit syscall instead of ret:

```asm
    mov rax, 60 ; syscall number for exit()
    xor rdi, rdi ; exit code 0
    syscall ; hand control back to the kernel — never returns
```

Contrast with main: the C runtime (crt0) calls main with a proper call instruction, pushing a return address. That's why main gets the full prologue/epilogue — it has a real caller to return to, and the ABI requires rbp to be preserved.

In short: push rbp / pop rbp is the convention for callable functions. \_start is an entry label for the process itself, not a callable function.
