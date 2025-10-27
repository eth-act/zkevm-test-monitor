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

    /* Place float library entry pointer at fixed address where OpenVM expects it */
    /* Moved to 0x1F0000 (just before float registers at 0x200000) to avoid conflicts with large .text sections */
    .float_lib_entry 0x001F0000 : {
        _float_lib_entry = .;
        LONG(0);  /* Reserve 4 bytes, will be initialized by _float_init */
    } > RAM : data

    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
    }
}
