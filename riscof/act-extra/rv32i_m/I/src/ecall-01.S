// Test ecall without privilege architecture.
//
// ZKVMs implement ecall without full CSR support. This test verifies ecall
// execution continues after the instruction, overwriting trap handler signatures
// for compatibility with the reference model.

#include "model_test.h"
#include "arch_test.h"

RVTEST_ISA("RV32I")

# Test code region
.section .text.init
.globl rvtest_entry_point

rvtest_entry_point:
RVMODEL_BOOT
RVTEST_CODE_BEGIN

#ifdef TEST_CASE_1
    RVTEST_CASE(1,"//check ISA:=regex(.*32.*); check ISA:=regex(.*I.*); def extra_trap_routine=True; def TEST_CASE_1=True",ecall)

    li      a7, 0
#ifdef JOLT_CYCLE_TRACK_ECALL
    # Jolt requires special values for cycle tracking ecalls
    li      a0, JOLT_CYCLE_TRACK_ECALL  # ecall ID
    LA(     a1, sigptr)                 # marker pointer (use sigptr address)
    li      a2, 1                       # JOLT_CYCLE_MARKER_START
#endif

    ecall
    nop

    # Write a signature to show that execution continued after the ecall
    LA(     x31,sigptr)
    LI(     x3,0x111fffaa)
    sw      x3, 0(x31)
    sw      x0, 4(x31)

    # Overwrite the signature written by the reference's trap handler
    LA(     x31,mtrap_sigptr)
    LI(     x3,0x222fffaa)
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

# unprivileged signature space
sigptr:
    .fill 4, 4, 0xfeedbabe

sig_end_canary:
CANARY;

# signature region to be written by the reference's trap handler only
mtrap_sigptr:
  .fill 8, 4, 0xdeadbeef

rvtest_sig_end:
RVMODEL_DATA_END
