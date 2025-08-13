# SP1 Plugin Documentation

## Overview

The SP1 plugin integrates Succinct's zkVM into the RISCOF testing framework. SP1 is a zero-knowledge virtual machine that enables verifiable computation with high performance.

## Plugin Implementation

### File: `plugins/sp1/riscof_sp1.py`

**Class**: `sp1(pluginTemplate)`
**Model**: "sp1"
**Version**: "XXX" (placeholder)

### Key Features

- **RISC-V ISA Support**: RV32IM architecture
- **Signature Extraction**: Custom signature handling for SP1
- **Parallel Execution**: Configurable job parallelization
- **Input Handling**: Custom stdin handling for SP1 executor

## Configuration

### ISA Specification (`sp1_isa.yaml`)
```yaml
hart_ids: [0]
hart0:
  ISA: RV32IM
  physical_addr_sz: 32
  User_Spec_Version: '2.3'
  supported_xlen: [32]
```

### Platform Specification (`sp1_platform.yaml`)
- Standard RISC-V platform configuration
- 32-bit address space
- Memory-mapped I/O regions

## Implementation Details

### Compilation Process
- **Toolchain**: `riscv32-unknown-elf-gcc`
- **Architecture**: Determined from ISA specification (rv32i/m/f/d/c)
- **ABI**: `ilp32` for 32-bit, `lp64` for 64-bit
- **Linker Script**: Custom `link.ld` in plugin environment

### Execution Process
1. **Binary Generation**: Compile test to ELF format
2. **Input Preparation**: Create empty stdin binary (24 bytes of zeros)
3. **SP1 Execution**: Run with signature extraction
   ```bash
   sp1-exe --signatures <sig_file> --program <elf> --stdin <empty_stdin> --executor-mode simple
   ```

### Signature Handling
- **Format**: SP1-specific signature extraction
- **File**: `<test_name>.signature` in test directory
- **Content**: Memory checkpoints written during execution

## SP1-Specific Features

### Empty Stdin Handling
The plugin creates a 24-byte empty stdin file for SP1 compatibility:
```python
open('empty_stdin.bin', 'wb').write(b'\x00'*24)
```

### Executor Mode
- **Mode**: `simple` executor mode for standard test execution
- **Performance**: Optimized for test suite execution

## Usage Notes

### Requirements
- SP1 binary must be mounted to `/dut/bin/dut-exe`
- Plugin files must be mounted to `/dut/plugin`

### Limitations
- Currently supports RV32IM only
- Requires specific stdin format (may be brittle)
- Signature extraction format is SP1-specific

## Error Handling

### Common Issues
1. **Missing Binary**: SP1 executable not found at expected path
2. **Compilation Errors**: RISC-V toolchain issues
3. **Signature Extraction**: SP1-specific signature format problems

### Debugging
- Check `jolt.log` files in test directories for execution output
- Verify ISA compatibility between test and SP1 capabilities
- Ensure proper mount points for binaries and plugins

## Future Improvements

### Potential Enhancements
1. **Dynamic Stdin**: More flexible stdin handling
2. **Extended ISA**: Support for additional RISC-V extensions
3. **Performance Metrics**: Execution timing and resource usage
4. **Error Recovery**: Better handling of failed tests

### Configuration Flexibility
- Make stdin format configurable
- Support different executor modes
- Add performance profiling options