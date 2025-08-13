# OpenVM Plugin Component

## Overview
The OpenVM plugin component is a RISCOF (RISC-V Architectural Compliance Framework) plugin that enables testing of the OpenVM ZKVM emulator against the RISC-V architectural test suite. This component implements the necessary interfaces to compile, execute, and validate RISC-V assembly tests using the OpenVM zero-knowledge virtual machine.

## Component Structure

### Location
- **Component Directory**: `/plugins/openvm/`
- **Environment Directory**: `/plugins/openvm/env/`

### Key Files

#### Core Plugin Files
- **`riscof_openvm.py`**: Main plugin implementation extending `pluginTemplate`
- **`openvm_isa.yaml`**: ISA specification defining RV32IM support
- **`openvm_platform.yaml`**: Platform configuration for OpenVM emulator

#### Environment Files
- **`env/link.ld`**: Linker script for RISC-V test compilation
- **`env/model_test.h`**: C preprocessor macros for RISCOF integration

## Technical Details

### ISA Support
- **Architecture**: RV32IM (32-bit RISC-V with Integer and Multiplication extensions)
- **XLEN**: 32-bit
- **Extensions**: Base Integer (I) and Multiplication/Division (M)
- **Physical Address Size**: 32-bit

### Plugin Implementation (`riscof_openvm.py`)

#### Key Features
1. **Compilation Pipeline**: Uses GCC cross-compiler with custom linker script
2. **Execution Control**: Configurable test execution vs. compile-only mode (defaults to compile-only)
3. **Signature Extraction**: Implements memory signature capture for test validation
4. **Parallel Execution**: Supports multi-threaded test execution via Makefile
5. **Cargo Integration**: Uses `cargo-openvm` for test execution

#### Key Methods
- `__init__()`: Configuration validation and executable verification
- `initialise()`: Setup compilation commands and paths
- `build()`: ISA string construction and ABI configuration
- `runTests()`: Parallel test compilation and execution with OpenVM

#### Execution Strategy
- **Default Mode**: Compile-only (`target_run = False` by default)
- **Runtime Execution**: Uses `cargo-openvm run --elf` with signature extraction
- **Error Handling**: Graceful failure handling with log capture

### Test Environment (`env/`)

#### Linker Script (`link.ld`)
- Base address: `0x0` (differs from standard RISC-V `0x80000000`)
- Special sections for RISCOF integration:
  - `.tohost`: Test completion signaling
  - `.data`: 16-byte aligned signature regions
  - Memory layout optimized for OpenVM

#### Model Header (`model_test.h`)
- **Custom Halt Logic**: Uses `.insn i 0x0b` instruction for termination
- **RISC Zero License**: Apache 2.0 licensed header from RISC Zero
- **Test Macros**: Pass/fail sequences with custom instruction encoding
- **Signature Regions**: Begin/end signature markers for validation

## Integration Points

### RISCOF Framework
- Extends `pluginTemplate` base class
- Implements required interface methods
- Supports RISCOF's differential testing model

### Docker Environment
- Designed for containerized execution
- Mounts plugin, binary, and results directories
- Integrates with project's Docker build system

### OpenVM Execution
- **Binary**: `dut-exe` (cargo-openvm executable)
- **Command**: `cargo-openvm run --elf {binary} --signatures {sig_file}`
- **Configuration**: Creates dummy `openvm.toml` to avoid warnings

### Test Execution Flow
1. **Compilation**: Assembly tests → ELF binaries with signature extraction
2. **Execution**: OpenVM emulator runs tests with memory signature capture
3. **Validation**: Signatures compared against reference implementation

## Configuration

### Required Parameters
- `PATH`: Directory containing `dut-exe` (OpenVM emulator binary)
- `pluginpath`: Path to plugin directory
- `ispec`: ISA specification file path
- `pspec`: Platform specification file path

### Optional Parameters
- `jobs`: Number of parallel compilation/execution jobs (default: 1)
- `target_run`: Enable/disable test execution (default: false for `--no-dut-run`)

## Notable Differences from Other Plugins

### Memory Layout
- Uses base address `0x0` instead of standard `0x80000000`
- Custom alignment requirements for signature regions

### Execution Model
- Defaults to compile-only mode unlike other plugins
- Uses cargo-based execution environment
- Custom instruction encoding for halt sequences

### Error Handling
- Includes `|| true` for graceful failure handling
- Captures execution logs for debugging
- Supports dummy signature generation when not running

## Security Considerations
- All code appears to be legitimate testing infrastructure
- No malicious patterns detected in plugin implementation
- Standard RISCOF plugin architecture with appropriate isolation
- Licensed under Apache 2.0 from RISC Zero

## Dependencies
- RISC-V GCC cross-compiler toolchain
- Cargo and Rust toolchain
- OpenVM emulator binary (`cargo-openvm`)
- RISCOF framework
- Python standard libraries

## Usage Context
This component is part of a ZKVM testing framework that validates multiple zero-knowledge virtual machines (Jolt, SP1, OpenVM, etc.) against the official RISC-V architectural test suite. It ensures OpenVM's RISC-V implementation correctness through differential testing against a formally verified reference model. The plugin is specifically designed to work with OpenVM's cargo-based execution environment and supports both compilation-only and full execution modes.