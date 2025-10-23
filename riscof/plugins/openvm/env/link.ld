/* OpenVM linker script for RISC-V architecture tests */

OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x10000, LENGTH = 512M
}

PHDRS
{
    text PT_LOAD FLAGS(5);  /* R+X = 5 (read + execute) */
    data PT_LOAD FLAGS(6);  /* RW = 6 (read + write) */
}

SECTIONS
{
    . = 0x10000;

    .text : {
        *(.text.rvtest_entry_point)
        *(.text._start)
        *(.text*)
    } > RAM : text

    . = ALIGN(0x1000);
    .tohost : {
        *(.tohost)
    } > RAM : data

    .rodata : {
        *(.rodata*)
    } > RAM : data

    /* Place float library entry pointer at fixed address where OpenVM expects it */
    . = 0x1F440;
    .float_lib_entry : {
        _float_lib_entry = .;
        . += 4;  /* Reserve 4 bytes for the function pointer */
    } > RAM : data

    .data : {
        *(.data*)
        *(.sdata*)
        /* Force 8 bytes padding after signature to match REF (144 bytes total) */
        . = ALIGN(16);
    } > RAM : data

    .bss : {
        *(.bss*)
        *(.sbss*)
    } > RAM : data

    _end = .;

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
    }
}
