OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/* Pico's ELF compiler scans entire PT_LOAD segments with execute permissions.
 * Keep all executable sections together before .tohost so they form a single
 * R E segment.  .tohost and .data land in a separate RW segment. */
SECTIONS
{
  . = 0x20000000;
  /* .text.init is padded to a 4096-byte boundary with NOPs so that
   * .text.rvtest (which has 4096-byte section alignment) starts at a
   * page boundary with no zero-fill gap in the R E segment. */
  .text.init : {
    FILL(0x13000000)
    *(.text.init)
    . = ALIGN(0x1000);
  }
  /* All ACT4 test code sections, immediately following .text.init. */
  .text : {
    FILL(0x13000000)
    *(.text) *(.text.rvtest) *(.text.rvmodel) *(.text.*)
  }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) *(.data.string) }
  . = ALIGN(0x1000);
  .bss : { *(.bss) }
  _end = .;
}
