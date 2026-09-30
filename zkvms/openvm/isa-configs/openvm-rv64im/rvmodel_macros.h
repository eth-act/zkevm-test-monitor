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

// The verdict is also revealed as public output 0, as for every zkVM on the ere
// path: "PASS" = 0x53534150 or "FAIL" = 0x4c494146 (little-endian ASCII).
// REVEAL is opcode 0x0b, funct3 2: rd = byte index, rs1 = the 8-byte value.
// Then TERMINATE (funct3 0) with the exit code as imm.
#define RVMODEL_OPENVM_HALT(_MARKER, _EXIT) \
  li t0, 0                   ;\
  li t1, _MARKER             ;\
  .insn i 0x0b, 2, t0, t1, 0 ;\
  .insn i 0x0b, 0, x0, x0, _EXIT ;\
  j .                        ;\

#define RVMODEL_HALT_PASS RVMODEL_OPENVM_HALT(0x53534150, 0)

#define RVMODEL_HALT_FAIL RVMODEL_OPENVM_HALT(0x4c494146, 1)

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
