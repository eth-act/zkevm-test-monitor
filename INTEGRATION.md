# ZKVM Integration Guide

This guide explains how to add a new ZKVM implementation to the test monitor.

## Overview

To integrate a new ZKVM, you need to:
1. Capture signature output from the ZKVM
2. Create a RISCOF plugin 
3. Build a Docker container for the ZKVM
4. Configure and test the integration

---

## 1. Signature Capture

*[This section will be provided separately]*

The ZKVM must be able to output signature data to a file after executing RISC-V programs. This typically involves modifying the ZKVM to dump register and memory state at specific points.

### Quick Check for Existing Signature Support

Many ZKVMs already have signature output for testing. Look for:

```bash
# Search for signature-related code
grep -r "signature\|begin_signature\|end_signature" <zkvm-repo>

# Look for memory dump functionality
grep -r "dump_memory\|write_mem\|tohost" <zkvm-repo>

# Check for existing RISC-V compliance test support
find <zkvm-repo> -name "*compliance*" -o -name "*signature*"
```

If signature output exists, you may only need to adapt the output format.

---

## 2. Plugin Definition

The RISCOF plugin defines how to compile and run tests on your ZKVM. Create a plugin in `riscof/plugins/<zkvm>/`.

### Check for Existing RISC-V Test Infrastructure

Before creating a plugin from scratch, search the ZKVM's repository for existing RISC-V test components that can be reused.

**Quick test**: Many ZKVMs already run standard RISC-V tests:
```bash
# Check if ZKVM mentions riscv-tests or compliance
grep -r "riscv-tests\|riscv_tests\|compliance\|torture" <zkvm-repo>

# Look for test binaries
find <zkvm-repo> -name "*.elf" -o -name "*.bin" | grep -i test
```

**Detailed search for reusable components:**

**What to look for:**

1. **Environment folders** (`env/`, `riscv-tests/`, `compliance/`):
   ```bash
   find <zkvm-repo> -type d -name "env" -o -name "*riscv*test*"
   ```

2. **Linker scripts** (`.ld` files):
   ```bash
   find <zkvm-repo> -name "*.ld" | grep -E "link|test|riscv"
   ```
   Common names: `link.ld`, `test.ld`, `riscv-tests.ld`

3. **Model test headers**:
   ```bash
   find <zkvm-repo> -name "model_test.h" -o -name "riscv_test.h" -o -name "encoding.h"
   ```

4. **Test runners that accept ELF files**:
   ```bash
   grep -r "\.elf" <zkvm-repo> --include="*.rs" --include="*.go" --include="*.c"
   grep -r "from_elf\|load_elf\|run_elf" <zkvm-repo>
   ```

5. **Existing test suites**:
   ```bash
   find <zkvm-repo> -path "*/testdata/*.elf" -o -path "*/tests/*.S"
   ```

**If you find existing infrastructure:**

- **Linker script**: Copy and adapt for RISCOF (check memory addresses)
- **model_test.h**: Often directly usable, may need minor adjustments
- **ELF loader**: Note the command-line interface for the plugin's `simcmd`
- **Test examples**: Study how the ZKVM expects tests to be structured

**Common adaptations needed:**

1. **Memory addresses**: RISCOF typically expects tests at `0x20000000` or `0x80000000`
2. **Entry point**: Must be `rvtest_entry_point` not `_start` or `main`
3. **Signature markers**: Need `begin_signature` and `end_signature` labels
4. **Halt mechanism**: May need to adapt from existing exit/halt code

**Example discovery in real ZKVMs:**

```bash
# SP1 example - found existing RISC-V tests
$ find sp1 -name "*.ld" 
sp1/crates/core/executor/src/riscv_tests/link.ld

# Risc0 example - found test infrastructure
$ find risc0 -name "model_test.h"
risc0/risc0/compliance/model_test.h

# OpenVM example - found ELF runner
$ grep -r "from_elf" openvm
openvm/crates/vm/src/lib.rs: Program::from_elf(bytes)
```

### Plugin Structure

