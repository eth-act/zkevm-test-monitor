# Float library initialization for RISCOF tests
# This file sets up the function pointer for the float library

.section .text.init
.globl _float_init
_float_init:
    # Store address of _zisk_float_wrapper into FLOAT_LIB_ENTRY_PTR (0x00100000)
    # This is where the OpenVM transpiler looks for the float library entry point
    # We use the wrapper instead of _zisk_float directly to handle sp properly
    lui t0, %hi(_zisk_float_wrapper)
    addi t0, t0, %lo(_zisk_float_wrapper)

    # 0x00100000 = 1MB (provides space for test code while keeping binary size reasonable)
    li t1, 0x00100000
    sw t0, 0(t1)

    ret

# Wrapper for _zisk_float that sets up a valid stack pointer
# RISCOF tests may use sp as a general-purpose register, so we need to
# save it and set up a known-good sp before calling the C float handler
.section .text
.globl _zisk_float_wrapper
_zisk_float_wrapper:
    # Save the test's sp and ra values to reserved memory locations
    # Use 0x00100004 and 0x00100008 (just after FLOAT_LIB_ENTRY_PTR)
    lui t0, 0x100
    addi t0, t0, 4
    sw sp, 0(t0)
    sw ra, 4(t0)

    # Set up a valid stack pointer at 8MB (well within 512MB limit)
    # This gives the float handler plenty of stack space
    lui sp, 0x800

    # Call the actual float handler (which uses stack for local variables)
    call _zisk_float

    # Restore the original sp and ra values
    lui t0, 0x100
    addi t0, t0, 4
    lw sp, 0(t0)
    lw ra, 4(t0)

    ret

# Weak reference to _zisk_float (provided by libziskfloat.a)
.weak _zisk_float
