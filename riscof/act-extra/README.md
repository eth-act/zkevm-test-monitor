# ACT-Extra Custom Test Suite

## Overview
ACT-Extra is a custom RISC-V test suite that supplements the standard riscv-arch-test suite with additional tests for specific bug reproductions and edge cases. It follows the exact same directory structure and naming conventions as riscv-arch-test to ensure seamless integration with RISCOF.

## Directory Structure
```
act-extra/
├── env/                    # Symlink to riscv-arch-test/riscv-test-suite/env/
├── Makefile.include        # Build configuration
├── README.md              # This file
├── rv64i_m/               # RV64 + Machine mode tests
│   ├── I/                 # Base integer instruction tests
│   │   └── src/           # Test assembly files
│   ├── M/                 # Multiply/divide extension tests (future)
│   │   └── src/
│   └── A/                 # Atomic extension tests (future)
│       └── src/
└── rv32i_m/               # RV32 + Machine mode tests
    └── I/                 # Base integer instruction tests
        └── src/
```

## Test Naming Convention
All tests must follow the riscv-arch-test naming pattern:
- Format: `{instruction}-{number}.S`
- Examples: `nop-01.S`, `add-01.S`, `zero-skip-01.S`
- Use dashes (`-`), not underscores
- Two-digit zero-padded numbers (`01`, `02`, etc.)
- Capital `.S` extension

## Adding New Tests

### 1. Create the test file
Place your test in the appropriate directory based on:
- Architecture: `rv32i_m/` or `rv64i_m/`
- Extension: `I/`, `M/`, `A/`, etc.
- Always in the `src/` subdirectory

### 2. Use standard test structure
```assembly
// Generated manually for act-extra test suite
//
// This assembly file tests [description]

#include "model_test.h"
#include "arch_test.h"

RVTEST_ISA("RV64I")  // or "RV32I" as appropriate

.section .text.init
.globl rvtest_entry_point

rvtest_entry_point:
RVMODEL_BOOT
RVTEST_CODE_BEGIN

#ifdef TEST_CASE_1
RVTEST_CASE(0,"//check ISA:=regex(.*64.*);check ISA:=regex(.*I.*);def TEST_CASE_1=True;",test-name)
RVTEST_SIGBASE(x31,signature_x31_0)

// Your test code here
// Use RVTEST_SIGUPD to record results

#endif

RVTEST_CODE_END
RVMODEL_HALT

RVTEST_DATA_BEGIN
RVTEST_DATA_END

.section .data
.align 4

RVTEST_SIGNATURE_BEGIN
signature_x31_0:
    .fill 32, 4, 0xdeadbeef
RVTEST_SIGNATURE_END
```

### 3. Test with specific ZKVM
The test suite supports filtering by ISA capabilities:
- ZisK: RV64IMA
- Other ZKVMs: RV32IM (typically)

## Environment Files
The `env/` directory is a symlink to the standard riscv-arch-test environment files, created automatically by the Docker entrypoint. This ensures consistency with the standard test macros.

## Running Tests

### Run ACT-Extra custom tests for a specific ZKVM:
```bash
./scripts/test.sh --act-extra zisk
```

### Run standard tests (default):
```bash
./scripts/test.sh zisk
```

## Current Tests

### rv64i_m/I/src/
- `zero-skip-01.S` - Tests that NOP instructions properly increment the PC (program counter)

## Test Validation
Use the validation script to verify test structure:
```bash
./scripts/validate-custom-tests.sh
```

This checks:
- Directory structure compliance
- Required macro usage
- Proper naming conventions
- Successful execution on target ZKVM