```
riscof/plugins/<zkvm>/
├── riscof_<zkvm>.py      # Main plugin implementation
├── <zkvm>_isa.yaml       # ISA configuration
├── <zkvm>_platform.yaml  # Platform configuration
└── env/
    ├── link.ld           # Linker script
    └── model_test.h      # Test macros header
```

### ISA YAML Configuration

Define the RISC-V ISA features your ZKVM supports:

```yaml
hart_ids: [0]
hart0:
  ISA: RV32IM              # or RV32I, RV64IM, etc.
  physical_addr_sz: 32     # Address size
  User_Spec_Version: '2.3'
  supported_xlen: [32]     # or [64] for 64-bit
  misa:
    rv32:                  # or rv64
      accessible: true
      mxl:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              - mxl[1:0] in [0x1]  # 0x1 for RV32, 0x2 for RV64
            wr_illegal:
              - Unchanged
      extensions:
        implemented: true
        type:
          warl:
            dependency_fields: []
            legal:
              # Bitmask for extensions (I=0x100, M=0x1000)
              - extensions[25:0] bitmask [0x0001104, 0x0000000]
            wr_illegal:
              - Unchanged
```

### Platform YAML Configuration

Define platform-specific features (usually minimal for ZKVMs):

```yaml
mtime:
  implemented: false
  address: 0xbff8
mtimecmp:
  implemented: false
  address: 0x4000
nmi:
  label: nmi_vector
reset:
  label: reset_vector
```

### Main Plugin Python File

The plugin must inherit from `pluginTemplate` and implement three key methods:

```python
import os
import re
import shutil
import subprocess
import shlex
import logging
import random
import string
from string import Template
import sys

import riscof.utils as utils
from riscof.pluginTemplate import pluginTemplate
import riscof.constants as constants

logger = logging.getLogger()

class <zkvm>(pluginTemplate):
    __model__ = "<zkvm>"
    __version__ = "1.0"
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')
        
        # Get binary path from config
        self.dut_exe = os.path.join(os.path.abspath(config['PATH']), "dut-exe")
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        self.pluginpath = os.path.abspath(config['pluginpath'])
        
        # Setup compilation command with important flags
        self.compile_cmd = 'riscv{1}-unknown-elf-gcc -march={0} \
            -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g \
            -mno-relax \  # CRITICAL: Prevents compressed instructions
            -Wa,-march={0} \
            -T '+self.pluginpath+'/env/link.ld \
            -I '+self.pluginpath+'/env/ \
            -I ' + archtest_env + ' {2} -o {3} {4}'
    
    def build(self, isa_yaml, platform_yaml):
        """Setup compilation based on ISA configuration"""
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '64' if 64 in ispec['supported_xlen'] else '32'
        self.isa = ispec['ISA'].lower()
        
        # Set ABI based on XLEN
        if 64 in ispec['supported_xlen']:
            self.compile_cmd = self.compile_cmd + ' -mabi=lp64 '
        else:
            self.compile_cmd = self.compile_cmd + ' -mabi=ilp32 '
    
    def runTests(self, testList):
        """Compile and run each test"""
        # Create Makefile for parallel execution
        make = utils.makeUtil(makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
        make.makeCommand = 'make -k -j' + self.num_jobs
        
        for testentry in testList:
            test = testentry['test_path']
            elf = testentry['work_dir'] + '/' + testentry['name'] + '.elf'
            sig_file = os.path.join(testentry['work_dir'], self.name[:-1] + ".signature")
            
            # Compile test
            compile_macros = ' -D' + " -D".join(testentry['macros'])
            cmd = self.compile_cmd.format(
                testentry['isa'].lower(), 
                self.xlen, 
                test, 
                elf, 
                compile_macros
            )
            
            # Run test on ZKVM
            if self.target_run:
                # CUSTOMIZE THIS: How to run your ZKVM
                simcmd = '{0} --elf {1} --output {2} 2>&1 | tail -10 > <zkvm>.log'.format(
                    self.dut_exe, elf, sig_file
                )
            else:
                simcmd = 'echo "NO RUN"'
            
            # Add to Makefile
            execute = '@cd {0}; {1}; {2};'.format(testentry['work_dir'], cmd, simcmd)
            make.add_target(execute)
        
        # Execute all tests
        make.execute_all(self.work_dir)
```

