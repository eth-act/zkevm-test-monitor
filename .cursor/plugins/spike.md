# Spike Plugin Documentation

## Overview

The Spike plugin integrates the Spike RISC-V ISA simulator into the RISCOF testing framework. Spike is the canonical RISC-V architectural simulator and serves as a reference implementation for RISC-V processor behavior.

## Plugin Implementation

### File: `plugins/spike/riscof_spike.py`

**Class**: `spike(pluginTemplate)`
**Model**: "spike"
**Purpose**: Reference RISC-V simulator for baseline comparison

### Key Features

- **Reference Implementation**: Canonical RISC-V simulator
- **Full ISA Support**: Comprehensive RISC-V instruction set support
- **Debugging Features**: Extensive debugging and tracing capabilities
- **Performance Reference**: Baseline for performance comparisons

## Configuration

### ISA Specification (`spike_isa.yaml`)
```yaml
hart_ids: [0]
hart0:
  ISA: RV32IMAFDC                # Full instruction set support
  physical_addr_sz: 32           # 32-bit address space
  User_Spec_Version: '2.3'       # RISC-V specification version
  supported_xlen: [32, 64]       # Both 32-bit and 64-bit support
  
  # Comprehensive ISA features
  misa:
    rv32:
      accessible: true
      mxl:
        implemented: true
        type:
          warl:
            legal: [0x1]         # 32-bit mode
    rv64:
      accessible: true
      mxl:
        implemented: true
        type:
          warl:
            legal: [0x2]         # 64-bit mode
```

### Platform Specification (`spike_platform.yaml`)
- Standard RISC-V platform configuration
- Memory layout compatible with Spike's memory model
- Device tree configuration for standard RISC-V features

## Implementation Details

### Plugin Architecture
```python
class spike(pluginTemplate):
    __model__ = "spike"
    
    def __init__(self, config):
        # Initialize Spike-specific configuration
        self.spike_exe = "spike"  # Spike simulator binary
        self.pk_exe = "pk"        # Proxy kernel for user mode
    
    def initialise(self, suite, work_dir, archtest_env):
        # Set up Spike execution environment
        self.compile_cmd = self._build_compile_command(archtest_env)
    
    def build(self, isa_yaml, platform_yaml):
        # Configure Spike for specific ISA
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.isa_string = self._build_isa_string(ispec)
    
    def runTests(self, testList):
        # Execute tests using Spike simulator
        self._execute_test_suite(testList)
```

### Compilation Process
- **Toolchain**: `riscv64-unknown-elf-gcc` or `riscv32-unknown-elf-gcc`
- **Target**: Full RISC-V ISA with all extensions
- **Linking**: Standard RISC-V linking with newlib
- **Output**: ELF binaries compatible with Spike

### Execution Model
Spike execution involves multiple modes:

#### Bare Metal Mode
```bash
spike --isa=rv32imac program.elf
```

#### Proxy Kernel Mode
```bash
spike pk program.elf
```

#### Machine Mode
```bash
spike --isa=rv32imac -m0x80000000:0x10000000 program.elf
```

## Spike-Specific Features

### ISA Extensions
Spike supports the full range of RISC-V extensions:
- **I**: Base integer instruction set
- **M**: Integer multiplication and division
- **A**: Atomic instructions
- **F**: Single-precision floating-point
- **D**: Double-precision floating-point
- **C**: Compressed instructions
- **V**: Vector instructions (newer versions)

### Debugging Capabilities
```bash
# Interactive debugging
spike -d --isa=rv32imac program.elf

# Instruction tracing
spike --log=trace.log --isa=rv32imac program.elf

# Memory tracing
spike --log-commits --isa=rv32imac program.elf
```

### Memory Model
- **Physical Memory**: Configurable memory regions
- **Virtual Memory**: Full MMU support with page tables
- **Device Memory**: Memory-mapped I/O simulation

## Configuration Examples

### Basic RV32I Configuration
```python
def build_rv32i_config(self):
    return {
        'isa': 'rv32i',
        'memory_base': '0x80000000',
        'memory_size': '0x10000000'
    }
```

### Extended RV32IMAFDC Configuration
```python
def build_rv32_full_config(self):
    return {
        'isa': 'rv32imafdc',
        'memory_base': '0x80000000',
        'memory_size': '0x40000000',
        'extensions': ['zicsr', 'zifencei']
    }
```

### RV64 Configuration
```python
def build_rv64_config(self):
    return {
        'isa': 'rv64imafdc',
        'memory_base': '0x80000000',
        'memory_size': '0x100000000',
        'xlen': 64
    }
```

