// Test ecall without any part of the privilege architecture.
//
// The base ISA RV32I requires that ecall be implemented but places no conditions on how it executes.
// Many (but not all) ZKVMs impelement ecall using a trap handler that does not follow the privilege spec. This test allows
// testing such implementations. Unfortunately, running RISCOF with the Sail model as a reference, one cannot simply remove 
// rvtest_mtrap_routine (extended by our extra_trap_routine flag) without hitting errors requiring that Zicsr be impelemented.
// Our solution is to keep the privilege signature region, but to post-process it (in the test) to ensure those signatures will
// match in such cases.
//
// Note that the official architecture tests's privlege tests do cover ecall, and implementations of Zicsr should be additionally
// tested against using that suite.

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
    
    li      a7, 0
    ecall
    nop

    # Write a signature to show that execution continued after the ecall
    LA(     x31,sigptr)  
    LI(     x3,0xffffffff)
    sw      x3, 0(x31)
    sw      x0, 4(x31)

    # Overwrite the signature written by the reference's trap handler
    LA(     x31,mtrap_sigptr)
    LI(     x3,0xffffffff)
    sw      x3, 0(x31)
    sw      x3, 4(x31)
    sw      x3, 8(x31)
    sw      x3, 12(x31)
    sw      x3, 16(x31)
    sw      x3, 20(x31)
    sw      x3, 24(x31)
    sw      x3, 28(x31)
#endif

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

# unprivileged signature spce
sigptr:
    .fill 4, 4, 0xfeedbabe

sig_end_canary:
CANARY;

# signature region to be written by the reference's trap handler only
mtrap_sigptr:
  .fill 8, 4, 0xdeadbeef

rvtest_sig_end:
RVMODEL_DATA_END

