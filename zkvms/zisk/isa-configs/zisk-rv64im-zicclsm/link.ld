/* ZisK memory map (core/src/mem.rs, ziskbuild/zisk_linker_script.ld): program code in
   ROM [ROM_ADDR 0x80000000, +128 MiB), which ZisK maps execute-only; RAM
   [RAM_ADDR 0xa0000000, +512 MiB) holds the stack (first 4 MiB), the system area
   (0xa0400000; UART at 0xa0400200), the public output (OUTPUT_ADDR 0xa0410000, where
   rvmodel_macros.h stores the PASS/FAIL marker), and program data from 0xa0430000.
   sail.json's ROM and RAM regions cover the same ranges. */
ROM_ORIGIN = 0x80000000;
ROM_LENGTH = 0x08000000;
RAM_ORIGIN = 0xa0000000;
RAM_LENGTH = 0x20000000;
DATA_BASE  = 0xa0430000;   /* first general-purpose RAM address */
TEST_BASE  = ROM_ORIGIN;
NUM_HARTS  = 1;

STACK_SIZE = 0x20000;

OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{
  rom (rx)  : ORIGIN = ROM_ORIGIN, LENGTH = ROM_LENGTH
  ram (rw)  : ORIGIN = RAM_ORIGIN, LENGTH = RAM_LENGTH
}

/* Deviation from the upstream ACT4 layout, which places .text.rvmodel after the data
   and stack: ZisK code must stay in ROM and data in RAM, so .text.rvmodel follows
   .text.rvtest in ROM. The data addresses do not depend on the size of
   .text.rvmodel (which differs between the DUT and Sail builds), because the data
   starts at the fixed DATA_BASE in RAM. */
PHDRS
{
  text PT_LOAD FLAGS(5);   /* R+X */
  data PT_LOAD FLAGS(6);   /* R+W */
}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{
  /* One output section, so alignment padding between the input sections is filled
     with NOPs instead of zeros. */
  .text TEST_BASE : {
    *(.text.init)
    *(.text.rvtest) *(.text.rvtest.*)
    *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*)
  } > rom :text =0x13000000   /* nop */

  .rodata DATA_BASE : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > ram :data
  .data   . : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) } > ram :data
  .tohost . : { *(.tohost) } > ram :data

  . = ALIGN(16);
  .bss . (NOLOAD) : {
    __bss_start = .;
    *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON)
    . = ALIGN(16);
    __bss_end = .;
  } > ram :data

  . = ALIGN(16);
  __stack_bottom = .;
  . += __stack_size * __num_harts;
  __stack_top = .;

  . = ALIGN(0x1000);
  _end = .;

  ASSERT(_end <= ORIGIN(ram) + LENGTH(ram), "ACT ELF exceeds RAM; increase RAM_LENGTH in link.ld and the matching memory.regions size in sail.json")
}
