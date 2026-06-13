OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/* Separate R+X and R+W segments so OpenVM's ELF loader does not reject the ELF.
   OpenVM pre-processes all words as instructions, so zero-filled gaps in the
   R+X segment (from 4096-byte input section alignment in 4.0.0 tests) would
   cause it to interpret 0x00000000 (illegal insn) as code. SUBALIGN(4) overrides
   the per-section alignment, collapsing the gaps. */
PHDRS {
    text PT_LOAD FLAGS(5);   /* R+X */
    data PT_LOAD FLAGS(6);   /* R+W */
}

SECTIONS
{
  . = 0x00000000;
  /* SUBALIGN(4): override 4096-byte input section alignments from the 4.0.0 tests. */
  .text : SUBALIGN(4) { *(.text.init) *(.text) *(.text.*) } :text
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } :data
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) *(.data.string) } :data
  . = ALIGN(0x1000);
  .bss (NOLOAD) : { *(.bss) } :data
  _end = .;
}
