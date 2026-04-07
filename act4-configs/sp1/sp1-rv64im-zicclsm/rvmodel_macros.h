// rvmodel_macros.h for SP1 (RV64IM_Zicclsm ZK-VM target)
// SP1 reads syscall number from t0 (x5): 0 = HALT
// PASS: t0=0 (HALT), a0=0 (success exit code)
// FAIL: t0=0 (HALT), a0=1 (non-zero exit code)
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
  li t0, 0                ;\
  li a0, 0                ;\
  li a1, 0x400            ;\
  ecall                   ;\
  j .                     ;\

#define RVMODEL_HALT_FAIL \
  li t0, 0                ;\
  li a0, 1                ;\
  li a1, 0x400            ;\
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
