##### START_TEST_CONFIG #####
# REQUIRED_EXTENSIONS: ['I']
# MARCH: rv64i
# NEEDS_SIGNATURE: false
##### END_TEST_CONFIG #####

// The control of misaligned-jalr-2mod4: the same code with an aligned target, rs1 + imm
// = pc + 16. misaligned-jalr-2mod4 fails when this test does not pass
// (misaligned-jalr-2mod4.control).

// The test checks no values, so it has no signature updates.
#define SIGUPD_COUNT 0

#include "riscv_arch_test.h"

RVTEST_BEGIN
  .p2align 2
  auipc x7, 0        // pc
  addi x7, x7, 6     // rs1 = pc + 6
  jalr x1, 10(x7)    // pc + 8: jump to rs1 + 10 = pc + 16
  addi x0, x2, 0     // pc + 12: its upper half (pc + 14) is 0x0001, c.nop
  addi x0, x2, 0     // pc + 16
RVTEST_CODE_END

RVTEST_DATA_BEGIN
RVTEST_DATA_END
RVTEST_SIG_SETUP
