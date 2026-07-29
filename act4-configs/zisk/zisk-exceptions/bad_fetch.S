.option norvc
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
  li t0, 0x80000002
  # Leave a gap in Zisk's non-aligned ROM lookup table. The target is in-bounds
  # but has no instruction, so the emulator reports instruction access fault.
  .2byte 0x0001
  .2byte 0x0001
  jalr x0, 0(t0)
