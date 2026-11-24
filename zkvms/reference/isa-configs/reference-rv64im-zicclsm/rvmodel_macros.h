// rvmodel_macros.h for the zkVM reference (eth-act/zkevm-standards reference/, run by
// zkvm-run). The reference performs a static-library function when the PC reaches its
// symbol: write_output appends to the public output, and reaching _start a second time
// halts with exit code a0 (main returning).
// PASS/FAIL: write the verdict "PASS" = 0x53534150 or "FAIL" = 0x4c494146
// (little-endian ASCII) to the public output, as every zkVM does on the ere path, then
// halt with exit code 0 or 1. The marker is staged in `fromhost`.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_REF_HALT(_MARKER, _EXIT) \
  li t1, _MARKER; la a0, fromhost; sw t1, 0(a0); li a1, 4; call write_output; \
  li a0, _EXIT; la t0, _start; jr t0;

#define RVMODEL_HALT_PASS RVMODEL_REF_HALT(0x53534150, 0)
#define RVMODEL_HALT_FAIL RVMODEL_REF_HALT(0x4c494146, 1)

// The reference has no console; the failure diagnostics are not printed.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

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
