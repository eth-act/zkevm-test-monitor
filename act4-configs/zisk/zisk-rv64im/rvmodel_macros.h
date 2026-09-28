// rvmodel_macros.h for ZisK (RV64 ZK-VM)
// Halt: ecall a7=93. ZisK has no M-mode trap CSRs, so STANDARD_SM_SUPPORTED stays
// undefined and the ACT4 boot code emits no trap setup. With F_SUPPORTED (native
// config), ACT4 still sets mstatus.FS and clears fcsr at boot.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

// ZisK ignores a0 at the exit ecall (its exit handler tests only a7 == 93), so
// the verdict is also stored to public output 0 at OUTPUT_ADDR (ZisK >= 1.2):
// "PASS" = 0x53534150, "FAIL" = 0x4c494146 (little-endian ASCII). ere returns
// public outputs from execute, prove and verify, so the verdict is proof-committed.
#define RVMODEL_ZISK_OUTPUT_ADDR 0xa0410000

#define RVMODEL_HALT_PASS  \
  li t0, RVMODEL_ZISK_OUTPUT_ADDR; \
  li t1, 0x53534150;       \
  sw t1, 0(t0);            \
  li a0, 0;                \
  li a7, 93;               \
  ecall;                   \
  j .;

#define RVMODEL_HALT_FAIL \
  li t0, RVMODEL_ZISK_OUTPUT_ADDR; \
  li t1, 0x4c494146;       \
  sw t1, 0(t0);            \
  li a0, 1;                \
  li a7, 93;               \
  ecall;                   \
  j .;

// Zisk has a memory-mapped UART at 0xa0400200: a single sb writes one byte to host stdout.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
  li _R2, 0xa0400200;                                   \
  98: lbu _R1, 0(_STR_PTR);                             \
  beqz _R1, 99f;                                        \
  sb _R1, 0(_R2);                                       \
  addi _STR_PTR, _STR_PTR, 1;                           \
  j 98b;                                                \
  99:

// No interrupts: these are required by check_defines.h but never expanded
// without STANDARD_SM_SUPPORTED.
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 100
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif // _RVMODEL_MACROS_H
