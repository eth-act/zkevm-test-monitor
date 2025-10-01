# Debug Workflow Guide

Quick reference for debugging individual test failures with verbose logging.

## Usage

```bash
./run debug [--arch|--extra] <zkvm> <test-pattern>
```

## Examples

```bash
# Debug a specific test
./run debug openvm div-01

# Use full or partial path
./run debug openvm rv32i_m/M/div-01

# Debug extra tests
./run debug --extra sp1 custom-test

# After seeing failures in main test run
./run test --arch openvm
# ... see "div-01 FAILED" ...
./run debug openvm div-01
```

## What It Does

1. **Finds** the pre-compiled test ELF from your last test run
2. **Re-runs** the test with full verbose logging:
   - `RUST_LOG=debug` - Detailed runtime logs
   - `RUST_BACKTRACE=full` - Complete stack traces on panics
3. **Saves** output to `debug-output/{zkvm}/{test}_{timestamp}.log`
4. **Compares** signatures with expected results
5. **Shows** diff if signatures don't match

## Why Use This

### Instead of re-running full test suite:
```bash
# Slow - rebuilds Docker, runs all tests
./run test --arch openvm  # 5+ minutes
```

### Debug specific test:
```bash
# Fast - just re-runs one test with verbose output
./run debug openvm div-01  # 2 seconds
```

## Typical Workflow

### 1. Run Tests and Identify Failures

```bash
./run test --arch openvm
```

Output shows:
```
Testing openvm...
✅ Tested openvm: 145/150 passed

# 5 tests failed - which ones?
```

### 2. Find Failed Tests

Check the HTML report:
```bash
./run serve
# Open http://localhost:8000
```

Or check console output / results:
```bash
grep -r "Failed" test-results/openvm/report-arch.html
```

### 3. Debug First Failure

```bash
./run debug openvm div-01
```

Output shows:
```
🐛 Running with verbose logging...
   Log output: debug-output/openvm/div-01.S_20250930_120000.log

[DEBUG openvm::runtime] Starting execution...
[DEBUG openvm::runtime] PC: 0x80000000
[DEBUG openvm::instructions] Executing DIV instruction
[ERROR openvm::runtime] Division overflow detected!
thread 'main' panicked at 'divide by zero', runtime.rs:142:5
stack backtrace:
   0: rust_begin_unwind
   1: openvm::runtime::execute_div
   ... (full stack trace) ...

❌ Test failed with exit code: 101
📝 Full log saved to: debug-output/openvm/div-01.S_20250930_120000.log
```

### 4. Fix the Issue

```bash
cd /path/to/openvm
# Edit runtime.rs to fix divide-by-zero handling
vim runtime.rs
```

### 5. Quick Rebuild and Retest

```bash
cargo build --release && \
  cp target/release/cargo-openvm /path/to/zkevm-test-monitor/binaries/openvm-binary && \
  cd /path/to/zkevm-test-monitor && \
  ./run debug openvm div-01
```

### 6. Verify Fix

```bash
✅ Test completed successfully
📝 Full log saved to: debug-output/openvm/div-01.S_20250930_124530.log

📄 Generated signature:
00000000
00000001

📊 Expected signature:
00000000
00000001

✅ Signatures match!
```

### 7. Run Full Suite to Confirm

```bash
./run test --arch openvm
```

## Output Files

### Log Files
Location: `debug-output/{zkvm}/{test}_{timestamp}.log`

Example:
```
debug-output/
└── openvm/
    ├── div-01.S_20250930_120000.log
    ├── div-01.S_20250930_124530.log  (after fix)
    └── mulhu-01.S_20250930_130000.log
```

These contain:
- Full RUST_LOG=debug output
- Complete backtraces on panics
- All VM execution traces
- Instruction-level debugging info

### Signature Files
Location: `debug-output/{zkvm}/debug.signature`

Overwritten each debug run. Contains the memory signature produced by the test.

## Test Pattern Matching

The debug command fuzzy-matches test names:

```bash
# All of these work for test "rv32i_m/M/src/div-01.S":
./run debug openvm div-01
./run debug openvm div-01.S
./run debug openvm M/div
./run debug openvm rv32i_m/M/div-01
```

If multiple tests match, it picks the first one. For exact control, use the full path.

