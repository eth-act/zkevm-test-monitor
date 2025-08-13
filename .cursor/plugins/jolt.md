# Jolt Plugin Documentation

## Overview

The Jolt plugin integrates the Jolt zkVM (lightning-fast SNARKs with Jolt lookups) into the RISCOF testing framework. Jolt provides high-performance zero-knowledge proofs with optimized lookup mechanisms.

## Plugin Implementation

### File: `plugins/jolt/riscof_jolt.py`

**Class**: `jolt(pluginTemplate)`
**Model**: "jolt"
**Version**: "1.0.0"

### Key Features

- **RISC-V ISA Support**: RV32IM architecture focus
- **Robust Error Handling**: Comprehensive validation and logging
- **Signature Verification**: Post-execution signature validation
- **Flexible Execution**: Support for compilation-only mode

## Configuration

### ISA Specification (`jolt_isa.yaml`)
```yaml
hart_ids: [0]
hart0:
  ISA: RV32IM
  physical_addr_sz: 32
  User_Spec_Version: '2.3'
  supported_xlen: [32]
```

### Platform Specification (`jolt_platform.yaml`)
- Optimized for Jolt's specific requirements
- 32-bit address space configuration
- Custom memory layout for Jolt execution

## Implementation Details

### Initialization Process
1. **Configuration Validation**: Verify all required config parameters
2. **Binary Verification**: Check jolt-emu exists and is executable
3. **Path Setup**: Configure plugin and specification paths
4. **Job Configuration**: Set parallel execution parameters

### Compilation Process
- **Toolchain**: `riscv32-unknown-elf-gcc` for RV32 targets
- **ISA Detection**: Automatically build ISA string from specification
- **ABI Selection**: `ilp32` for 32-bit, `lp64` for 64-bit
- **Custom Linker**: Uses plugin-specific `link.ld`

### Execution Process
```python
# Jolt execution with signature extraction
simcmd = '{0} {1} --signature {2} --signature-granularity 4 > jolt.log 2>&1 || true'
```

#### Execution Parameters
- **Binary**: Compiled ELF test file
- **Signature File**: Output signature path
- **Granularity**: 4-byte signature granularity
- **Logging**: Comprehensive output capture

## Jolt-Specific Features

### Signature Granularity
- **Granularity**: 4-byte aligned signature extraction
- **Purpose**: Optimized for Jolt's memory model
- **Format**: Standard RISCOF signature format

### Error Recovery
- **Graceful Failure**: Uses `|| true` to prevent pipeline breaks
- **Comprehensive Logging**: All output captured to `jolt.log`
- **Post-Execution Validation**: Verifies signature file creation

### Build Process Optimization
The plugin includes sophisticated ISA string building:
```python
self.isa = 'rv' + self.xlen
if "I" in ispec["ISA"]: self.isa += 'i'
if "M" in ispec["ISA"]: self.isa += 'm'
# Additional extensions as supported
```

## Advanced Features

### Signature Validation
Post-execution verification ensures test integrity:
```python
if not os.path.exists(sig_file):
    logger.warning(f"Signature file not generated for {testname}")
    # Debug log analysis
    log_path = os.path.join(test_dir, 'jolt.log')
    if os.path.exists(log_path):
        with open(log_path, 'r') as f:
            logger.debug(f"jolt-emu output for {testname}: {f.read()}")
```

### Parallel Execution
- **Make-based**: Uses GNU Make for parallel test execution
- **Job Control**: Configurable via `jobs` parameter
- **Resource Management**: Optimized for system resources

### Target Run Control
Supports compilation-only mode when `target_run=0`:
```python
if self.target_run:
    # Full execution with jolt-emu
else:
    # Create placeholder signature
    simcmd = 'echo "# Test compiled but not executed" > {0}'.format(sig_file)
```

## Usage and Configuration

### Mount Requirements
- **Binary Path**: `/dut/bin/dut-exe` (jolt-emu executable)
- **Plugin Path**: `/dut/plugin` (contains plugin files)
- **Results Path**: `/riscof/riscof_work` (test results output)

### Environment Setup
- Plugin automatically copies to container plugin directory
- Sets up proper Python package structure with `__init__.py`
- Configures PATH for jolt-emu execution

## Error Handling and Debugging

### Validation Checks
1. **Binary Existence**: Verifies jolt-emu binary exists
2. **Executable Permissions**: Confirms binary is executable
3. **Configuration Completeness**: Validates all required config fields

### Logging and Debug
- **Execution Logs**: Captured in `jolt.log` per test
- **Warning System**: Alerts for missing signature files
- **Debug Output**: Detailed jolt-emu output for failed tests

### Common Issues
1. **Missing jolt-emu**: Binary not found at expected path
2. **Permission Errors**: Binary not executable
3. **Compilation Failures**: Toolchain or ISA compatibility issues
4. **Signature Extraction**: Jolt-specific signature format problems

## Performance Considerations

### Optimization Features
- **Parallel Compilation**: Multiple tests built simultaneously
- **Efficient Logging**: Captured but not displayed unless needed
- **Resource Management**: Configurable job limits
- **Graceful Degradation**: Continues on individual test failures

### Resource Usage
- **Memory**: Optimized for container environments
- **CPU**: Utilizes multiple cores via parallel jobs
- **I/O**: Efficient file handling and logging

## Future Enhancements

### Potential Improvements
1. **Extended ISA Support**: Additional RISC-V extensions
2. **Performance Metrics**: Execution timing and resource usage
3. **Enhanced Debugging**: More detailed error reporting
4. **Configuration Flexibility**: Runtime parameter tuning

### Integration Opportunities
- **CI/CD Integration**: Automated testing pipelines
- **Benchmark Suite**: Performance comparison testing
- **Formal Verification**: Integration with formal methods tools