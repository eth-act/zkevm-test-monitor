##### START_TEST_CONFIG #####
# REQUIRED_EXTENSIONS: ['I']
# MARCH: rv64i
# NEEDS_SIGNATURE: false
##### END_TEST_CONFIG #####

// Instruction-address-misaligned exception: a JALR with rs1 + imm = pc + 15 (3 mod 4);
// JALR clears bit 0, so the target is pc + 14. The target pc + 14 is not 4-byte aligned,
// and without C, IALIGN=32, so the zkVM must terminate abnormally
// (misaligned-jalr-3mod4.outcome). Each continuation (the target rounded down to pc + 12
// or up to pc + 16, or the jump skipped) reaches RVMODEL_HALT_PASS at RVTEST_CODE_END, a
// successful termination, so the test fails. The stimulus is ACT4's
// cp_instr_adr_misaligned_jalr
// (generators/testgen/src/testgen/priv/extensions/ExceptionsCommon.py).

// The test checks no values, so it has no signature updates.
#define SIGUPD_COUNT 0

#include "riscv_arch_test.h"

RVTEST_BEGIN
  .p2align 2
  auipc x7, 0        // pc
  addi x7, x7, 7     // rs1 = pc + 7
  jalr x1, 8(x7)     // pc + 8: jump to rs1 + 8 = pc + 15
  addi x0, x2, 0     // pc + 12: its upper half (pc + 14) is 0x0001, c.nop
  addi x0, x2, 0     // pc + 16
RVTEST_CODE_END

RVTEST_DATA_BEGIN
RVTEST_DATA_END
RVTEST_SIG_SETUP
