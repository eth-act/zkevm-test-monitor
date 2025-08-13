# SP1 Plugin - RISCOF Integration

## Overview
The SP1 plugin enables testing of the SP1 zero-knowledge virtual machine using the RISC-V Architectural Test Suite through the RISCOF framework. SP1 is a zkVM that can execute RISC-V programs and generate zero-knowledge proofs of correct execution.

## Component Structure
```
plugins/sp1/
├── riscof_sp1.py      # Main plugin implementation
├── sp1_isa.yaml       # ISA configuration (RV32IM)
├── sp1_platform.yaml  # Platform configuration
└── env/               # Build environment files
```

## Purpose
This plugin serves as a bridge between RISCOF (RISC-V Compatibility Framework) and the SP1 zkVM, allowing:
- Automated execution of RISC-V architectural tests on SP1
- Signature extraction and comparison for compliance verification
- Integration with the larger ZKEVM testing infrastructure

## Key Components

### riscof_sp1.py:185
Main plugin implementation inheriting from `pluginTemplate`. Key features:
- **ISA Support**: RV32IM (32-bit RISC-V with Integer and Multiply extensions)
- **Signature Extraction**: Custom implementation for SP1's execution model
- **Build System**: GCC-based compilation with SP1-specific linking
- **Execution**: Direct binary execution through SP1's simple executor mode

### sp1_isa.yaml:28
ISA specification defining:
- 32-bit RISC-V architecture
- Integer (I) and Multiply (M) extensions enabled
- Physical address space: 32-bit
- WARL (Write Any Read Legal) field configurations

### sp1_platform.yaml:11
Platform configuration specifying:
- Timer implementations (disabled)
- Reset and NMI vector labels
- Memory-mapped timer addresses

## Architecture

### Compilation Flow
1. RISC-V assembly tests compiled with `riscv32-unknown-elf-gcc`
2. Custom linker script from `env/link.ld`
3. Static linking with SP1-specific memory model
4. Output: ELF binaries ready for SP1 execution

### Execution Flow
1. SP1 executor runs compiled test binaries
2. Signature data extracted during execution
3. Signatures compared against reference implementation
4. Pass/fail results reported through RISCOF framework

### Key Implementation Details
- **Empty Stdin Handling**: Creates 24-byte zero-filled stdin file for SP1 compatibility
- **Signature File Format**: Follows RISCOF naming convention `DUT-sp1.signature`
- **Parallel Execution**: Supports configurable job parallelism via makefile generation
- **Build Optimization**: Uses medany code model for position-independent execution

## Integration Points

### With RISCOF Framework
- Implements required `pluginTemplate` interface
- Provides ISA and platform YAML configurations
- Generates makefiles for parallel test execution
- Handles signature file management

### With SP1 zkVM
- Uses SP1's simple executor mode for test execution
- Interfaces with SP1's signature extraction capabilities
- Manages SP1-specific input/output requirements

## Testing Coverage
- **Supported**: RV32IM instruction set
- **Architecture**: 32-bit RISC-V compliance testing
- **Extensions**: Integer base + Multiply extension
- **Execution Model**: Simple (non-proving) mode for fast testing

## Usage Context
Part of the larger ZKEVM testing infrastructure that validates multiple zero-knowledge virtual machines against RISC-V architectural compliance standards. This plugin specifically handles SP1 zkVM integration within the Docker-based testing environment.