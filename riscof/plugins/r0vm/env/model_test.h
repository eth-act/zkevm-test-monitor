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

// Our custom halting logic
#define RVMODEL_HALT                                              \
  li t0, 0;         /* Status code for pass, can be changed */      \
  li a7, 0;         /* HOST_ECALL_TERMINATE */                      \
  li a0, 0;         /* Corresponds to a0 in on_terminate */         \
  li a1, 0x400;     /* Corresponds to a1 in on_terminate */         \
  ecall


#define RVTEST_RV32U                                                                               \
  .macro init;                                                                                     \
  .endm

#define RVTEST_FAIL                                                                                \
  fence;                                                                                           \
  unimp
#define RVTEST_PASS                                                                                \
  li t0, 0;                                                                                        \
  li a7, 0;         /* HOST_ECALL_TERMINATE */                                          \
  li a0, 0;                                                                                        \
  li a1, 0x400;                                                                                    \
  ecall

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
