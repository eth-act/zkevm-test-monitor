##### START_TEST_CONFIG #####
# REQUIRED_EXTENSIONS: ['I']
# MARCH: rv64i
# NEEDS_SIGNATURE: false
##### END_TEST_CONFIG #####

// The control of misaligned-bne: the same code with an aligned target, pc + 8.
// misaligned-bne fails when this test does not pass (misaligned-bne.control).

// The test checks no values, so it has no signature updates.
#define SIGUPD_COUNT 0

#include "riscv_arch_test.h"

RVTEST_BEGIN
  LI(x5, 1)
  .p2align 2
  bne x0, x5, .+8    // pc
  addi x0, x2, 0     // pc + 4: its upper half (pc + 6) is 0x0001, c.nop
  nop                // pc + 8
RVTEST_CODE_END

RVTEST_DATA_BEGIN
RVTEST_DATA_END
RVTEST_SIG_SETUP
