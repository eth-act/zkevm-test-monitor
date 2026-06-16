OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)
PHDRS {
    text PT_LOAD FLAGS(5);   /* R+X */
    data PT_LOAD FLAGS(6);   /* R+W */
}
SECTIONS
{
  . = 0x01000000;
  .text : SUBALIGN(4) { *(.text.init) *(.text) *(.text.*) } :text
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } :data
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) *(.data.string) } :data
  . = ALIGN(0x1000);
  .bss (NOLOAD) : { *(.bss) } :data
  _end = .;
}
