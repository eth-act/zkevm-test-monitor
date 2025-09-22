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

    # Store "before" values in signature
    LA(     x31,test_A_res)  # Use x31 instead of x1 (x1/ra might be modified by ecall)
    LI(     x3,0x11111111)   # Value before ecall
    sw      x3, 0(x31)       # Store 0x11111111 (before value)
    sw      x0, 4(x31)       # Store zero as second value
    addi    x31, x31, 8      # Advance pointer by 8 bytes
    
    # Set a7 to a value other than 93 (CAUSE_EXIT) for Zisk compatibility
    # This ensures the ecall returns to the next instruction instead of terminating
    li      a7, 1           # Use syscall number 1 (not 93/CAUSE_EXIT)

    ecall
    nop

    # If we reach here, ecall returned successfully
    LI(     x3,0xffffffff)  # Value after ecall - proves we continued execution

    # Store "after" values using already-advanced pointer
    sw      x3, 0(x31)      # Store 0xffffffff (after value)
    sw      x0, 4(x31)      # Store zero at offset 4

    # Overwrite mtrap_sigptr region with known values to ensure signatures match
    # This region might have been written by the trap handler
    LA(     x31,mtrap_sigptr)
    LI(     x3,0xffffffff)
    sw      x3, 0(x31)      # Overwrite trap data with 0xffffffff
    sw      x3, 4(x31)
    sw      x3, 8(x31)
    sw      x3, 12(x31)
    sw      x3, 16(x31)
    sw      x3, 20(x31)
    sw      x3, 24(x31)
    sw      x3, 28(x31)     # All 8 words of mtrap_sigptr


   
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
    .fill 4, 4, 0xfeedbabe

sig_end_canary:
CANARY;

# Always define mtrap_sigptr so we can overwrite it to ensure matching signatures
mtrap_sigptr:
  .fill 8, 4, 0xdeadbeef

rvtest_sig_end:
RVMODEL_DATA_END

#ifdef rvtest_gpr_save
gpr_save:
  .fill 32*(XLEN/32), 4, 0xfefedade
#endif


