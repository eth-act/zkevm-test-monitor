/* Linker script for the eth-act standards test guests on OpenVM, built as ACT4
   C tests. OpenVM publishes no linker script for C guests, so this one is ours.
   build-guests.sh links the vendor library (libere_openvm_c.a: eth-act/ere's
   ere-platform-openvm plus the read_input/write_output wrapper). Derived from
   the ISA config zkvms/openvm/isa-configs/openvm-rv64im-zicclsm/link.ld, with
   these changes:
   - ENTRY(_start) is the openvm crate's _start, which initializes the runtime
     and calls main. ACT's own C start code (rvtest_entry_point) is linked but
     not run.
   - No Sail signature is built, so the data need not start at an address that
     is independent of the size of .text.rvmodel. */
/* OpenVM memory map (crates/toolchain/platform/src/memory.rs): guest memory is
   [GUEST_MIN_MEM 0x400, 2^29); the stack grows down from STACK_TOP 0x200400; programs
   are linked at TEXT_START 0x200800. The test image starts at TEXT_START and must end
   below 2^29. sail.json's RAM region covers the same range (page-aligned). */
RAM_ORIGIN = 0x00200800;
RAM_LENGTH = 0x1FDFF800;
TEST_BASE = RAM_ORIGIN;
NUM_HARTS = 1;

STACK_SIZE = 0x20000;

OUTPUT_ARCH( "riscv" )
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = RAM_ORIGIN, LENGTH = RAM_LENGTH
}

/* OpenVM's ELF loader rejects a segment that is both writable and executable, and it
   requires all executable code to be one contiguous segment. */
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

  .text TEST_BASE : {
    *(.text.init)
    *(.text.rvtest) *(.text.rvtest.*)
    *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*)
  } > ram :text

  . = ALIGN(0x1000);
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
  /* OpenVM's _start (openvm crate) sets gp from __global_pointer$. */
  PROVIDE(__global_pointer$ = _end);

  ASSERT(_end <= ORIGIN(ram) + LENGTH(ram), "ACT ELF exceeds RAM; increase RAM_LENGTH in link.ld and the matching memory.regions size in sail.json")
}
