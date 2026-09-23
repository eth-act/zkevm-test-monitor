/* ZisK v1.3.0-alpha ziskbuild/zisk_linker_script.ld (eth-act/ere vendors the
   same file), with two changes for the C guests:
   - .srodata goes in .rodata.
   - .data and .bss share one PT_LOAD. A guest without initialized data has
     an empty .data, and GNU ld then emits an empty PT_LOAD at address 0,
     which ziskemu rejects as outside the ZisK address space.

   RAM layout: stack 0xa0000000..0xa0400000, the emulator's register area
   (UART at 0xa0400200), the public output at 0xa0410000 and .data/.bss from
   0xa0430000. The heap ends below the float RAM at 0xbfff0000. */
OUTPUT_FORMAT("elf64-littleriscv")
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
  rom   (xa) : ORIGIN = 0x80000000, LENGTH = 0x08000000
  ram   (wxa) : ORIGIN = 0xa0000000, LENGTH = 0x20000000
}

PHDRS {
  text PT_LOAD FLAGS(1);
  rodata PT_LOAD FLAGS(4);
  data PT_LOAD FLAGS(6);
  output_data PT_LOAD FLAGS(6);
  general_registers_data PT_LOAD FLAGS(6);
  float_registers_data PT_LOAD FLAGS(6);
  stack_data PT_LOAD FLAGS(6);
}

_stack_size                  = 0x400000;  /* 4 MB reserved */
_general_registers_data_size = 0x8000;    /* 32 kB */
_float_registers_data_size   = 0x8000;    /* 32 kB */
_output_data_size            = 0x20000;   /* 128 KB reserved */
_float_ram_data_size         = 0x10000;   /* 64 KB reserved */

SECTIONS
{
  .text : { *(.text.init) *(.text .text.*)} >rom AT>rom :text

  . = ALIGN(8);
  PROVIDE(_global_pointer = .);
  .rodata : { *(.srodata .srodata.* .rodata .rodata.*)} >rom AT>rom :rodata

  /* C++ static constructors / destructors, run by _start around main. */
  . = ALIGN(8);
  .init_array : {
    PROVIDE(__init_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
    KEEP(*(.init_array))
    PROVIDE(__init_array_end = .);
  } >rom AT>rom :rodata

  .fini_array : {
    PROVIDE(__fini_array_start = .);
    KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*)))
    KEEP(*(.fini_array))
    PROVIDE(__fini_array_end = .);
  } >rom AT>rom :rodata

  . = ORIGIN(ram);

  .stack_data (NOLOAD): {
    PROVIDE(_stack_start = .);
    PROVIDE(_init_stack_bottom = .);
    . = . + _stack_size;
    PROVIDE(_init_stack_top = .);
  } >ram AT>ram :stack_data

  .general_registers_data (NOLOAD) : {
    PROVIDE(_general_registers_data_start = .);
    . = . + _general_registers_data_size;
    PROVIDE(_general_registers_data_end = .);
  } >ram AT>ram :general_registers_data

  .float_registers_data (NOLOAD) : {
    PROVIDE(_float_registers_data_start = .);
    . = . + _float_registers_data_size;
    PROVIDE(_float_registers_data_end = .);
  } >ram AT>ram :float_registers_data

  .output_data (NOLOAD) : {
    PROVIDE(_output_data_start = .);
    . = . + _output_data_size;
    PROVIDE(_output_data_end = .);
  } >ram AT>ram :output_data

  .data : { *(.data .data.* .sdata .sdata.*) } >ram AT>ram :data

  .bss : {
    PROVIDE(_bss_start = .);
    *(.bss .bss.* .sbss .sbss.*);
    PROVIDE(_bss_end = .);
  } >ram AT>ram :data

  PROVIDE(_heap_bottom = .);
  PROVIDE(_heap_top = ORIGIN(ram) + LENGTH(ram) - _float_ram_data_size);
  PROVIDE(_heap_size = _heap_top - _heap_bottom);

  _end = .;
}
