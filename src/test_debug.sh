#!/bin/bash
set -e

# Parse arguments
TARGET_ZKVM="$1"  # run script shifts args, so $1 is optional zkvm name

# Determine which ZKVMs to test
if [ -z "$TARGET_ZKVM" ] || [ "$TARGET_ZKVM" = "all" ]; then
  ZKVMS="openvm sp1 jolt r0vm zisk pico airbender"
  echo "🧪 Testing debug command for all ZKVMs"
else
  ZKVMS="$TARGET_ZKVM"
  echo "🧪 Testing debug command for $TARGET_ZKVM"
fi

echo ""

PASSED=0
FAILED=0
SKIPPED=0

for ZKVM in $ZKVMS; do
  echo "──────────────────────────────────────"
  echo "Testing: $ZKVM"
  echo "──────────────────────────────────────"

  # Check if artifact exists
  ARTIFACT_DIR="test-artifacts/${ZKVM}"
  ARTIFACT_ELF="$ARTIFACT_DIR/jal-01.elf"

  if [ ! -f "$ARTIFACT_ELF" ]; then
    echo "⏭️  SKIPPED - No artifact found"
    echo "   Generate with: ./run generate-test-artifact $ZKVM"
    echo ""
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if binary exists
  if [ ! -f "binaries/${ZKVM}-binary" ]; then
    echo "⏭️  SKIPPED - No binary found"
    echo "   Build with: ./run build $ZKVM"
    echo ""
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Setup temporary test structure
  # Debug command expects test-results/{zkvm}/path/to/test/dut/my.elf

  # Clean entire ZKVM test directory (may have root-owned files from Docker)
  if ! rm -rf "test-results/${ZKVM}" 2>/dev/null; then
    # If regular rm fails (permission denied), try with sudo or Docker
    if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
      # Use sudo if available and configured for passwordless access
      sudo rm -rf "test-results/${ZKVM}" 2>/dev/null || true
    elif command -v docker &> /dev/null; then
      # Fall back to Docker to clean up root-owned files
      docker run --rm -v "${PWD}/test-results:/test-results" ubuntu:24.04 rm -rf "/test-results/${ZKVM}" 2>/dev/null || true
    fi
  fi

  TEMP_TEST_DIR="test-results/${ZKVM}/rv32i_m/I/src/jal-01.S/dut"
  mkdir -p "$TEMP_TEST_DIR"
  cp "$ARTIFACT_ELF" "$TEMP_TEST_DIR/my.elf"

  # For OpenVM, also need Cargo.toml and openvm.toml
  if [ "$ZKVM" = "openvm" ]; then
    PARENT_DIR="$(dirname "$TEMP_TEST_DIR")"
    cat > "$PARENT_DIR/Cargo.toml" << 'EOF_CARGO'
[package]
name = "riscof-test"
version = "0.1.0"
edition = "2021"

[dependencies]
EOF_CARGO

    cat > "$PARENT_DIR/openvm.toml" << 'EOF_OPENVM'
app_vm_config = { exe = "dut/my.elf" }
EOF_OPENVM
  fi

  # Run debug command and capture output
  echo "▶️  Running: ./run debug $ZKVM jal-01"

  if OUTPUT=$(./run debug "$ZKVM" jal-01 2>&1); then
    EXIT_CODE=0
  else
    EXIT_CODE=$?
  fi

  # Validate output
  SUCCESS=true

  if [ $EXIT_CODE -ne 0 ]; then
    echo "❌ FAILED - Exit code: $EXIT_CODE"
    SUCCESS=false
  elif ! echo "$OUTPUT" | grep -q "✅ Test completed successfully"; then
    echo "❌ FAILED - Missing success message in output"
    SUCCESS=false
  elif ! echo "$OUTPUT" | grep -q "Full log saved to:"; then
    echo "❌ FAILED - Missing log file message"
    SUCCESS=false
  else
    echo "✅ PASSED"
  fi

  if [ "$SUCCESS" = false ]; then
    echo ""
    echo "Output:"
    echo "$OUTPUT" | tail -20
    FAILED=$((FAILED + 1))
  else
    PASSED=$((PASSED + 1))
  fi

  echo ""
done

echo "══════════════════════════════════════"
echo "Test Summary"
echo "══════════════════════════════════════"
echo "✅ Passed:  $PASSED"
echo "❌ Failed:  $FAILED"
echo "⏭️  Skipped: $SKIPPED"
echo ""

if [ $FAILED -gt 0 ]; then
  exit 1
fi
