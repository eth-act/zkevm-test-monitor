# RISC-V RV64I Example Test
# This test demonstrates the RISCOF test framework structure and macros

#include "model_test.h"    # Platform-specific macros (RVMODEL_BOOT, RVMODEL_HALT)
#include "arch_test.h"     # Test framework macros (RVTEST_*, LA, LI, CANARY)

# RVTEST_ISA macro declares which ISA this test requires
# The string is matched against the DUT's declared capabilities
RVTEST_ISA("RV64I")

.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:

# RVMODEL_BOOT: Platform-specific initialization code
# Each ZKVM plugin defines this to set up their environment
RVMODEL_BOOT

# RVTEST_CODE_BEGIN: Marks the start of actual test code
RVTEST_CODE_BEGIN

# TEST_CASE macros allow conditional compilation of different test scenarios
# Format: RVTEST_CASE(number, "ISA requirements", test_label)
#ifdef TEST_CASE_1
RVTEST_CASE(0,"//check ISA:=regex(.*64.*);check ISA:=regex(.*I.*);def TEST_CASE_1=True;",example)

# === Framework Macros ===

# LA/LI are framework macros (not la/li pseudo-instructions) that ensure:
# - Consistent behavior across different assemblers
# - Fixed-length instruction sequences for predictable testing
# - Special handling (e.g., skip if destination is x0)

RVTEST_SIGBASE(x31, signature_x31_1)  # Sets x31 = address of signature, initializes internal offset

LI(x1, 0x123456789ABCDEF0)    # LI: Load Immediate macro - loads 64-bit test pattern

LA(x4, test_data)         # Get address of test data
ld x2, 0(x4)              # Load 64-bit from memory
add x3, x1, x2            # Compute result

RVTEST_SIGUPD(x31, x1)    # Stores x1 to signature and auto-increments offset (equiv: sd x1, 0(x31); offset+=8)
RVTEST_SIGUPD(x31, x2)    # Stores x2 to signature and auto-increments offset (equiv: sd x2, 8(x31); offset+=8)
RVTEST_SIGUPD(x31, x3)    # Stores x3 to signature and auto-increments offset (equiv: sd x3, 16(x31); offset+=8)

LI(x6, 0xDEADBEEFCAFEBABE)    # Load 64-bit marker value
RVTEST_SIGUPD(x31, x6)        # Stores x6 to signature and auto-increments offset (equiv: sd x6, 24(x31); offset+=8)

# The signature region is compared between DUT and reference model
# If all signature values match, the test passes

#endif

# RVTEST_CODE_END: Marks the end of test code
RVTEST_CODE_END

# RVMODEL_HALT: Platform-specific code to terminate execution
# Each ZKVM plugin defines how to properly stop execution
RVMODEL_HALT

# === Data Section ===
# RVTEST_DATA_BEGIN/END: Marks the test's data region
RVTEST_DATA_BEGIN
.align 8

test_data:
    .dword 0xFEDCBA9876543210  # Example 64-bit data that can be loaded
    .dword 0x1122334455667788

RVTEST_DATA_END

# === Signature Section ===
# RVMODEL_DATA_BEGIN/END: Platform-specific data region
# This is where test results are stored for comparison
RVMODEL_DATA_BEGIN

rvtest_sig_begin:
sig_begin_canary:
CANARY;               # CANARY macro: Inserts 0xdeadbeef as a boundary marker

# Signature storage area - this is what gets compared
# For RV64, using 8-byte alignment and storage
signature_x31_1:
    .fill 8, 8, 0xdeadbeef    # Reserve 8 doublewords (64 bytes) for results

sig_end_canary:
CANARY;               # End boundary marker
rvtest_sig_end:

RVMODEL_DATA_END