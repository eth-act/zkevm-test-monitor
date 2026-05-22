// rvmodel_macros.h for LambdaVM (RV64IM STARK ZK-VM)
//
// LambdaVM has no HTIF tohost/fromhost and no PC-stall ("j .") termination —
// the executor only stops when the PC reaches 0, which the Halt ecall produces.
// A passing test halts cleanly via the Halt syscall (a7=93, exit 0); a failing
// self-check routes to RVMODEL_HALT_FAIL, which issues the Panic syscall
// (a7=2) so the executor aborts and the process exits non-zero.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

// LambdaVM does not read this section, but ACT4 env code references the
// `tohost`/`fromhost` symbols, so they must still be defined.
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost; tohost: .dword 0;         \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_BOOT

// Halt syscall — clean termination, process exit 0.
#define RVMODEL_HALT_PASS  \
  li a0, 0                ;\
  li a7, 93               ;\
  ecall                   ;\

// Panic syscall — aborts execution, process exit non-zero.
#define RVMODEL_HALT_FAIL  \
  li a0, 0                ;\
  li a7, 2                ;\
  ecall                   ;\

#define RVMODEL_IO_INIT(_R1, _R2, _R3)

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

#define RVMODEL_MTIME_ADDRESS    0x02004000

#define RVMODEL_MTIMECMP_ADDRESS 0x02000000

#define RVMODEL_SET_MEXT_INT

#define RVMODEL_CLR_MEXT_INT

#define RVMODEL_SET_MSW_INT

#define RVMODEL_CLR_MSW_INT

#define RVMODEL_SET_SEXT_INT

#define RVMODEL_CLR_SEXT_INT

#define RVMODEL_SET_SSW_INT

#define RVMODEL_CLR_SSW_INT

#endif // _COMPLIANCE_MODEL_H
