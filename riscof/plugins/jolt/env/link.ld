OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;  /* Standard RISC-V base address */
  .text.init : { *(.text.init) }
  .text : { *(.text) }
  
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }  /* Special section for test markers */
  
  . = ALIGN(0x1000);
  .data : { *(.data) }
  
  .bss : { *(.bss) }
  _end = .;
}