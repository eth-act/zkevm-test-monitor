# Sail C Simulator Plugin Component

## Overview
The Sail C Simulator plugin component is a RISCOF (RISC-V Architectural Compliance Framework) plugin that enables testing against the Sail C simulator implementation. This component provides a formal verification pathway using the Sail specification language's C backend, allowing for rigorous architectural compliance testing of RISC-V implementations.

## Component Structure

### Location
- **Component Directory**: `/plugins/sail_cSim/`
- **Environment Directory**: `/plugins/sail_cSim/env/`

### Key Files

#### Core Plugin Files
- **`riscof_sail_cSim.py`**: Main plugin implementation extending `pluginTemplate`
- **`__init__.py`**: Python package initialization file

#### Environment Files
- **`env/link.ld`**: Linker script for RISC-V test compilation
- **`env/model_test.h`**: C preprocessor macros for RISCOF integration

## Technical Details

### ISA Support
- **Architecture**: Configurable RV32/RV64 with multiple extensions
- **XLEN**: Auto-detected 32-bit or 64-bit based on ISA specification
- **Extensions**: Dynamically configured (I, M, C, F, D)
- **Executables**: Uses `riscv_sim_rv32d` and `riscv_sim_rv64d`

### Plugin Implementation (`riscof_sail_cSim.py`)

#### Key Features
1. **Dynamic ISA Configuration**: Automatically builds ISA string from YAML specification
2. **Dual Architecture Support**: Handles both RV32 and RV64 configurations
3. **PMP Support**: Configurable Physical Memory Protection with grain and count settings
4. **Coverage Integration**: Optional RISC-V ISA Coverage (riscv_isac) integration
5. **Parallel Execution**: Multi-job compilation and testing support

#### Key Methods
- `__init__()`: Configuration parsing, executable verification, and path setup
- `initialise()`: Compilation command template setup and environment configuration
- `build()`: ISA string construction, ABI detection, and tool validation
- `runTests()`: Parallel test execution with Makefile generation

#### Configuration Parameters
- `PATH`: Directory containing Sail simulator binaries
- `pluginpath`: Plugin directory path
- `ispec`/`pspec`: ISA and platform specification files
- `jobs`: Parallel execution job count
- `make`: Make command (defaults to 'make')

### Sail Simulator Integration

#### Execution Command Structure
```bash
riscv_sim_rv{32|64}d -i -v [pmp_flags] --signature-granularity=4 --test-signature={sig_file} {elf}
```

#### PMP Configuration
- **Grain Setting**: `--pmp-grain=<value>` from ISA YAML
- **Count Setting**: `--pmp-count=<value>` from ISA YAML
- **Conditional**: Only applied when PMP is implemented in ISA specification

### Test Environment (`env/`)

#### Compilation Pipeline
- **Compiler**: `riscv{32|64}-unknown-elf-gcc`
- **Flags**: `-march={isa} -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles`
- **Linker**: Custom `link.ld` script
- **ABI**: Auto-selected (`lp64` for 64-bit, `ilp32` for 32-bit)

#### Coverage Analysis
- **Tool**: `riscv_isac` (RISC-V ISA Coverage)
- **Parser**: `c_sail` for Sail simulator logs
- **Labels**: Configurable coverage labels and macros
- **Output**: Coverage reports with signature validation

## Integration Points

### RISCOF Framework
- Extends `pluginTemplate` base class
- Implements required interface methods for compilation and execution
- Supports differential testing against reference implementations

### Formal Verification Context
- Uses Sail specification language for architectural modeling
- Provides formally verified reference for compliance testing
- Enables high-confidence validation of RISC-V implementations

### Docker Environment
- Designed for containerized execution
- Integrates with project's Docker build system
- Mounts plugin, binary, and results directories

### Test Execution Flow
1. **Configuration**: ISA/platform YAML parsing and tool validation
2. **Compilation**: Assembly tests → ELF binaries with RISCOF integration
3. **Execution**: Sail simulator runs tests with signature capture
4. **Coverage**: Optional ISA coverage analysis and reporting
5. **Validation**: Signature comparison for architectural compliance

## Configuration

### Required Parameters
- `PATH`: Directory containing Sail simulator binaries (`riscv_sim_rv32d`, `riscv_sim_rv64d`)
- `pluginpath`: Path to plugin directory
- `ispec`: ISA specification file path
- `pspec`: Platform specification file path

### Optional Parameters
- `jobs`: Number of parallel compilation/execution jobs (default: 1)
- `make`: Make command override (default: 'make')

### ISA Specification Requirements
- Must define `supported_xlen` for architecture detection
- Should include ISA extensions (I, M, C, F, D)
- Optional PMP configuration with grain and count settings

## Security Considerations
- All code appears to be legitimate formal verification infrastructure
- No malicious patterns detected in plugin implementation
- Standard RISCOF plugin architecture with appropriate process isolation
- Sail simulator provides formally verified execution environment

## Dependencies
- RISC-V GCC cross-compiler toolchain (`riscv{32|64}-unknown-elf-gcc`)
- Sail C simulator binaries (`riscv_sim_rv32d`, `riscv_sim_rv64d`)
- RISCOF framework
- Optional: `riscv_isac` for coverage analysis
- Standard build tools (`make`)

## Usage Context
This component is part of a comprehensive ZKVM testing framework that validates multiple implementations against the RISC-V architectural specification. The Sail C Simulator provides a formally verified reference implementation, making it particularly valuable for high-assurance testing scenarios where mathematical correctness is paramount. It complements other testing approaches (spike, ZKVM emulators) by providing a formal verification baseline for architectural compliance validation.