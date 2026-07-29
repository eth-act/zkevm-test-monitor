.option norvc
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
  ebreak
  li a0, 0
  li a7, 93
  ecall
