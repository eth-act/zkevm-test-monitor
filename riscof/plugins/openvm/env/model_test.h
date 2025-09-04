// Copyright 2024 RISC Zero, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef _RISCV_MODEL_TEST_H
#define _RISCV_MODEL_TEST_H

#define __riscv_xlen 32
#define TESTNUM x31

// Define this to disable the identity mapping MMU code
#define RVTEST_NO_IDENTY_MAP

#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_BOOT

#define RVTEST_RV32U                                                    \
  .macro terminate ec;                                                  \
      .insn i 0x0b, 0, x0, x0, \ec;                                     \
  .endm


// Our custom halting logic
#define RVMODEL_HALT                                              \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 0;                                                       \
        .insn i 0x0b, 0, x0, x0, 0;                                     \
        /* Fill with nops to end of text section cleanly */            \
        .rept 32;                                                       \
        nop;                                                            \
        .endr

//-----------------------------------------------------------------------
// Pass/Fail Macro
//-----------------------------------------------------------------------

#define RVTEST_PASS                                                     \
        fence;                                                          \
        li TESTNUM, 1;                                                  \
        li a7, 93;                                                      \
        li a0, 0;                                                       \
        .insn i 0x0b, 0, x0, x0, 0;                                     \
        /* Fill with nops to end of text section cleanly */            \
        .rept 32;                                                       \
        nop;                                                            \
        .endr

#define RVTEST_FAIL                                                     \
        fence;                                                          \
1:      beqz TESTNUM, 1b;                                               \
        sll TESTNUM, TESTNUM, 1;                                        \
        or TESTNUM, TESTNUM, 1;                                         \
        li a7, 93;                                                      \
        addi a0, TESTNUM, 0;                                            \
        .insn i 0x0b, 0, x0, x0, 1;                                     \
        /* Fill with nops to end of text section cleanly */            \
        .rept 32;                                                       \
        nop;                                                            \
        .endr

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .align 8; .global begin_regstate; begin_regstate: .word 128;    \
        .align 8; .global end_regstate; end_regstate: .word 4;          \
        .popsection;

#define RVMODEL_DATA_BEGIN                                              \
  /* End text section cleanly before starting data */                   \
  .section .text;                                                       \
  .balign 4;                                                           \
  RVMODEL_DATA_SECTION                                                  \
  .section .data;                                                       \
  .balign 4;                                                           \
  .global begin_signature; begin_signature:


#define RVMODEL_DATA_END                                                      \
  .align 4;                                                           \
  .global end_signature; end_signature:

// // Signature writing macros
// // We define these macros to override the standard ones
// // The warnings about redefinition are harmless - our definitions will be used
// #define RVTEST_SIGBASE(BASE_REG, SIG_ADDR) \
//   la BASE_REG, begin_signature
//
// #define RVTEST_SIGUPD(BASE_REG, SIG_OFFSET, REG) \
//   sw REG, SIG_OFFSET(BASE_REG)
//
// #define RVTEST_SIGUPD_F(BASE_REG, SIG_OFFSET, FPREG) \
//   fsw FPREG, SIG_OFFSET(BASE_REG)
//
// #define RVTEST_BASEUPD(BASE_REG, NEW_ADDR) \
//   la BASE_REG, NEW_ADDR

#endif // _RISCV_MODEL_TEST_H
