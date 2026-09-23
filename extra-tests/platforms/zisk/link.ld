OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH("riscv")
ENTRY(_start)
MEMORY {
  rom (xa)  : ORIGIN = 0x80000000, LENGTH = 0x08000000
  ram (wxa) : ORIGIN = 0xa0030000, LENGTH = 0x1ffc0000
}
SECTIONS {
  .text : { *(.text.init) *(.text .text.*) } >rom
  . = ALIGN(8);
  PROVIDE(_global_pointer = .);
  .rodata : { *(.srodata .srodata.* .rodata .rodata.*) } >rom
  .init_array : { PROVIDE(__init_array_start = .); KEEP(*(.init_array*)) PROVIDE(__init_array_end = .); } >rom
  .fini_array : { PROVIDE(__fini_array_start = .); KEEP(*(.fini_array*)) PROVIDE(__fini_array_end = .); } >rom
  .stack (NOLOAD) : { PROVIDE(_init_stack_bottom = .); . = . + 0x400000; PROVIDE(_init_stack_top = .); } >ram
  .data : { *(.data .data.* .sdata .sdata.*) } >ram
  .bss : { PROVIDE(_bss_start = .); *(.bss .bss.* .sbss .sbss.* COMMON) PROVIDE(_bss_end = .); } >ram
  . = ALIGN(8);
  PROVIDE(_heap_bottom = .);
  PROVIDE(_heap_top = 0xbfff0000);
  PROVIDE(_kernel_heap_bottom = _heap_bottom);
  PROVIDE(_kernel_heap_top = _heap_top);
  PROVIDE(_kernel_heap_size = _heap_top - _heap_bottom);
  PROVIDE(_end = .);
}
