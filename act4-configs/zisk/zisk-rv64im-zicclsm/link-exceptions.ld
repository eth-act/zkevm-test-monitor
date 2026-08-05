OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init    : { *(.text.init) }
  .text.rvtest  : { *(.text.rvtest) *(.text.rvtest.*) }
  .text.rvmodel : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }
  . = 0xa0010000;
  .tohost       : { *(.tohost) }
  .data         : { *(.data) }
  .data.string  : { *(.data.string) }
  .bss          : { *(.bss) }
  _end = .;
}
