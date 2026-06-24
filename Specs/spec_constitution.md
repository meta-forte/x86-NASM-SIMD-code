### Coding conventions

- Use these macros and add them at the beginning and end of subroutines.

```asm
    %macro PROLOGUE 0
        push rbp
        mov  rbp, rsp
    %endmacro

    %macro EPILOGUE 0
        pop  rbp
        ret
%endmacro

```