### Key Compilation Flags

**Critical flags to prevent issues:**

- `-mno-relax`: **Essential** - Prevents linker relaxation that can introduce compressed instructions
- `-march={isa}`: Sets the target ISA (e.g., rv32im, rv64im)
- `-mabi={abi}`: Sets the ABI (ilp32 for RV32, lp64 for RV64)
- `-static`: Static linking required for most ZKVMs
- `-nostdlib -nostartfiles`: No standard libraries
- `-mcmodel=medany`: Medium code model for addressing

### Test Macros Header (env/model_test.h)

Define ZKVM-specific test behavior:

```c
#ifndef _RISCV_MODEL_TEST_H
#define _RISCV_MODEL_TEST_H

#define __riscv_xlen 32  // or 64 for RV64
#define TESTNUM x31

// Disable identity mapping if not needed
#define RVTEST_NO_IDENTY_MAP

// Define how to assert register values (usually empty for ZKVMs)
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_BOOT

// Define halt mechanism (customize for your ZKVM)
#define RVMODEL_HALT                      \
  li t0, 0;     /* Status code */        \
  li a7, 0;     /* System call number */ \
  ecall;        /* Trigger halt */

// Data section begin/end markers
#define RVMODEL_DATA_BEGIN \
  .align 4;                \
  .global begin_signature; \
  begin_signature:

#define RVMODEL_DATA_END \
  .align 4;              \
  .global end_signature; \
  end_signature:

#endif
```

### Linker Script (env/link.ld)

Standard memory layout for RISC-V tests:

```ld
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x20000000;           /* Start address - adjust if needed */
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .data.string : { *(.data.string)}
  .bss : { *(.bss) }
  _end = .;
}
```

### Execution Command Patterns

Different ZKVMs have different invocation patterns:

**Simple binary execution:**
```python
simcmd = '{0} --elf {1} --output {2}'.format(self.dut_exe, elf, sig_file)
```

**With stdin (SP1 pattern):**
```python
empty_stdin = os.path.realpath("empty_stdin.bin")
simcmd = '{0} --signatures {1} --program {2} --stdin {3}'.format(
    self.dut_exe, sig_file, elf, empty_stdin
)
```

**CLI tool wrapper (OpenVM pattern):**
```python
simcmd = '{0} openvm run --elf {1} --signatures {2}'.format(
    self.dut_exe, elf, sig_file
)
```

**With error handling:**
```python
simcmd = '({0} {1} {2} || echo "PANIC" > {2}) 2>&1 | tail -10 > zkvm.log'.format(
    self.dut_exe, elf, sig_file
)
```

### Testing Your Plugin

1. **Verify plugin structure:**
   ```bash
   ls -la riscof/plugins/<zkvm>/
   ```

2. **Test compilation:**
   ```bash
   # The plugin will compile tests using riscv-unknown-elf-gcc
   # Ensure the toolchain is installed
   ```

3. **Run minimal test:**
   ```bash
   ./run test <zkvm>
   ```

### Common Plugin Issues

**Issue: Compressed instructions appearing**
- Solution: Always use `-mno-relax` flag
- Check: Disassemble ELF to verify no C extension instructions

**Issue: Wrong entry point**
- Solution: Ensure linker script has `ENTRY(rvtest_entry_point)`

**Issue: Signatures not captured**
- Solution: Verify ZKVM outputs to the correct file path
- Debug: Check `<zkvm>.log` in test directories

**Issue: Tests timeout**
- Solution: Add timeout handling in execution command
- Consider: Some tests may legitimately take longer

---

## 3. Build Container

Each ZKVM needs a Docker container that builds the binary and makes it available for testing.

### Directory Structure
Create a new Dockerfile at:
```
docker/build-<zkvm>/Dockerfile
```

### Dockerfile Template

