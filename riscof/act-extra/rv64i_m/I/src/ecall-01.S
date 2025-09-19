// -----------
// Copyright (c) 2020. RISC-V International. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause
// -----------
//
// This assembly file tests the ecall instruction of the RISC-V I extension.
// 

#include "model_test.h"
#include "arch_test.h"

RVTEST_ISA("RV64I")

# Test code region
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
RVMODEL_BOOT
RVTEST_CODE_BEGIN

#ifdef TEST_CASE_1
    RVTEST_CASE(1,"//check ISA:=regex(.*64.*); check ISA:=regex(.*I.*); def extra_trap_routine=True; def TEST_CASE_1=True",ecall)

    # ---------------------------------------------------------------------------------------------
    # Test ecall by setting values before and after
    # If ecall returns correctly, x3 will be set to the "after" value

    LI(     x3,0x11111111)  # Value before ecall

    # Set a7 to a value other than 93 (CAUSE_EXIT) for Zisk compatibility
    # This ensures the ecall returns to the next instruction instead of terminating
    li      a7, 1           # Use syscall number 1 (not 93/CAUSE_EXIT)

    ecall
    nop

    # If we reach here, ecall returned successfully
    LI(     x3,0x22222222)  # Value after ecall - proves we continued execution

    # Store results in signature
    LA(     x1,test_A_res)
    sw      x3, 0(x1)       # Will be 0x22222222 if ecall returned correctly
    sw      x0, 4(x1)       # Store zero as second value
    
    RVMODEL_IO_WRITE_STR(x30, "# Test part A - test ECALL\n");

    RVMODEL_IO_WRITE_STR(x30, "# Test End\n")

#endif

 # ---------------------------------------------------------------------------------------------
    # HALT

RVTEST_CODE_END
RVMODEL_HALT

RVTEST_DATA_BEGIN
# Input data section.
    .data
    .align 4
RVTEST_DATA_END

# Output data section.
RVMODEL_DATA_BEGIN
rvtest_sig_begin:
sig_begin_canary:
CANARY;
test_A_res:
    .fill 2, 4, 0xdeadbeef

#ifdef rvtest_mtrap_routine
mtrap_sigptr:
  .fill 8, 4, 0xdeadbeef
#endif

#ifdef rvtest_gpr_save
gpr_save:
  .fill 32*(XLEN/32), 4, 0xdeadbeef
#endif

sig_end_canary:
CANARY;
rvtest_sig_end:
RVMODEL_DATA_END
