// rvmodel_macros.h for OpenVM (RV64IM ZK-VM)
// PASS: custom terminate opcode (.insn i 0x0b, 0, x0, x0, 0)
// FAIL: custom terminate opcode with imm=1 (non-zero → non-zero exit)
// OpenVM has no M-mode CSRs, so STANDARD_SM_SUPPORTED stays undefined and the
// ACT4 boot code emits no CSR instructions.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_HALT_PASS  \
  .insn i 0x0b, 0, x0, x0, 0 ;\
  j .                     ;\

#define RVMODEL_HALT_FAIL \
  .insn i 0x0b, 0, x0, x0, 1 ;\
  j .                     ;\

// OpenVM has no console; the failure diagnostics are not printed.
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
