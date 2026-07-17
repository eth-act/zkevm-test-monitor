.option norvc
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
  li a0, 0xd0000000
  lw a1, 0(a0)
