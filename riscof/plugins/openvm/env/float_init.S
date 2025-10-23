# Float library initialization for RISCOF tests
# This file sets up the function pointer for the float library

.section .text.init
.globl _float_init
_float_init:
    # Store address of _zisk_float into FLOAT_LIB_ENTRY_PTR (0x00100000)
    # This is where the OpenVM transpiler looks for the float library entry point
    lui t0, %hi(_zisk_float)
    addi t0, t0, %lo(_zisk_float)

    # 0x00100000 = 1MB (provides space for test code while keeping binary size reasonable)
    li t1, 0x00100000
    sw t0, 0(t1)

    ret

# Weak reference to _zisk_float (provided by libziskfloat.a)
.weak _zisk_float
