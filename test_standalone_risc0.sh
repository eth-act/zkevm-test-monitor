#!/bin/bash

# Extract and run compiled ecall test from RISCOF container with RISC0
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clean up previous test results to force recompilation
echo "Cleaning previous test results to force recompilation..."
rm -rf "${SCRIPT_DIR}/test-results/risc0/extra"
# Try to remove riscof_work, but don't fail if permission denied
rm -rf "${SCRIPT_DIR}/riscof/riscof_work" 2>/dev/null || true

./run test --act-extra risc0

# Extract compiled test files from test-results directory
WORKDIR="${SCRIPT_DIR}/copied-risc0"
# Clean up any previous copied files to ensure fresh results
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# The test outputs to test-results/risc0 directory
if [ -d "${SCRIPT_DIR}/test-results/risc0" ]; then
  cp -r "${SCRIPT_DIR}/test-results/risc0/"* "$WORKDIR/" 2>/dev/null || {
    echo "Error: Could not copy test results"
    exit 1
  }
else
  echo "Error: test-results/risc0 directory not found"
  exit 1
fi

# Print the signature files from the container
echo ""
echo "=== Signatures from RISCOF container ==="
echo ""
echo "--- DUT (RISC0) Signature ---"
DUT_SIG=$(find "$WORKDIR" -path "*ecall-01*/dut/DUT-risc0.signature" -type f | head -1)
if [ -f "$DUT_SIG" ]; then
  cat "$DUT_SIG"
else
  echo "DUT signature not found"
fi

echo ""
echo "--- Reference (Sail) Signature ---"
REF_SIG=$(find "$WORKDIR" -path "*ecall-01*/ref/Reference-*.signature" -type f | head -1)
if [ -f "$REF_SIG" ]; then
  cat "$REF_SIG"
else
  echo "Reference signature not found"
fi

echo ""
echo "=== Running external RISC0 test ==="
echo ""

# Find the DUT test ELF - specifically ecall-01
TEST_ELF=$(find "$WORKDIR" -path "*ecall-01*/dut/*.elf" -type f | head -1)

if [ -z "$TEST_ELF" ]; then
  echo "Error: No DUT test ELF found"
  exit 1
fi

# Run with RISC0 emulator
RISC0_EMU="${SCRIPT_DIR}/risc0/target/release/r0vm"

if [ ! -f "$RISC0_EMU" ]; then
  echo "Error: RISC0 emulator not found at $RISC0_EMU"
  echo "Building RISC0 emulator..."
  cd "${SCRIPT_DIR}/risc0" && cargo build --release --bin r0vm
  cd "$SCRIPT_DIR"
fi

echo "Running ecall test with RISC0:"
echo "Test: $(basename "$(dirname "$(dirname "$TEST_ELF")")")"
echo ""
# Clean up any previous signature file to ensure fresh results
rm -f /tmp/risc0-test.sig
echo "Command: $RISC0_EMU --elf $TEST_ELF"
echo ""

# Check if there's a log file from RISCOF run
RISC0_LOG=$(find "$WORKDIR" -path "*ecall-01*/dut/*.log" -type f | head -1)
if [ -f "$RISC0_LOG" ]; then
  echo "--- RISCOF run log ---"
  cat "$RISC0_LOG"
  echo ""
fi

# Try to run r0vm directly
echo "--- Direct r0vm execution ---"
"$RISC0_EMU" --elf "$TEST_ELF" 2>&1 || {
  echo ""
  echo "RISC0 emulator exited with error (expected for ecall/ebreak tests)"
  echo ""
}

echo ""
echo "=== Checking for any error details ==="
echo ""

# Look for any error logs or debug output
if [ -d "$WORKDIR" ]; then
  echo "Looking for error logs in test results..."
  find "$WORKDIR" -name "*.log" -type f -exec echo "--- {} ---" \; -exec cat {} \; 2>/dev/null
fi