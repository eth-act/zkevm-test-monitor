#ifndef _RISCV_MODEL_TEST_H
#define _RISCV_MODEL_TEST_H

#define __riscv_xlen 32
#define TESTNUM x31

// Define this to disable the identity mapping MMU code
#define RVTEST_NO_IDENTY_MAP

#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_BOOT

// Our custom halting logic for Airbender - infinite loop instead of ecall
// Airbender treats ecall as IllegalInstruction, so we just loop forever
#define RVMODEL_HALT                                              \
  self: j self      /* Infinite loop - Airbender will run for --cycles limit */


#define RVTEST_RV32U                                                                               \
  .macro init;                                                                                     \
  .endm

#define RVTEST_FAIL                                                                                \
  fence;                                                                                           \
  fail_loop: j fail_loop  /* Infinite loop on failure */
#define RVTEST_PASS                                                                                \
  pass_loop: j pass_loop  /* Infinite loop on pass - Airbender will hit cycle limit */

// #define RVTEST_CODE_BEGIN                                                                          \
//   .text;                                                                                           \
//   .globl _start;                                                                                   \
//   _start:                                                                                          \
//   .option push;                                                                                    \
//   .option norelax;                                                                                 \
//   la gp, __global_pointer$;                                                                        \
//   .option pop;

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_DATA_BEGIN                                              \
  RVMODEL_DATA_SECTION                                                        \
  .align 4;\
  .global begin_signature; begin_signature:


#define RVMODEL_DATA_END                                                      \
  .align 4;\
  .global end_signature; end_signature:

#endif // _RISCV_MODEL_TEST_H