```dockerfile
# <ZKVM> Builder
FROM ubuntu:24.04 AS builder

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust (if needed)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /workspace

# Clone and checkout specific commit
ARG REPO_URL=https://github.com/<org>/<zkvm>
ARG COMMIT_HASH=main
RUN git clone "$REPO_URL" <zkvm> && \
    cd <zkvm> && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Build the ZKVM
WORKDIR /workspace/<zkvm>
RUN cargo build --release --bin <binary-name>

# Runtime stage
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy binary and commit info
COPY --from=builder /workspace/<zkvm>/target/release/<binary-name> /usr/local/bin/<zkvm>-binary
COPY --from=builder /workspace/commit.txt /commit.txt

# Entrypoint to extract binary
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/<zkvm>-binary /output/<zkvm>-binary"]
```

### Key Points

1. **Multi-stage build**: Use builder stage for compilation, runtime stage for minimal image
2. **Commit tracking**: Save git commit hash to `/commit.txt` for version tracking
3. **Dependencies**: Include all build dependencies in builder, only runtime deps in final stage
4. **Binary naming**: Ensure the output binary follows the `<zkvm>-binary` convention

### Examples

See existing Dockerfiles for reference:
- `docker/build-sp1/Dockerfile` - Simple Rust build
- `docker/build-zisk/Dockerfile` - Complex with many crypto dependencies  
- `docker/build-risc0/Dockerfile` - Uses build caching for faster rebuilds

---

## 4. Test Execution

### Configuration

Add your ZKVM to `config.json`:

```json
{
  "zkvms": {
    "your-zkvm": {
      "repo_url": "https://github.com/<org>/<repo>",
      "commit": "<commit-hash-or-branch>",
      "build_cmd": "cargo build --release --bin <binary>",
      "binary_name": "<binary>",
      "binary_path": "target/release/<binary>"
    }
  }
}
```

### Build Script Integration

The build script (`scripts/build.sh`) will automatically:
1. Use your Dockerfile if it exists at `docker/build-<zkvm>/Dockerfile`
2. Build the Docker image with your repo URL and commit
3. Extract the binary to `binaries/<zkvm>-binary`
4. Capture the actual git commit for tracking

### Test Script Integration

The test script (`scripts/test.sh`) will:
1. Check for binary at `binaries/<zkvm>-binary`
2. Look for RISCOF plugin at `riscof/plugins/<zkvm>/`
3. Mount binary and plugin into RISCOF container
4. Run tests and generate reports
5. Parse results from HTML report

### Binary Naming Edge Cases

If your ZKVM binary has a different name than expected, add special handling in `scripts/build.sh`:

```bash
# Handle special cases for binary naming
if [ "$ZKVM" = "your-zkvm" ] && [ -f "binaries/actual-name" ]; then
    mv "binaries/actual-name" "binaries/your-zkvm-binary"
fi
```

### Testing Your Integration

```bash
# Build your ZKVM
./run build your-zkvm

# Verify binary exists
ls -la binaries/your-zkvm-binary

# Run RISCOF tests (requires plugin)
./run test your-zkvm

# Check results
./run serve
# Open http://localhost:8000
```

### Debugging Tips

1. **Build failures**: Check Docker build logs for missing dependencies
2. **Binary not found**: Verify the binary path in your Dockerfile's ENTRYPOINT
3. **Tests not running**: Ensure plugin exists at `riscof/plugins/<zkvm>/`
4. **No results**: Check `test-results/<zkvm>/` for error logs

---

## 5. Common Issues and Solutions

### Issue: ZKVM requires specific Rust version
**Solution**: Use `rustup` to install the exact version in your Dockerfile:
```dockerfile
RUN rustup toolchain install 1.75.0
RUN rustup default 1.75.0
```

### Issue: Complex build dependencies
**Solution**: See `docker/build-zisk/Dockerfile` for an example with many dependencies

### Issue: Binary needs wrapper script
**Solution**: Some ZKVMs (like OpenVM) use `cargo-<zkvm>` as a CLI tool. Ensure your plugin knows how to invoke it correctly.

### Issue: Large Docker images
**Solution**: Use multi-stage builds and only copy the final binary to the runtime stage

---

## Next Steps

After integration:
1. Run full test suite: `./run test your-zkvm`
2. Update dashboard: `./run update`
3. Commit and push changes
4. Verify deployment at https://codygunton.github.io/zkevm-test-monitor/