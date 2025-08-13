# OpenVM Plugin Documentation

## Overview

The OpenVM plugin integrates the OpenVM modular, performant zkVM framework into the RISCOF testing framework. OpenVM is designed for high-performance zero-knowledge computation with a modular architecture.

## Plugin Implementation

### File: `plugins/openvm/riscof_openvm.py`

**Class**: `openvm(pluginTemplate)`
**Model**: "openvm"
**Version**: To be determined based on OpenVM implementation

### Key Features

- **Modular Architecture**: Leverages OpenVM's modular design
- **Performance Focus**: Optimized for high-performance zkVM execution
- **RISC-V Compatibility**: Standard RISC-V ISA support
- **Flexible Configuration**: Adaptable to different OpenVM configurations

## Configuration

### ISA Specification (`openvm_isa.yaml`)
```yaml
hart_ids: [0]
hart0:
  ISA: RV32IM                    # Base integer + multiplication
  physical_addr_sz: 32           # 32-bit address space
  User_Spec_Version: '2.3'       # RISC-V specification version
  supported_xlen: [32]           # 32-bit register width
```

### Platform Specification (`openvm_platform.yaml`)
- OpenVM-specific platform configuration
- Memory layout optimized for OpenVM execution model
- Custom device tree and memory regions

## Implementation Details

### Plugin Structure
Following the standard RISCOF plugin template:

```python
class openvm(pluginTemplate):
    __model__ = "openvm"
    
    def __init__(self, *args, **kwargs):
        # Initialize OpenVM-specific configuration
        pass
    
    def initialise(self, suite, work_dir, archtest_env):
        # Set up OpenVM compilation environment
        pass
    
    def build(self, isa_yaml, platform_yaml):
        # Configure for OpenVM ISA support
        pass
    
    def runTests(self, testList):
        # Execute tests using OpenVM
        pass
```

### Compilation Process
- **Toolchain**: `riscv32-unknown-elf-gcc`
- **Target**: RV32IM architecture
- **Optimization**: Configured for OpenVM execution model
- **Linking**: Custom linker script for OpenVM memory layout

### Execution Model
OpenVM execution typically involves:
1. **Program Loading**: Load compiled RISC-V binary
2. **Execution**: Run program in OpenVM environment
3. **Signature Extraction**: Extract memory signatures for comparison
4. **Result Capture**: Capture execution results and logs

## OpenVM-Specific Features

### Modular Design
OpenVM's modular architecture allows for:
- **Custom Instruction Sets**: Extended or custom RISC-V instructions
- **Performance Optimizations**: Module-specific optimizations
- **Flexible Execution**: Different execution models per module

### Performance Characteristics
- **High Throughput**: Optimized for performance-critical applications
- **Resource Efficiency**: Efficient memory and CPU utilization
- **Scalability**: Supports large-scale computations

## Configuration Requirements

### Binary Requirements
- **OpenVM Executable**: Must be mounted at `/dut/bin/dut-exe`
- **Execution Mode**: Compatible with RISCOF signature extraction
- **Dependencies**: All required OpenVM libraries and runtime

### Environment Setup
- **Plugin Directory**: Complete plugin configuration in `/dut/plugin`
- **ISA Configuration**: Properly configured ISA specification
- **Platform Settings**: OpenVM-compatible platform specification

## Usage Patterns

### Standard Execution
```bash
docker run --rm \
    -v "$PWD/plugins/openvm:/dut/plugin" \
    -v "/path/to/openvm/binary:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

### Custom Configuration
OpenVM supports various configuration options:
- **Module Selection**: Choose specific OpenVM modules
- **Performance Tuning**: Optimize for specific workloads
- **Memory Configuration**: Custom memory layouts

## Integration Considerations

### RISCOF Compatibility
- **Signature Format**: Must produce RISCOF-compatible signatures
- **Error Handling**: Graceful handling of OpenVM-specific errors
- **Performance**: Optimized for test suite execution

### Development Workflow
1. **Plugin Development**: Implement OpenVM-specific execution logic
2. **Testing**: Validate against RISC-V architectural tests
3. **Optimization**: Tune for OpenVM performance characteristics
4. **Documentation**: Maintain comprehensive usage documentation

## Expected Implementation Details

### Signature Extraction
```python
# Expected signature extraction pattern
simcmd = f'{self.dut_exe} --program {elf} --signature {sig_file}'
```

### Error Handling
```python
# Robust error handling for OpenVM
if not os.path.exists(self.dut_exe):
    logger.error(f"OpenVM executable not found: {self.dut_exe}")
    raise SystemExit(1)
```

### Performance Optimization
```python
# Parallel execution support
make.makeCommand = f'make -k -j{self.num_jobs}'
```

## Future Development

### Planned Features
1. **Extended ISA Support**: Additional RISC-V extensions
2. **Custom Instructions**: OpenVM-specific instruction support
3. **Performance Metrics**: Detailed execution profiling
4. **Module Integration**: Support for OpenVM module ecosystem

### Integration Roadmap
- **Phase 1**: Basic RISC-V compatibility
- **Phase 2**: OpenVM-specific optimizations
- **Phase 3**: Advanced feature support
- **Phase 4**: Performance and scalability enhancements

## Development Notes

### Implementation Status
The OpenVM plugin is currently in development. Key implementation considerations:

- **Binary Interface**: Define OpenVM command-line interface for testing
- **Signature Format**: Ensure compatibility with RISCOF expectations
- **Performance**: Optimize for test suite execution speed
- **Documentation**: Comprehensive usage and configuration documentation

### Technical Requirements
- **OpenVM Binary**: Executable with signature extraction support
- **Command Interface**: Standard command-line interface for test execution
- **Memory Model**: Compatible with RISC-V architectural test expectations
- **Error Reporting**: Clear error messages and debugging support

## Community and Support

### Resources
- **OpenVM Documentation**: Official OpenVM project documentation
- **RISC-V Specification**: RISC-V International architectural specifications
- **RISCOF Framework**: RISCOF testing framework documentation
- **Community Forums**: OpenVM and RISC-V community support channels

### Contributing
Contributions to the OpenVM plugin are welcome:
1. **Issues**: Report bugs and feature requests
2. **Pull Requests**: Submit improvements and fixes
3. **Documentation**: Enhance documentation and examples
4. **Testing**: Validate against different OpenVM configurations