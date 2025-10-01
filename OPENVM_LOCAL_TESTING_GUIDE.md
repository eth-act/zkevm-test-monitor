# Guide: Execute Tests Using a Local Copy of OpenVM

This guide explains how to run RISC-V compliance tests on OpenVM using a local copy of the OpenVM repository instead of building from a remote repository.

## Prerequisites

- Docker installed and running
- Local clone of OpenVM repository
- Bash shell
- jq (for JSON processing)

## Overview

The zkevm-test-monitor normally builds OpenVM from a remote GitHub repository. To use a local copy instead, you need to:

1. Build the OpenVM binary locally
2. Copy it to the binaries directory
3. Run tests using the existing RISCOF infrastructure

## Method 1: Using Docker with Local Repository

### Step 1: Modify config.json (Optional)

If you want to track which commit you're testing:

```bash
# Update the commit hash to match your local OpenVM version
jq '.zkvms.openvm.commit = "your-commit-hash"' config.json > config.tmp && mv config.tmp config.json
```

### Step 2: Build OpenVM Binary Locally

In your local OpenVM repository:

```bash
cd /path/to/your/local/openvm
cargo build --release
```

This produces the binary at: `target/release/cargo-openvm`

### Step 3: Copy Binary to Test Monitor

```bash
# From your OpenVM repository
cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary

# Make it executable
chmod +x /path/to/zkevm-test-monitor/binaries/openvm-binary
```

### Step 4: Record the Commit Hash

```bash
cd /path/to/zkevm-test-monitor
mkdir -p data/commits
cd /path/to/your/local/openvm
git rev-parse HEAD > /path/to/zkevm-test-monitor/data/commits/openvm.txt
```

### Step 5: Run Tests

```bash
cd /path/to/zkevm-test-monitor

# Run architecture compliance tests
./run test --arch openvm

# Or run extra differential tests
./run test --extra openvm
```

## Method 2: Build Using Modified Dockerfile with Local Path

### Step 1: Create a Modified Dockerfile

Create `docker/build-openvm/Dockerfile.local`:

```dockerfile
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /workspace

# Copy local OpenVM repository
COPY /path/to/your/local/openvm /workspace/openvm

WORKDIR /workspace/openvm
RUN cargo build --release

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/openvm/target/release/cargo-openvm /usr/local/bin/cargo-openvm

ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/cargo-openvm /output/cargo-openvm"]
```

### Step 2: Build Using Modified Dockerfile

```bash
cd /path/to/zkevm-test-monitor

docker build \
  -f docker/build-openvm/Dockerfile.local \
  -t zkvm-openvm:latest \
  .

# Extract binary
mkdir -p binaries
docker run --rm --user $(id -u):$(id -g) -v "$PWD/binaries:/output" zkvm-openvm:latest
mv binaries/cargo-openvm binaries/openvm-binary
```

## Method 3: Quick One-Command Test

For rapid iteration during development:

```bash
# Build and copy in one command from OpenVM repository
cd /path/to/your/local/openvm && \
  cargo build --release && \
  cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary && \
  cd /path/to/zkevm-test-monitor && \
  ./run test --arch openvm
```

## Understanding the Test Execution

### What Happens During Testing

1. **RISCOF Docker Build**: The test runner builds a RISCOF Docker image from `riscof/Dockerfile`
2. **Test Execution**: Docker runs with mounted volumes:
   - Your OpenVM binary: `/dut/bin/dut-exe`
   - OpenVM plugin: `/dut/plugin` (from `riscof/plugins/openvm/`)
   - Results directory: `/riscof/riscof_work`
   - Extra tests (if `--extra`): `/extra-tests`

3. **Plugin Execution**: The OpenVM plugin (`riscof/plugins/openvm/riscof_openvm.py`):
   - Compiles RISC-V test assembly files using `riscv64-unknown-elf-gcc`
   - Runs each test ELF using: `cargo-openvm openvm run --elf <test.elf> --signatures <sig-file>`
   - Compares signatures against the Sail reference model

### Test Suites Available

#### Architecture Tests (`--arch`)
- Official RISC-V Architecture Tests v3.9.1
- Located at: `riscof/riscv-arch-test/riscv-test-suite/`
- Tests basic ISA compliance (ADD, SUB, LOAD, STORE, etc.)

#### Extra Tests (`--extra`)
- Custom differential tests
- Located at: `extra-tests/`
- Tests edge cases, traps, and specific scenarios

### Test Results

Results are stored in:
- `test-results/openvm/report-arch.html` - Architecture test report
- `test-results/openvm/report-extra.html` - Extra test report
- `test-results/openvm/summary-arch.json` - Architecture test summary
- `test-results/openvm/summary-extra.json` - Extra test summary
- `data/history/openvm-arch.json` - Historical architecture test data
- `data/history/openvm-extra.json` - Historical extra test data

## Viewing Results

### Local Dashboard

```bash
./run serve
# Open http://localhost:8000
```

### Update Dashboard

```bash
./run update
```

This regenerates the HTML dashboard in `docs/` from the test results.

## Advanced: Debugging Test Failures

### Quick Debug Command (Recommended)

The fastest way to debug a failing test with full verbose output:

```bash
# After running tests, debug a specific failing test
./run debug openvm div-01

# Or with full path
./run debug openvm rv32i_m/M/div-01

# Debug extra tests
./run debug --extra openvm custom-test
```

This command:
- Finds the compiled test ELF from previous test run
- Re-runs it with `RUST_LOG=debug` and `RUST_BACKTRACE=full`
- Saves full output to `debug-output/{zkvm}/{test}_{timestamp}.log`
- Shows signature comparison with expected results
- No need to rebuild or re-run entire test suite

