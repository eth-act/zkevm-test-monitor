OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  /* Float handler at fixed address for OpenVM transpiler */
  /* MUST be at 0x10000000 to match transpiler expectations */
  /* Must be below OpenVM's MEM_SIZE limit of 0x20000000 (512MB) */
  . = 0x10000000;
  .float_handler : {
    *(.float_handler)
  }

  /* All code (including float runtime) starts at non-zero address */
  /* This prevents float runtime functions from being at address 0 */
  /* Must be below OpenVM's MEM_SIZE limit of 0x20000000 (512MB) */
  . = 0x00010000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text .text.*) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .data : {
    *(.data)
    /* Force 8 bytes padding after signature to match REF (144 bytes total) */
    . = ALIGN(16);
  }
  .bss : { *(.bss) }

  /* OpenVM Float Runtime Support - NOLOAD sections */
  . = ALIGN(16);

  /* Integer register file for runtime - 32 registers x 4 bytes at 16-byte stride */
  . = ALIGN(16);
  .int_regs (NOLOAD) : {
    . = . + 512;  /* 32 * 16 bytes */
  }

  /* Float register file - 32 registers x 4 bytes = 128 bytes */
  . = ALIGN(16);
  .float_regs (NOLOAD) : {
    . = . + 128;
  }

  _end = .;
}