## Supported ZKVMs

Works with all ZKVMs in the test monitor:
- `openvm` - `cargo-openvm openvm run --exe` ⚠️ **Note**: OpenVM requires executables compiled with OpenVM toolchain (bitcode format), not standard RISC-V ELFs from gcc
- `sp1` - `sp1-perf-executor --elf`
- `jolt` - `jolt-emu`
- `r0vm` - `r0vm`
- `zisk` - `ziskemu`
- `pico` - `pico-riscof`
- `airbender` - `cli`

Each ZKVM runs with appropriate flags for its binary.

### OpenVM Limitation

OpenVM expects executables in its own bitcode format, compiled with `cargo openvm build`. The RISCOF tests are compiled with standard gcc (`riscv64-unknown-elf-gcc`), which produces ELFs that OpenVM cannot execute.

**For OpenVM debugging**, the RISCOF plugin already provides limited output in `test-results/openvm/<test>/openvm.log`. For deeper debugging, you would need to:
1. Rewrite the test as an OpenVM program
2. Compile it with `cargo openvm build`
3. Then use the debug command

For other ZKVMs that accept standard RISC-V ELFs, the debug workflow works as designed.

## Comparison with Other Debug Methods

### Method 1: Debug Command (This Tool)
**Pros:**
- Fast (2 seconds)
- Full verbose logging
- Uses existing test ELFs
- No Docker overhead
- Easy to iterate

**Cons:**
- Requires test to be compiled first (run `./run test` once)

### Method 2: Modify Plugin to Log Verbosely
**Pros:**
- Logs all tests at once

**Cons:**
- Slow (re-runs all tests)
- Output mixed with hundreds of tests
- Must edit `riscof_openvm.py`
- Hard to find relevant logs

### Method 3: Manual Docker RISCOF Run
**Pros:**
- Full RISCOF environment

**Cons:**
- Complex Docker commands
- Slow to start
- Still need to isolate specific test
- Overkill for simple debugging

## Advanced: Custom Debug Flags

Edit `src/debug.sh` to customize logging per ZKVM:

```bash
case "$ZKVM" in
  openvm)
    # Add custom OpenVM flags
    RUST_LOG=trace RUST_BACKTRACE=full \
      "binaries/${ZKVM}-binary" openvm run \
      --elf "$TEST_ELF" \
      --signatures "${DEBUG_DIR}/debug.signature" \
      --dump-instructions \     # Custom flag
      2>&1 | tee "$LOG_FILE"
    ;;
```

## Tips

### List Available Tests
```bash
# Show all tests for a ZKVM
find test-results/openvm -type d -path "*/dut" | \
  sed 's|test-results/openvm/||' | \
  sed 's|/dut$||'
```

### Search Logs
```bash
# Search all debug logs for specific error
grep -r "panic" debug-output/openvm/

# Find specific log files
ls -lt debug-output/openvm/*.log | head -5
```

### Compare Multiple Runs
```bash
# Keep logs from before and after fix
./run debug openvm div-01
mv debug-output/openvm/div-01.S_*.log before-fix.log

# ... make changes ...

./run debug openvm div-01
mv debug-output/openvm/div-01.S_*.log after-fix.log

diff before-fix.log after-fix.log
```

## Integration with Development

### Git Workflow
```bash
# .gitignore already excludes debug-output/
git status  # Won't show debug logs
```

### CI/CD
The debug command is for local development only. CI runs the normal test workflow.

### IDE Integration
Configure your IDE to run debug command on test failure:
- VS Code: Add task in `.vscode/tasks.json`
- CLion: Add run configuration
- Vim: Add keybinding to `:!./run debug openvm <cword>`

## Troubleshooting

### "No test found matching"
```bash
# First, ensure tests have been run at least once
./run test --arch openvm

# Then list available tests
find test-results/openvm -name "*.elf" | head -20
```

### "Binary not found"
```bash
# Rebuild the ZKVM binary
./run build openvm

# Or copy from local build
cp /path/to/openvm/target/release/cargo-openvm binaries/openvm-binary
```

### Test passes in debug but fails in RISCOF
This can happen due to:
- Different environment variables
- Docker vs native execution differences
- Timing issues (rare)

Try running RISCOF manually with same verbose flags to compare.
