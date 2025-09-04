#ifndef _RISCV_MODEL_TEST_H
#define _RISCV_MODEL_TEST_H

#define __riscv_xlen 32
#define TESTNUM x31

#define RVTEST_NO_IDENTY_MAP

#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_BOOT

#define RVMODEL_HALT                      \
  li t0, 0;                               \
  li a7, 0;                               \
  ecall;

#define RVMODEL_DATA_BEGIN \
  .align 4;                \
  .global begin_signature; \
  begin_signature:

#define RVMODEL_DATA_END \
  .align 4;              \
  .global end_signature; \
  end_signature:

#endif