**Example output:**
```bash
$ ./run debug openvm div-01
🔍 Searching for test matching 'div-01' in arch suite...
✓ Found test: div-01.S
  ELF: test-results/openvm/rv32i_m/M/src/div-01.S/dut/my.elf

🐛 Running with verbose logging...
   Log output: debug-output/openvm/div-01.S_20250930_120000.log

[DEBUG openvm::runtime] Starting execution...
[DEBUG openvm::runtime] PC: 0x80000000
... (full verbose output) ...

✅ Test completed successfully
📝 Full log saved to: debug-output/openvm/div-01.S_20250930_120000.log
```

### Examine Individual Test Results

```bash
# Find a failing test in the results
cd test-results/openvm/

# Look at the signature comparison
cat <test-name>/<test-name>.cgf

# Check the OpenVM output
cat <test-name>/DUT-openvm.signature

# Compare with reference
cat <test-name>/Reference-sail_cSim.signature

# Check brief log from RISCOF run
cat <test-name>/openvm.log
```

### Run RISCOF Manually (Advanced)

For deeper RISCOF debugging:

```bash
# Build RISCOF Docker image
cd riscof
docker build -t riscof:latest .

# Run with interactive shell
docker run --rm -it \
  -e "TEST_SUITE=arch" \
  -v "$PWD/../binaries/openvm-binary:/dut/bin/dut-exe" \
  -v "$PWD/plugins/openvm:/dut/plugin" \
  -v "$PWD/../test-results/openvm:/riscof/riscof_work" \
  riscof:latest /bin/bash

# Inside container, run tests manually
riscof run --config=/riscof/config.ini \
  --suite=/riscof/riscv-arch-test/riscv-test-suite/ \
  --env=/riscof/riscv-arch-test/riscv-test-suite/env \
  --no-clean
```

### Modify Plugin Behavior

Edit `riscof/plugins/openvm/riscof_openvm.py`:

```python
# Line 158: Add debug output
simcmd = 'touch openvm.toml; ({0} openvm run --elf {1} --signatures {2} || echo "PANIC" > {2}) 2>&1 | tee openvm.log'.format(
    self.dut_exe, elf, sig_file)
```

## Troubleshooting

### Binary Not Found

**Error**: `⚠️ No binary found, skipping`

**Solution**:
```bash
# Ensure binary is named correctly
ls -la binaries/openvm-binary

# If missing, rebuild from local OpenVM
cd /path/to/openvm
cargo build --release
cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary
```

### Permission Denied

**Error**: Permission errors when running Docker

**Solution**:
```bash
chmod +x binaries/openvm-binary
# Or ensure Docker runs with correct user permissions
```

### OpenVM Panics on Tests

**Error**: Tests show "PANIC" in signature files

**Solution**:
- Check `test-results/openvm/<test-name>/openvm.log` for error details
- The plugin catches panics and creates signature files with "PANIC"
- Debug the specific test by running OpenVM manually with the test ELF

### Plugin Not Found

**Error**: `⚠️ No plugin found at riscof/plugins/openvm`

**Solution**:
```bash
# Verify plugin exists
ls -la riscof/plugins/openvm/

# Should contain:
# - riscof_openvm.py
# - openvm_isa.yaml
# - openvm_platform.yaml
# - env/link.ld
# - env/model_test.h
```

## Iteration Workflow for Development

When actively developing OpenVM features:

```bash
# 1. Make changes to OpenVM source
cd /path/to/openvm
# ... edit code ...

# 2. Build, test, view results in one go
cargo build --release && \
  cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary && \
  cd /path/to/zkevm-test-monitor && \
  ./run test --arch openvm && \
  ./run serve

# 3. Open browser to http://localhost:8000 to see results

# 4. For debugging specific failures, use debug command
cd /path/to/zkevm-test-monitor
./run debug openvm <failing-test-name>
```

### Fast Debug-Fix-Retest Loop

When debugging a specific test failure:

```bash
# 1. Identify failing test from dashboard or test output
./run test --arch openvm
# Shows: "div-01 FAILED"

# 2. Debug with full verbose output
./run debug openvm div-01
# Shows full stack trace and execution log

# 3. Fix the issue in OpenVM source
cd /path/to/openvm
# ... make fixes ...

# 4. Rebuild and retest just that one test
cargo build --release && \
  cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary && \
  cd /path/to/zkevm-test-monitor && \
  ./run debug openvm div-01

# Repeat 3-4 until test passes
```

This workflow is much faster than re-running the entire test suite each time.

## Configuration Files Reference

### OpenVM ISA Configuration

File: `riscof/plugins/openvm/openvm_isa.yaml`

Defines which RISC-V extensions OpenVM supports for testing.

### OpenVM Platform Configuration

File: `riscof/plugins/openvm/openvm_platform.yaml`

Defines platform-specific details like memory regions.

### Test Execution Plugin

File: `riscof/plugins/openvm/riscof_openvm.py`

Python plugin that:
- Compiles test assembly to ELF
- Executes tests using `cargo-openvm openvm run --elf`
- Extracts signatures for comparison

## Summary

To test a local OpenVM build:

1. **Build locally**: `cd openvm && cargo build --release`
2. **Copy binary**: `cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary`
3. **Run tests**: `cd /path/to/zkevm-test-monitor && ./run test --arch openvm`
4. **View results**: `./run serve` and open http://localhost:8000

This workflow bypasses the Docker-based remote repository build and uses your local OpenVM development copy directly.
