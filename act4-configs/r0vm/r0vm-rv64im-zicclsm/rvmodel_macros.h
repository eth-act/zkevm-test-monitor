// rvmodel_macros.h for r0vm (risc0 ZKVM, kernel-mode, RV64IM_Zicclsm target)
// risc0 kernel-mode ecall convention (HOST_ECALL_TERMINATE):
//   a7 = 0   (HOST_ECALL_TERMINATE; circuit dispatches on a7 in kernel mode)
//   a0 = (halt_type << 16) | user_exit_code
//        halt_type=0 (TERMINATE), user_exit in low 16 bits
// PASS: a7=0, a0=0 (exit_code=0)
// FAIL: a7=0, a0=1 (exit_code=1)
// SPDX-License-Identifier: BSD-3-Clause

#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost; tohost: .dword 0;         \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_BOOT

#define RVMODEL_HALT_PASS  \
  li a7, 0                ;\
  li a0, 0                ;\
  ecall                   ;\
  j .                     ;\

#define RVMODEL_HALT_FAIL \
  li a7, 0                ;\
  li a0, 1                ;\
  ecall                   ;\
  j .                     ;\

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
