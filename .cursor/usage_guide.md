# Usage Guide

## Quick Start

### Prerequisites
- Docker installed and running
- ZKVM binary (SP1, Jolt, OpenVM, etc.)
- Basic understanding of RISC-V and zero-knowledge proofs

### Basic Usage
```bash
# 1. Build the container
docker build -t riscof:latest .

# 2. Run tests with your ZKVM
docker run --rm \
    -v "$PWD/plugins/<zkvm-name>:/dut/plugin" \
    -v "/path/to/zkvm/binary:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest

# 3. View results
open results/report.html
```

## Supported ZKVMs

### SP1 (Succinct)
```bash
# Example: Testing SP1
docker run --rm \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    -v "/path/to/sp1-binary:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

**Requirements:**
- SP1 binary with signature extraction support
- RV32IM compatibility
- Custom stdin handling

### Jolt
```bash
# Example: Testing Jolt
docker run --rm \
    -v "$PWD/plugins/jolt:/dut/plugin" \
    -v "/path/to/jolt-emu:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

**Requirements:**
- jolt-emu executable
- Signature extraction with 4-byte granularity
- RV32IM support

### OpenVM
```bash
# Example: Testing OpenVM
docker run --rm \
    -v "$PWD/plugins/openvm:/dut/plugin" \
    -v "/path/to/openvm:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

**Requirements:**
- OpenVM executable with RISCOF compatibility
- Modular architecture support
- Standard signature extraction

## Configuration Options

### Volume Mounts

#### Required Mounts
- **`/dut/plugin`**: Plugin configuration directory
- **`/dut/bin`**: ZKVM executable directory
- **`/riscof/riscof_work`**: Test results output

#### Optional Mounts
- **`/workspace`**: Development workspace for debugging
- **`/custom-tests`**: Custom test suite directory

### Environment Variables
```bash
# Set parallelization level
docker run --rm \
    -e RISCOF_JOBS=24 \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    -v "/path/to/sp1:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest

# Enable debug mode
docker run --rm \
    -e RISCOF_DEBUG=1 \
    -v "$PWD/plugins/jolt:/dut/plugin" \
    -v "/path/to/jolt:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

## Advanced Usage

### Interactive Development
```bash
# Interactive shell for debugging
docker run -it --rm \
    -v "$PWD:/workspace" \
    -v "$PWD/results:/riscof/riscof_work" \
    --workdir /workspace \
    riscof:latest /bin/bash

# Inside container:
# Manually configure and run tests
cd /riscof
riscof run --config=config.ini --suite=riscv-arch-test/riscv-test-suite/
```

### Custom Test Suites
```bash
# Run specific test categories
docker run --rm \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    -v "/path/to/sp1:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    -v "$PWD/custom-tests:/custom-tests" \
    riscof:latest riscof run --suite=/custom-tests
```

### Performance Tuning
```bash
# Optimize for available CPU cores
CPU_CORES=$(nproc)
docker run --rm \
    --cpus="$CPU_CORES" \
    -v "$PWD/plugins/jolt:/dut/plugin" \
    -v "/path/to/jolt:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

## Result Analysis

### Report Structure
```
results/
├── report.html              # Main test report
├── database/                # Test database
├── <test-name>/             # Individual test results
│   ├── test.elf            # Compiled test binary
│   ├── dut.signature       # DUT signature
│   ├── ref.signature       # Reference signature
│   ├── test.log            # Execution log
│   └── Makefile           # Build artifacts
└── work/                   # Working files
```

### Understanding Results

#### Pass/Fail Status
- **PASS**: Signatures match between DUT and reference
- **FAIL**: Signature mismatch detected
- **ERROR**: Compilation or execution error

#### Signature Analysis
```bash
# Compare signatures manually
diff results/rv32i-add-01/dut.signature results/rv32i-add-01/ref.signature

# Analyze signature format
hexdump -C results/rv32i-add-01/dut.signature
```

#### Log Analysis
```bash
# Check execution logs
cat results/rv32i-add-01/test.log

