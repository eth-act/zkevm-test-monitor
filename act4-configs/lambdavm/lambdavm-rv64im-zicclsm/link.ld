OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/* SUBALIGN(4): override 4096-byte input section alignments from the 4.0.0 tests.
   Without this, the linker inserts a ~4KB zero-filled gap between .text.init and
   .text.rvtest; LambdaVM scans all bytes in the executable PT_LOAD segment at
   load time and panics on 0x00000000 (UnknownOpcode) in the gap. */
SECTIONS
{
  . = 0x80000000;
  .text : SUBALIGN(4) { *(.text.init) *(.text) *(.text.*) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) *(.data.string) }
  . = ALIGN(0x1000);
  .bss : { *(.bss) }
  _end = .;
}
