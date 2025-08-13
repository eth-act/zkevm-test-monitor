# Development Guide

## Overview

This guide provides comprehensive information for developers working with the ZKEVM Test Monitor, including development workflows, best practices, and guidelines for extending the system.

## Development Environment Setup

### Prerequisites
- **Docker**: Container runtime for isolated development
- **Git**: Version control for source management
- **Text Editor**: VS Code, vim, or preferred development environment
- **RISC-V Knowledge**: Understanding of RISC-V ISA and testing concepts

### Local Development Setup
```bash
# Clone the repository
git clone <repository-url>
cd zkevm-test-monitor

# Build the Docker image
docker build -t riscof:latest .

# Set up development volumes
mkdir -p results
```

### Development Container
For active development, use an interactive container:
```bash
docker run -it --rm \
    -v "$PWD:/workspace" \
    -v "$PWD/results:/riscof/riscof_work" \
    --workdir /workspace \
    riscof:latest /bin/bash
```

## Project Structure

### Core Components
```
zkevm-test-monitor/
├── Dockerfile              # Container definition
├── entrypoint.sh           # Dynamic configuration script
├── README.md               # Project documentation
├── plugins/                # ZKVM plugin implementations
│   ├── sp1/               # SP1 zkVM plugin
│   ├── jolt/              # Jolt zkVM plugin
│   ├── openvm/            # OpenVM plugin
│   ├── spike/             # Spike reference plugin
│   └── sail_cSim/         # Sail reference plugin
├── results/               # Test execution results
├── ai_docs/               # AI assistant documentation
└── riscof/                # RISCOF framework integration
```

### Plugin Structure Template
```
plugins/<zkvm_name>/
├── riscof_<zkvm_name>.py      # Main plugin implementation
├── <zkvm_name>_isa.yaml       # ISA specification
├── <zkvm_name>_platform.yaml # Platform specification
├── env/                       # Environment files
│   └── link.ld               # Linker script
└── README.md                  # Plugin documentation
```

## Plugin Development

### Creating a New Plugin

#### 1. Plugin Class Implementation
Create `plugins/<zkvm_name>/riscof_<zkvm_name>.py`:

```python
import os
import logging
import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class <zkvm_name>(pluginTemplate):
    __model__ = "<zkvm_name>"
    __version__ = "1.0.0"
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        
        config = kwargs.get('config')
        if config is None:
            raise SystemExit("Configuration required")
        
        # Set up plugin configuration
        self.dut_exe = os.path.join(os.path.abspath(config['PATH']), "dut-exe")
        self.num_jobs = str(config.get('jobs', 1))
        self.pluginpath = os.path.abspath(config['pluginpath'])
        self.isa_spec = os.path.abspath(config['ispec'])
        self.platform_spec = os.path.abspath(config['pspec'])
        self.target_run = config.get('target_run', '1') != '0'
    
    def initialise(self, suite, work_dir, archtest_env):
        self.work_dir = work_dir
        self.suite_dir = suite
        self.archtest_env = archtest_env
        
        # Set up compilation command
        self.compile_cmd = 'riscv{1}-unknown-elf-gcc -march={0} \
            -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
            -T '+self.pluginpath+'/env/link.ld \
            -I '+self.pluginpath+'/env/ \
            -I ' + archtest_env + ' {2} -o {3} {4}'
    
    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        
        # Build ISA string
        self.isa = 'rv' + self.xlen
        for ext in ['I', 'M', 'F', 'D', 'C']:
            if ext in ispec["ISA"]:
                self.isa += ext.lower()
        
        # Set ABI
        abi = 'lp64' if 64 in ispec['supported_xlen'] else 'ilp32'
        self.compile_cmd += ' -mabi=' + abi
    
    def runTests(self, testList):
        # Implementation specific to your ZKVM
        # See existing plugins for examples
        pass
```

#### 2. ISA Specification
Create `plugins/<zkvm_name>/<zkvm_name>_isa.yaml`:

```yaml
hart_ids: [0]
hart0:
  ISA: RV32IM                    # Supported extensions
  physical_addr_sz: 32           # Address space
  User_Spec_Version: '2.3'       # RISC-V version
  supported_xlen: [32]           # Register width
  misa:
    rv32:
      accessible: true
      mxl:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal: [0x1]
            wr_illegal: [Unchanged]
      extensions:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal: [0x0001104, 0x0000000]  # I and M extensions
            wr_illegal: [Unchanged]
```

#### 3. Platform Specification
Create `plugins/<zkvm_name>/<zkvm_name>_platform.yaml`:

```yaml
# Platform-specific configuration
# Memory regions, device tree, etc.
```

#### 4. Environment Setup
Create `plugins/<zkvm_name>/env/link.ld`:

```ld
/* Linker script for RISC-V tests */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 0x10000000
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text)
    } > RAM
    
    .data : {
        *(.data)
    } > RAM
    
    .bss : {
        *(.bss)
    } > RAM
    
    .signature : {
        *(.signature)
    } > RAM
}
```

### Plugin Development Best Practices

#### Error Handling
```python
# Validate configuration
if not os.path.exists(self.dut_exe):
    logger.error(f"Executable not found: {self.dut_exe}")
    raise SystemExit(1)

# Graceful execution handling
simcmd = f'{self.dut_exe} {elf} > output.log 2>&1 || true'
```

#### Signature Extraction
```python
# Standard signature file naming
sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")

# ZKVM-specific signature extraction
simcmd = f'{self.dut_exe} --signature {sig_file} {elf}'
```

