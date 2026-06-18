OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

/* SUBALIGN(4): override 4096-byte input section alignments from the 4.0.0 tests.
   Without this, the linker inserts a ~4KB zero-filled gap between .text.init and
   .text.rvtest; while Zisk uses section-based ROM loading (so the gap isn't in the
   ROM), AUIPC instructions then run at PC 0x80001xxx and the Zisk prover fails
   VerifyGlobalConstraints — indicating a circuit bug with AUIPC at higher PCs. */
SECTIONS
{
  . = 0x80000000;
  .text : SUBALIGN(4) { *(.text.init) *(.text) *(.text.*) }
  .rodata : { *(.rodata .rodata.*)}
  . = 0xa0010000;
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .data.string : { *(.data.string)}
  .bss : { *(.bss) }
  _end = .;
}

