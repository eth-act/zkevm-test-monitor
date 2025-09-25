// RISC-V RV32I Example Test
# This test demonstrates the RISCOF test framework structure and macros

#include "model_test.h"    # Platform-specific macros (RVMODEL_BOOT, RVMODEL_HALT)
#include "arch_test.h"     # Test framework macros (RVTEST_*, LA, LI, CANARY)

# The string is matched against the DUT's declared capabilities
RVTEST_ISA("RV32I")

.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:

# Each ZKVM plugin defines this to set up their environment
RVMODEL_BOOT

RVTEST_CODE_BEGIN

# TEST_CASE macros allow conditional compilation of different test scenarios
# Format: RVTEST_CASE(number, "ISA requirements", test_label)
#ifdef TEST_CASE_1
RVTEST_CASE(0,"//check ISA:=regex(.*32.*);check ISA:=regex(.*I.*);def TEST_CASE_1=True;",example)

# LA/LI are framework macros akin to the la/li pseudo-instructions that ensure:
# - Consistent behavior across different assemblers
# - Fixed-length instruction sequences for predictable testing
# - Special handling (e.g., skip if destination is x0)

RVTEST_SIGBASE(x31, signature_x31_1)  # Sets x31 = address of signature, initializes internal offset

LI(x1, 0x00000001)        # LI: Load Immediate macro - loads test pattern

LA(x4, test_data)         # Could load an address of some data region
lw x2, 0(x4)              # Load from memory
add x3, x1, x2            # 3 = 1 + 2

RVTEST_SIGUPD(x31, x1)    # Stores x1 to signature and auto-increments offset (equiv: sw x1, 0(x31); offset+=4)
RVTEST_SIGUPD(x31, x2)    # Stores x2 to signature and auto-increments offset (equiv: sw x2, 4(x31); offset+=4)
RVTEST_SIGUPD(x31, x3)    # Stores x3 to signature and auto-increments offset (equiv: sw x3, 8(x31); offset+=4)

LI(x6, 0xdeadbeef)        # could load a maker value to deliniate begin/end of group of assertsions
RVTEST_SIGUPD(x31, x6)

# The signature region is compared between DUT and reference model
# If all signature values match, the test passes

#endif

RVTEST_CODE_END

# Each ZKVM plugin defines how to properly stop execution
RVMODEL_HALT

# RVTEST_DATA_BEGIN/END: Marks the test's data region
RVTEST_DATA_BEGIN
.align 4

test_data:
    .word 0x00000002  # Example data that can be loaded by the test

RVTEST_DATA_END

# This is where test results are stored for comparison
RVMODEL_DATA_BEGIN

rvtest_sig_begin:
sig_begin_canary:
CANARY;               # CANARY macro: Inserts 0xdeadbeef as a boundary marker

# Signature storage area - this is what gets compared
# The .fill directive reserves space: count, size, initial_value
signature_x31_1:
    .fill 4, 4, 0xdeadbeef    # Reserve 4 words (16 bytes) for results

sig_end_canary:
CANARY;               # End boundary marker
rvtest_sig_end:

RVMODEL_DATA_END
