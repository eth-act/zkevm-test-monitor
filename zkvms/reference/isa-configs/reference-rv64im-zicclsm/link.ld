/* The zkVM reference's memory map (eth-act/zkevm-standards
   reference/memory-profiles/reference-rx.json, reference/tests/stublib/link.ld.in
   filled for it): RAM 0x80000000..0x88000000, code read+execute, read-only data and
   data/bss in their own page-aligned segments. ACT's sections are placed explicitly:
   its code (.text.init, .text.rvtest, .text.rvmodel) in the text segment, .tohost
   with the data. sail.json has the same regions (RAM, the read-only input region at
   0x40000000 and the stack at 0x88001000). The entry point is the library's _start,
   which calls main; an ISA test has no main, so main is ACT's entry point. This is the
   ISA tests' script; the standards guests link zkvms/reference/standards/link.ld, the
   same layout without the library symbols (the stub library defines them). */
OUTPUT_ARCH(riscv)
ENTRY(_start)
PHDRS { text PT_LOAD FLAGS(5); rodata PT_LOAD FLAGS(4); data PT_LOAD FLAGS(6); }
SECTIONS {
  . = 0x80000000;
  .text : {
    *(.text.init)
    *(.text.rvtest) *(.text.rvtest.*)
    *(.text.rvmodel) *(.text.rvmodel.*)
    *(.text .text.*)
    /* An ISA test links no library, so the library symbols the reference binds get
       one word each here (ebreak, never executed: the reference performs the library
       function when the PC reaches its symbol). */
    . = ALIGN(4);
    _start = .; LONG(0x00100073)
    read_input = .; LONG(0x00100073)
    write_output = .; LONG(0x00100073)
  } :text =0x13000000
  . = ALIGN(4096);
  .rodata : { *(.rodata .rodata.* .srodata .srodata.* .eh_frame .eh_frame_hdr .gcc_except_table) } :rodata
  . = ALIGN(4096);
  .data : { *(.data .data.*) __global_pointer$ = . + 0x800; *(.sdata .sdata.*) *(.tohost) } :data
  .bss : { *(.sbss .sbss.* .bss .bss.* COMMON) } :data
  . = ALIGN(4096);
  _heap_start = .; _heap_end = 0x88000000;
  _stack_bottom = 0x88001000; _stack_top = 0x88101000;
  /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.note*) }
}
PROVIDE(main = rvtest_entry_point);
