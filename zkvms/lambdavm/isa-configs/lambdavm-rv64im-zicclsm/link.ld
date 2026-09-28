/* LambdaVM memory map: the program and its heap live below MAX_MEMORY_SIZE 0xC0000000
   (syscalls/src/allocator.rs); private input starts at 0xFF000000
   (executor/src/vm/memory.rs) and the stack grows down from 0xFFFFFFFFFFFFFFF0
   (executor/src/vm/registers.rs). sail.json's RAM region covers the same range. */
RAM_ORIGIN = 0x80000000;
RAM_LENGTH = 0x40000000;
TEST_BASE = RAM_ORIGIN;
NUM_HARTS = 1;

STACK_SIZE = 0x20000;

/* Space reserved for .text.rvmodel. Its size differs between the DUT build and the
   Sail reference build, so .rodata/.data start at an address that depends only on
   where .text.rvmodel starts, never on its size. */
RVMODEL_SPACE = 0x1000;

OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

MEMORY
{
  ram (rwx) : ORIGIN = RAM_ORIGIN, LENGTH = RAM_LENGTH
}

/* LambdaVM decodes every word of every executable segment at load time, so code and
   data go into separate R+X and R+W segments, and the R+X segment has no gaps. */
/* Deviation from the upstream ACT4 layout, which places .text.rvmodel in a second
   executable segment after the data and stack: here .text.rvmodel follows
   .text.rvtest in the one R+X segment, and RVMODEL_SPACE keeps the data addresses
   identical in the DUT and Sail builds. */
PHDRS
{
  text PT_LOAD FLAGS(5);   /* R+X */
  data PT_LOAD FLAGS(6);   /* R+W */
}

PROVIDE(__stack_size = STACK_SIZE);
PROVIDE(__num_harts = NUM_HARTS);

SECTIONS
{
  ASSERT(TEST_BASE >= ORIGIN(ram) && TEST_BASE < ORIGIN(ram) + LENGTH(ram), "TEST_BASE is outside RAM; update TEST_BASE and RAM_ORIGIN/RAM_LENGTH in link.ld, and the matching memory.regions entry in sail.json")

  /* One output section, so alignment padding between the input sections is filled
     with NOPs (0x00000013) instead of zeros, which the zkVM would decode as an
     illegal instruction. */
  .text TEST_BASE : {
    *(.text.init)
    *(.text.rvtest) *(.text.rvtest.*)
    __rvmodel_start = .;
    *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*)
    __rvmodel_end = .;
  } > ram :text =0x13000000

  ASSERT(__rvmodel_end - __rvmodel_start <= RVMODEL_SPACE, "RVMODEL code exceeds RVMODEL_SPACE; increase RVMODEL_SPACE in link.ld")
  . = ALIGN(__rvmodel_start + RVMODEL_SPACE, 0x4000);
  .rodata . : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > ram :data
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
