/* Placeholder linker script for the eth-act standards test guests on OpenVM.

   OpenVM publishes no linker script. Its guest build links with the linker's
   default layout and -Ttext=0x00200800 (TEXT_START, crates/toolchain/build/src/lib.rs
   and crates/toolchain/platform/src/memory.rs). build-guests.sh does the same
   (link-args). ACT requires a linker script and passes it with -T, which would
   replace GNU ld's default script; this one adds nothing and uses INSERT, so
   the default script stays in effect. */
SECTIONS
{
}
INSERT AFTER .bss;
