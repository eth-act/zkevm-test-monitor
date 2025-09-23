#!/bin/bash

# Extract and run compiled ecall test from RISCOF container with Jolt
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Clean up previous test results to force recompilation
echo "Cleaning previous test results to force recompilation..."
rm -rf "${SCRIPT_DIR}/test-results/jolt/extra"
# Try to remove riscof_work, but don't fail if permission denied
rm -rf "${SCRIPT_DIR}/riscof/riscof_work" 2>/dev/null || true

./run test --act-extra jolt

# Extract compiled test files from test-results directory
WORKDIR="${SCRIPT_DIR}/copied-jolt"
# Clean up any previous copied files to ensure fresh results
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# The test outputs to test-results/jolt directory
if [ -d "${SCRIPT_DIR}/test-results/jolt" ]; then
  cp -r "${SCRIPT_DIR}/test-results/jolt/"* "$WORKDIR/" 2>/dev/null || {
    echo "Error: Could not copy test results"
    exit 1
  }
else
  echo "Error: test-results/jolt directory not found"
  exit 1
fi

# Print the signature files from the container
echo ""
echo "=== Signatures from RISCOF container ==="
echo ""
echo "--- DUT (Jolt) Signature ---"
DUT_SIG=$(find "$WORKDIR" -path "*ecall-01*/dut/DUT-jolt.signature" -type f | head -1)
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
echo "=== Running external Jolt test ==="
echo ""

# Find the DUT test ELF - specifically ecall-01
TEST_ELF=$(find "$WORKDIR" -path "*ecall-01*/dut/*.elf" -type f | head -1)

if [ -z "$TEST_ELF" ]; then
  echo "Error: No DUT test ELF found"
  exit 1
fi

# Run with Jolt emulator
JOLT_EMU="${SCRIPT_DIR}/jolt/target/release/jolt-emu"

if [ ! -f "$JOLT_EMU" ]; then
  echo "Error: Jolt emulator not found at $JOLT_EMU"
  echo "Building Jolt emulator..."
  cd "${SCRIPT_DIR}/jolt" && cargo build --release --bin jolt-emu
  cd "$SCRIPT_DIR"
fi

echo "Running ecall test with Jolt:"
echo "Test: $(basename "$(dirname "$(dirname "$TEST_ELF")")")"
echo ""
# Clean up any previous signature file to ensure fresh results
rm -f /tmp/jolt-test.sig
echo "Command: $JOLT_EMU $TEST_ELF --signature /tmp/jolt-test.sig --signature-granularity 4"
echo ""
"$JOLT_EMU" "$TEST_ELF" --signature /tmp/jolt-test.sig --signature-granularity 4 2>&1 || {
  echo ""
  echo "Jolt emulator exited with error (expected for ecall/ebreak tests)"
  echo ""
  if [ -f /tmp/jolt-test.sig ]; then
    echo "--- Jolt generated signature ---"
    cat /tmp/jolt-test.sig
  else
    echo "No signature generated (Jolt likely panicked)"
  fi
}

echo ""
echo "=== Testing with magic ecall value ==="
echo ""
# Try to patch the binary to use Jolt's magic value
echo "Note: Standard ecall test will fail. Testing with Jolt's cycle tracking value (0xC7C1E)..."