# Look for specific errors
grep -i error results/*/test.log
```

## Troubleshooting

### Common Issues

#### Binary Not Found
```
Error: No DUT binary found. Please mount a directory containing the DUT executable to /dut/bin
```

**Solution:**
```bash
# Ensure binary is mounted correctly
ls /path/to/zkvm/binary/  # Should contain executable
docker run --rm \
    -v "/path/to/zkvm/binary:/dut/bin" \
    ...
```

#### Plugin Not Detected
```
Error: No riscof_*.py file found in /dut/plugin
```

**Solution:**
```bash
# Verify plugin directory structure
ls plugins/sp1/  # Should contain riscof_sp1.py
docker run --rm \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    ...
```

#### Compilation Failures
```
error: unknown target 'rv32im'
```

**Solutions:**
1. Check ISA specification in plugin YAML files
2. Verify RISC-V toolchain installation
3. Review compilation flags in plugin implementation

#### Signature Mismatches
```
Test failed: signature comparison failed
```

**Debug Steps:**
1. Check execution logs for runtime errors
2. Verify signature extraction implementation
3. Compare memory layouts between DUT and reference
4. Review test-specific requirements

### Debug Mode

#### Verbose Execution
```bash
# Run with detailed logging
docker run --rm \
    -v "$PWD/plugins/sp1:/dut/plugin" \
    -v "/path/to/sp1:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest riscof run --verbose --config=/riscof/config.ini
```

#### Manual Test Execution
```bash
# Run individual tests manually
docker exec -it <container> /bin/bash
cd /riscof/riscof_work
make -f Makefile.sp1 TARGET0  # Run specific test
```

#### Plugin Development
```bash
# Test plugin in isolation
docker run -it --rm \
    -v "$PWD/plugins/new_plugin:/dut/plugin" \
    -v "/path/to/binary:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest /bin/bash

# Inside container, test plugin loading
python3 -c "
import sys
sys.path.append('/riscof/plugins/new_plugin')
from riscof_new_plugin import new_plugin
print('Plugin loaded successfully')
"
```

## Best Practices

### Performance Optimization
1. **Parallel Execution**: Use appropriate job count for your system
2. **Resource Limits**: Set Docker CPU and memory limits
3. **SSD Storage**: Use fast storage for results directory
4. **Clean Builds**: Remove old results between runs

### Development Workflow
1. **Version Control**: Track plugin changes with git
2. **Iterative Testing**: Test with small test subsets first
3. **Documentation**: Document plugin-specific requirements
4. **Validation**: Cross-verify results with multiple ZKVMs

### CI/CD Integration
```yaml
# Example GitHub Actions workflow
name: ZKVM Compliance Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        zkvm: [sp1, jolt, openvm]
    
    steps:
    - uses: actions/checkout@v2
    
    - name: Build Test Container
      run: docker build -t riscof:latest .
    
    - name: Run Compliance Tests
      run: |
        docker run --rm \
          -v "$PWD/plugins/${{ matrix.zkvm }}:/dut/plugin" \
          -v "$PWD/test-binaries/${{ matrix.zkvm }}:/dut/bin" \
          -v "$PWD/results:/riscof/riscof_work" \
          riscof:latest
    
    - name: Upload Results
      uses: actions/upload-artifact@v2
      with:
        name: test-results-${{ matrix.zkvm }}
        path: results/
```

## Integration Examples

### Continuous Testing
```bash
#!/bin/bash
# Automated testing script

ZKVMS=("sp1" "jolt" "openvm")
RESULTS_DIR="$(date +%Y%m%d_%H%M%S)_results"

for zkvm in "${ZKVMS[@]}"; do
    echo "Testing $zkvm..."
    
    docker run --rm \
        -v "$PWD/plugins/$zkvm:/dut/plugin" \
        -v "$PWD/binaries/$zkvm:/dut/bin" \
        -v "$PWD/$RESULTS_DIR/$zkvm:/riscof/riscof_work" \
        riscof:latest
    
    if [ $? -eq 0 ]; then
        echo "$zkvm: PASS"
    else
        echo "$zkvm: FAIL"
    fi
done
```

### Performance Benchmarking
```bash
#!/bin/bash
# Performance comparison script

echo "ZKVM,Test Count,Pass Rate,Execution Time" > benchmark_results.csv

for zkvm in sp1 jolt openvm; do
    start_time=$(date +%s)
    
    docker run --rm \
        -v "$PWD/plugins/$zkvm:/dut/plugin" \
        -v "$PWD/binaries/$zkvm:/dut/bin" \
        -v "$PWD/results:/riscof/riscof_work" \
        riscof:latest > /dev/null 2>&1
    
    end_time=$(date +%s)
    execution_time=$((end_time - start_time))
    
    # Parse results
    total_tests=$(grep -c "Test:" results/report.html)
    passed_tests=$(grep -c "PASS" results/report.html)
    pass_rate=$(echo "scale=2; $passed_tests * 100 / $total_tests" | bc)
    
    echo "$zkvm,$total_tests,$pass_rate%,${execution_time}s" >> benchmark_results.csv
done
```

This comprehensive usage guide provides everything needed to effectively use the ZKEVM Test Monitor for validating ZKVM implementations against the RISC-V architectural test suite.