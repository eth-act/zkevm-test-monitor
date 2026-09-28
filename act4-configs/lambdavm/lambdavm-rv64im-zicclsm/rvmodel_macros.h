// rvmodel_macros.h for LambdaVM (RV64IM STARK ZK-VM)
//
// LambdaVM has no HTIF tohost/fromhost and no PC-stall ("j .") termination —
// the executor only stops when the PC reaches 0, which the Halt ecall produces.
// A passing test halts cleanly via the Halt syscall (a7=93, exit 0); a failing
// self-check routes to RVMODEL_HALT_FAIL, which issues the Panic syscall
// (a7=2) so the executor aborts and the process exits non-zero.
// LambdaVM has no M-mode CSRs, so STANDARD_SM_SUPPORTED stays undefined and the
// ACT4 boot code emits no CSR instructions.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

// LambdaVM does not read this section, but ACT4 env code references the
// `tohost`/`fromhost` symbols, so they must still be defined.
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

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

// LambdaVM has no console; the failure diagnostics are not printed.
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