#### Parallel Execution
```python
# Use makeUtil for parallel test execution
make = utils.makeUtil(makefilePath=makefile_path)
make.makeCommand = f'make -k -j{self.num_jobs}'

for testname in testList:
    # Build execution command
    execute = f'@cd {test_dir}; {compile_cmd}; {sim_cmd}'
    make.add_target(execute)

make.execute_all(self.work_dir)
```

## Testing and Validation

### Plugin Testing
```bash
# Test plugin with minimal setup
docker run --rm \
    -v "$PWD/plugins/your_plugin:/dut/plugin" \
    -v "/path/to/your/zkvm:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

### Debug Mode
```bash
# Run with verbose output
docker run --rm \
    -v "$PWD/plugins/your_plugin:/dut/plugin" \
    -v "/path/to/your/zkvm:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest riscof run --config=/riscof/config.ini --verbose
```

### Validation Checklist
- [ ] Plugin class inherits from `pluginTemplate`
- [ ] All required methods implemented
- [ ] ISA specification matches ZKVM capabilities
- [ ] Compilation command generates valid ELF files
- [ ] Signature extraction works correctly
- [ ] Error handling for common failure cases
- [ ] Parallel execution support

## Code Quality Standards

### Python Coding Standards
- **PEP 8**: Follow Python style guidelines
- **Docstrings**: Document all classes and methods
- **Type Hints**: Use type annotations where applicable
- **Error Handling**: Comprehensive exception handling

### Example Function Documentation
```python
def runTests(self, testList: dict) -> None:
    """
    Execute the test suite on the ZKVM.
    
    Args:
        testList: Dictionary of test configurations
        
    Raises:
        SystemExit: If critical errors occur during execution
    """
    pass
```

### Configuration Management
```python
# Use configuration with defaults
self.num_jobs = str(config.get('jobs', 1))
self.target_run = config.get('target_run', '1') != '0'

# Validate required configuration
required_keys = ['PATH', 'pluginpath', 'ispec', 'pspec']
for key in required_keys:
    if key not in config:
        raise SystemExit(f"Missing required config: {key}")
```

## Performance Optimization

### Compilation Optimization
- **Parallel Jobs**: Use appropriate job count for system
- **Incremental Builds**: Avoid unnecessary recompilation
- **Resource Management**: Monitor memory and CPU usage

### Execution Optimization
```python
# Efficient signature handling
if self.target_run:
    simcmd = f'{self.dut_exe} {elf} --signature {sig_file}'
else:
    # Skip execution, create placeholder
    simcmd = f'echo "# Compilation only" > {sig_file}'
```

### Debug Information
```python
# Conditional debug output
if logger.isEnabledFor(logging.DEBUG):
    logger.debug(f"Executing: {simcmd}")
```

## CI/CD Integration

### Automated Testing
```yaml
# Example GitHub Actions workflow
name: ZKVM Test Suite
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    - name: Build Docker Image
      run: docker build -t riscof:latest .
    - name: Run Tests
      run: |
        docker run --rm \
          -v "$PWD/plugins/test_plugin:/dut/plugin" \
          -v "$PWD/test_binaries:/dut/bin" \
          -v "$PWD/results:/riscof/riscof_work" \
          riscof:latest
```

### Quality Gates
- **Build Success**: Docker image builds without errors
- **Test Execution**: All tests complete successfully
- **Coverage**: Adequate test coverage for new features
- **Documentation**: Updated documentation for changes

## Troubleshooting Guide

### Common Issues

#### Plugin Not Found
```
Error: No riscof_*.py file found in /dut/plugin
```
**Solution**: Ensure plugin file follows naming convention `riscof_<name>.py`

#### Compilation Errors
```
error: unknown target 'rv32im'
```
**Solution**: Check ISA string generation in `build()` method

#### Signature Mismatch
```
Test failed: signature comparison failed
```
**Solution**: Verify signature extraction format and memory layout

#### Permission Errors
```
Error: jolt-emu at /dut/bin/dut-exe is not executable
```
**Solution**: Check binary permissions and mount configuration

### Debug Strategies

#### Enable Verbose Logging
```python
import logging
logging.basicConfig(level=logging.DEBUG)
```

#### Examine Test Artifacts
```bash
# Check individual test results
ls results/<test_name>/
cat results/<test_name>/test.log
```

#### Compare Signatures Manually
```bash
# Examine signature differences
diff results/<test_name>/dut.signature results/<test_name>/ref.signature
```

## Contributing Guidelines

### Pull Request Process
1. **Feature Branch**: Create branch from main
2. **Implementation**: Develop feature with tests
3. **Documentation**: Update relevant documentation
4. **Testing**: Verify all tests pass
5. **Review**: Submit pull request for review

### Code Review Checklist
- [ ] Code follows project standards
- [ ] Tests cover new functionality
- [ ] Documentation is updated
- [ ] No breaking changes (or properly documented)
- [ ] Performance implications considered

### Release Process
1. **Version Bump**: Update version numbers
2. **Changelog**: Document changes
3. **Testing**: Full regression testing
4. **Tagging**: Create release tag
5. **Documentation**: Update deployment guides

## Future Development

### Planned Enhancements
- **Extended ISA Support**: Additional RISC-V extensions
- **Performance Metrics**: Execution timing and resource usage
- **Custom Test Suites**: Support for domain-specific tests
- **Formal Verification**: Integration with formal methods

### Architecture Evolution
- **Microservices**: Split into smaller, focused services
- **API Layer**: REST API for programmatic access
- **Web Interface**: Browser-based test management
- **Cloud Integration**: Support for cloud-based testing