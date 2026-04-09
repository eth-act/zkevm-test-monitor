// rvmodel_macros.h for Zisk (RV64IM ZK-VM)
// Adapted from RISCOF model_test.h — same halt convention (ecall a7=93),
// same DATA_SECTION layout, same MSW_INT addresses.
// The RISCOF marchid/QEMU detection is omitted because ACT4 compiles
// with -march=rv64i (no zicsr) and only runs on Zisk.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_BOOT

#define RVMODEL_HALT_PASS  \
  li a0, 0;                \
  li a7, 93;               \
  ecall;                   \
  j .;

#define RVMODEL_HALT_FAIL \
  li a0, 1;                \
  li a7, 93;               \
  ecall;                   \
  j .;

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

// Zisk has a memory-mapped UART at 0xa0000200: a single sb writes one byte to host stdout.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
  li _R2, 0xa0000200;                                   \
  98: lbu _R1, 0(_STR_PTR);                             \
  beqz _R1, 99f;                                        \
  sb _R1, 0(_R2);                                       \
  addi _STR_PTR, _STR_PTR, 1;                           \
  j 98b;                                                \
  99:

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

#define RVMODEL_MTIME_ADDRESS    0x02004000

#define RVMODEL_MTIMECMP_ADDRESS 0x02000000

#define RVMODEL_SET_MEXT_INT

#define RVMODEL_CLR_MEXT_INT

#define RVMODEL_SET_MSW_INT \
 li t1, 1;                         \
 li t2, 0x2000000;                 \
 sw t1, 0(t2);

#define RVMODEL_CLR_MSW_INT \
 li t2, 0x2000000;                 \
 sw x0, 0(t2);

#define RVMODEL_CLR_MTIMER_INT

#define RVMODEL_SET_SEXT_INT

#define RVMODEL_CLR_SEXT_INT

#define RVMODEL_SET_SSW_INT

#define RVMODEL_CLR_SSW_INT

#endif // _COMPLIANCE_MODEL_H
