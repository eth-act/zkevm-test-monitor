/* Linker script for the eth-act standards test guests on OpenVM, built as ACT4
   C tests.

   OpenVM publishes no linker script. Its guest build links with the linker's
   default layout and -Ttext=0x00200800 (TEXT_START, crates/toolchain/build/src/lib.rs
   and crates/toolchain/platform/src/memory.rs). build-guests.sh does the same
   (link-args), so this script does not replace GNU ld's default script: INSERT
   adds to it. It only defines the symbols that ACT's C start code references.
   That code is linked but not run: the entry point stays OpenVM's _start. */
SECTIONS
{
  PROVIDE(__bss_end = _end);
  PROVIDE(__stack_size = 0x20000);
  PROVIDE(__stack_top = 0x200400); /* STACK_TOP in memory.rs */
  PROVIDE(__num_harts = 1);
}
INSERT AFTER .bss;
