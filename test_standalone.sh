#!/bin/bash

# Extract and run compiled ecall test from RISCOF container
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

./run test --act-extra zisk

# Extract compiled test files from test-results directory
WORKDIR="${SCRIPT_DIR}/copied"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# The test outputs to test-results/zisk directory
if [ -d "${SCRIPT_DIR}/test-results/zisk" ]; then
  cp -r "${SCRIPT_DIR}/test-results/zisk/"* "$WORKDIR/" 2>/dev/null || {
    echo "Error: Could not copy test results"
    exit 1
  }
else
  echo "Error: test-results/zisk directory not found"
  exit 1
fi

# Print the signature files from the container
echo ""
echo "=== Signatures from RISCOF container ==="
echo ""
echo "--- DUT (ZisK) Signature ---"
DUT_SIG=$(find "$WORKDIR" -path "*ecall-01*/dut/DUT-zisk.signature" -type f | head -1)
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
echo "=== Running external ZisK test ==="
echo ""

# Find the DUT test ELF - specifically ecall-01
TEST_ELF=$(find "$WORKDIR" -path "*ecall-01*/dut/*.elf" -type f | head -1)

if [ -z "$TEST_ELF" ]; then
  echo "Error: No DUT test ELF found"
  exit 1
fi

# Run with ZisK emulator
ZISK_EMU="${SCRIPT_DIR}/zisk/target/release/ziskemu"

if [ ! -f "$ZISK_EMU" ]; then
  echo "Error: ZisK emulator not found at $ZISK_EMU"
  exit 1
fi

echo "Running ecall test with ZisK:"
echo "Test: $(basename "$(dirname "$(dirname "$TEST_ELF")")")"
"$ZISK_EMU" -e "$TEST_ELF"

