# Spike Plugin for RISCOF Testing

## Overview
The Spike plugin enables RISC-V Architectural Test compliance testing using the Spike RISC-V ISA simulator as a Device Under Test (DUT). This plugin is part of the RISCOF (RISC-V Compliance Framework) testing infrastructure for zero-knowledge virtual machines (ZKVMs).

## Component Structure

### Core Files
- `riscof_spike.py` - Main plugin implementation (251 lines)
- `spike_isa.yaml` - ISA specification configuration
- `spike_platform.yaml` - Platform-specific configuration
- `env/` - Environment files for test compilation

### Environment Files
- `env/link.ld` - Linker script defining memory layout for RISC-V tests
- `env/model_test.h` - C preprocessor macros for test framework integration

## Technical Details

### ISA Configuration (`spike_isa.yaml`)
- **Architecture**: RV32IMCZicsr_Zifencei
- **XLEN**: 32-bit
- **Extensions**: Integer (I), Multiplication (M), Compressed (C), CSR access, Fence instructions
- **Physical Address Size**: 32 bits
- **MISA Register**: Configured with reset value 1073746180

### Platform Configuration (`spike_platform.yaml`)
- **Memory-mapped Timer**: mtime at 0xbff8, mtimecmp at 0x4000
- **Interrupt Vectors**: NMI and reset vector labels defined
- **Memory Layout**: Text starts at 0x80000000 with 4KB aligned sections

### Plugin Implementation (`riscof_spike.py`)

#### Key Features
- **Parallel Execution**: Configurable job parallelization via `num_jobs`
- **Cross-compilation**: Uses riscv-unknown-elf-gcc toolchain
- **Signature Generation**: Implements RISCOF signature extraction protocol
- **ISA Detection**: Automatically builds ISA string from configuration

#### Main Methods
1. `__init__()` - Configuration parsing and path setup
2. `initialise()` - Compilation command template setup
3. `build()` - ISA string construction and ABI selection
4. `runTests()` - Test compilation, execution, and signature generation

#### Compilation Process
```bash
riscv{xlen}-unknown-elf-gcc -march={isa} -static -mcmodel=medany 
-fvisibility=hidden -nostdlib -nostartfiles -g
-T {plugin_path}/env/link.ld -I {plugin_path}/env/ 
-I {archtest_env} {test_file} -o {elf_file} {macros}
```

#### Execution Command
```bash
spike --isa={isa_string} +signature={sig_file} +signature-granularity=4 {elf_file}
```

### Memory Layout (link.ld)
- **Entry Point**: rvtest_entry_point
- **Base Address**: 0x80000000
- **Sections**: .text.init, .tohost, .text, .data, .bss with 4KB alignment

### Test Framework Macros (model_test.h)
- **RVMODEL_DATA_SECTION**: Sets up tohost/fromhost communication
- **RVMODEL_HALT**: Test termination sequence
- **RVMODEL_DATA_BEGIN/END**: Signature region markers
- **Interrupt Handling**: MSW, timer, and external interrupt macros

## Integration Points

### RISCOF Framework
- Inherits from `pluginTemplate` base class
- Implements required methods for test lifecycle management
- Generates makefiles for parallel test execution
- Produces signatures compatible with RISCOF validation

### Spike Simulator
- Configures ISA string based on enabled extensions
- Uses signature generation features for compliance testing
- Supports 32-bit RV32IMC configuration

## Usage Context
This plugin enables automated compliance testing of RISC-V implementations against the official architectural test suite, specifically configured for 32-bit RISC-V cores with integer, multiplication, and compressed instruction support.