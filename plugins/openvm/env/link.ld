OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x0;
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { 
    *(.data) 
    /* Force 8 bytes padding after signature to match REF (144 bytes total) */
    . = ALIGN(16);
  }
  .bss : { *(.bss) }
  _end = .;
}