## Signature Extraction

### Spike Signature Mechanism
Spike uses memory-mapped signature regions:

```c
// Signature start marker
#define SIGNATURE_START 0x80001000

// Write signature data
void write_signature(uint32_t data) {
    *((volatile uint32_t*)SIGNATURE_START) = data;
}
```

### Extraction Process
1. **Memory Region**: Tests write to designated signature memory
2. **Spike Logging**: Capture memory writes to signature region
3. **Post-Processing**: Extract signature data from Spike logs
4. **File Output**: Generate RISCOF-compatible signature files

## Performance Characteristics

### Execution Speed
- **Instruction-Level**: Cycle-accurate simulation
- **Performance**: Moderate speed (reference, not optimized)
- **Scalability**: Single-threaded execution model

### Resource Usage
- **Memory**: Proportional to simulated memory size
- **CPU**: Single-core utilization
- **I/O**: Extensive logging capabilities

## Advanced Features

### Custom Instructions
Spike supports custom instruction extensions:
```cpp
// Example custom instruction implementation
WRITE_RD(sext_xlen(RS1 + insn.i_imm()));
```

### Plugin System
Spike's plugin architecture allows:
- **Custom Devices**: Memory-mapped device simulation
- **Instruction Extensions**: Custom instruction implementations
- **Debug Hooks**: Custom debugging and profiling

### Formal Verification
Spike serves as a reference for:
- **ISA Compliance**: Canonical instruction behavior
- **Architecture Validation**: Reference implementation behavior
- **Test Development**: Golden model for test creation

## Integration with RISCOF

### Reference Model Role
Spike typically serves as the reference model in RISCOF:
```ini
[RISCOF]
ReferencePlugin=spike
ReferencePluginPath=plugins/spike
```

### Comparison Baseline
- **Golden Signatures**: Spike generates reference signatures
- **Behavioral Standard**: Defines expected RISC-V behavior
- **Compliance Testing**: Validates other implementations against Spike

## Usage Examples

### Basic Test Execution
```bash
# Run architectural tests with Spike
docker run --rm \
    -v "$PWD/plugins/spike:/dut/plugin" \
    -v "/usr/local/bin:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

### Debug Mode Execution
```bash
# Run with Spike debugging enabled
spike -d --isa=rv32imac \
    --log=debug.log \
    program.elf
```

### Performance Profiling
```bash
# Profile instruction execution
spike --log-commits \
    --log=profile.log \
    --isa=rv32imac \
    program.elf
```

## Troubleshooting

### Common Issues

#### ISA Mismatch
```
Error: Illegal instruction
```
**Solution**: Verify ISA string matches compiled binary requirements

#### Memory Layout Problems
```
Error: Bad address
```
**Solution**: Check memory base and size configuration

#### Signature Extraction Failures
```
Warning: No signature data found
```
**Solution**: Verify signature memory region setup in tests

### Debug Strategies

#### Instruction Tracing
```bash
spike --log=trace.log --isa=rv32imac program.elf
```

#### Memory Analysis
```bash
spike --log-commits --log=memory.log program.elf
```

#### Interactive Debugging
```bash
spike -d --isa=rv32imac program.elf
(spike) reg 0  # Show register values
(spike) mem 0x80000000 # Show memory contents
```

## Development and Customization

### Building Spike
```bash
# Build Spike from source
git clone https://github.com/riscv/riscv-isa-sim.git
cd riscv-isa-sim
mkdir build && cd build
../configure --prefix=/opt/riscv
make -j$(nproc)
make install
```

### Custom Extensions
```cpp
// Custom instruction example
class custom_insn_t : public insn_t {
public:
    custom_insn_t(uint32_t bits) : insn_t(bits) {}
    void execute(processor_t* p, insn_t insn, reg_t pc);
};
```

### Plugin Development
```cpp
// Custom device plugin
class custom_device_t : public abstract_device_t {
public:
    bool load(reg_t addr, size_t len, uint8_t* bytes) override;
    bool store(reg_t addr, size_t len, const uint8_t* bytes) override;
};
```

## Future Enhancements

### Planned Improvements
1. **Vector Extension**: Full RVV support
2. **Hypervisor Extension**: H-extension implementation
3. **Performance**: Multi-threading and optimization
4. **Debugging**: Enhanced debugging capabilities

### Integration Roadmap
- **Phase 1**: Complete RV32/RV64 support
- **Phase 2**: Vector and hypervisor extensions
- **Phase 3**: Performance optimizations
- **Phase 4**: Advanced debugging and profiling tools