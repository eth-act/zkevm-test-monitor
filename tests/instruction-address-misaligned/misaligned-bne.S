##### START_TEST_CONFIG #####
# REQUIRED_EXTENSIONS: ['I']
# MARCH: rv64i
# NEEDS_SIGNATURE: false
##### END_TEST_CONFIG #####

// Instruction-address-misaligned exception: a taken BNE (0 != 1) to pc + 6. The target
// pc + 6 is not 4-byte aligned, and without C, IALIGN=32, so the zkVM must terminate
// abnormally (misaligned-bne.outcome). Each continuation (the target rounded down to
// pc + 4 or up to pc + 8, or the jump skipped) reaches RVMODEL_HALT_PASS at
// RVTEST_CODE_END, a successful termination, so the test fails. The stimulus is ACT4's
// cp_instr_adr_misaligned_branch
// (generators/testgen/src/testgen/priv/extensions/ExceptionsCommon.py).

// The test checks no values, so it has no signature updates.
#define SIGUPD_COUNT 0

#include "riscv_arch_test.h"

RVTEST_BEGIN
  LI(x5, 1)
  .p2align 2
  bne x0, x5, .+6    // pc
  addi x0, x2, 0     // pc + 4: its upper half (pc + 6) is 0x0001, c.nop
  nop                // pc + 8
RVTEST_CODE_END

RVTEST_DATA_BEGIN
RVTEST_DATA_END
RVTEST_SIG_SETUP
