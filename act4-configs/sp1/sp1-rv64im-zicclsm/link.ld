OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/* Separate R+X and R+W segments so SP1's ELF loader does not reject the ELF.
   SP1 rejects any segment that is both writable and executable, and also panics
   on any unrecognized word (including 0x00000000 = illegal insn) in the text
   segment.  Merging all .text.* sections into one contiguous block eliminates
   the zero-filled alignment gaps that appeared between .text.init and
   .text.rvtest when each was page-aligned separately. */
PHDRS {
    text PT_LOAD FLAGS(5);   /* R+X */
    data PT_LOAD FLAGS(6);   /* R+W */
}

SECTIONS
{
  . = 0x78000000;
  /* SUBALIGN(4): override 4096-byte input section alignments from the 4.0.0 tests.
     Without this, the linker inserts a ~4KB zero-filled gap between .text.init and
     .text.rvtest; SP1 scans ALL bytes in the R+E segment at load time and panics on
     0x00000000 (illegal instruction) at rrs.rs. */
  .text : SUBALIGN(4) { *(.text.init) *(.text) *(.text.*) } :text
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } :data
  . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) } :data
  . = ALIGN(0x1000);
  .bss (NOLOAD) : { *(.bss) } :data
  _end = .;
}
