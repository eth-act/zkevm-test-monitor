# Jolt Plugin Component

## Overview
The Jolt plugin component is a RISCOF (RISC-V Architectural Compliance Framework) plugin that enables testing of the Jolt ZKVM emulator against the RISC-V architectural test suite. This component implements the necessary interfaces to compile, execute, and validate RISC-V assembly tests using the Jolt zero-knowledge virtual machine.

## Component Structure

### Location
- **Component Directory**: `/plugins/jolt/`
- **Environment Directory**: `/plugins/jolt/env/`

### Key Files

#### Core Plugin Files
- **`riscof_jolt.py`**: Main plugin implementation extending `pluginTemplate`
- **`jolt_isa.yaml`**: ISA specification defining RV32IM support
- **`jolt_platform.yaml`**: Platform configuration for Jolt emulator

#### Environment Files
- **`env/link.ld`**: Linker script for RISC-V test compilation
- **`env/model_test.h`**: C preprocessor macros for RISCOF integration

## Technical Details

### ISA Support
- **Architecture**: RV32IM (32-bit RISC-V with Integer and Multiplication extensions)
- **XLEN**: 32-bit
- **Extensions**: Base Integer (I) and Multiplication/Division (M)

### Plugin Implementation (`riscof_jolt.py`)

#### Key Features
1. **Compilation Pipeline**: Uses GCC cross-compiler with custom linker script
2. **Execution Control**: Configurable test execution vs. compile-only mode
3. **Signature Extraction**: Implements memory signature capture for test validation
4. **Parallel Execution**: Supports multi-threaded test execution via Makefile

#### Key Methods
- `__init__()`: Configuration validation and executable verification
- `initialise()`: Setup compilation commands and paths
- `build()`: ISA string construction and ABI configuration  
- `runTests()`: Parallel test compilation and execution

### Test Environment (`env/`)

#### Linker Script (`link.ld`)
- Base address: `0x80000000` (standard RISC-V)
- Special sections for RISCOF integration:
  - `.tohost`: Test completion signaling
  - Memory-mapped signature regions

#### Model Header (`model_test.h`)
- **HTIF Protocol**: Host-target interface for test completion
- **Signature Macros**: Memory region markers for validation
- **Boot/Halt Sequences**: Test initialization and termination

## Integration Points

### RISCOF Framework
- Extends `pluginTemplate` base class
- Implements required interface methods
- Supports RISCOF's differential testing model

### Docker Environment
- Designed for containerized execution
- Mounts plugin, binary, and results directories
- Integrates with project's Docker build system

### Test Execution Flow
1. **Compilation**: Assembly tests → ELF binaries with signature extraction
2. **Execution**: Jolt emulator runs tests with memory signature capture
3. **Validation**: Signatures compared against reference implementation

## Configuration

### Required Parameters
- `PATH`: Directory containing `dut-exe` (Jolt emulator binary)
- `pluginpath`: Path to plugin directory
- `ispec`: ISA specification file path
- `pspec`: Platform specification file path

### Optional Parameters
- `jobs`: Number of parallel compilation/execution jobs
- `target_run`: Enable/disable test execution (default: true)

## Security Considerations
- All code appears to be legitimate testing infrastructure
- No malicious patterns detected in plugin implementation
- Standard RISCOF plugin architecture with appropriate isolation

## Dependencies
- RISC-V GCC cross-compiler toolchain
- Jolt ZKVM emulator binary (`jolt-emu`)
- RISCOF framework
- Python standard libraries

## Usage Context
This component is part of a ZKVM testing framework that validates multiple zero-knowledge virtual machines (Jolt, SP1, OpenVM, etc.) against the official RISC-V architectural test suite. It ensures Jolt's RISC-V implementation correctness through differential testing against a formally verified reference model.