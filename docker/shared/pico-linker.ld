OUTPUT_ARCH(riscv)
ENTRY(rvtest_entry_point)
SECTIONS {
  . = 0x00200800;
  .text.init : { *(.text.init) }
  . = 0x00201000;
  .tohost : { *(.tohost) }
  .data : { *(.data) *(.bss) }
}
