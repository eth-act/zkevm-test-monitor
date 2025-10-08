#!/bin/bash
# test-debug - Validate debug command functionality
#
# Tests that the debug command works correctly for each ZKVM by:
# - Checking that binaries exist
# - Checking that test results exist (from ./run test)
# - Running the debug command on a known test (jal-01)
# - Validating the output
#
# Usage: ./test-debug [zkvm]
#        ./test-debug all

set -e

# Parse arguments
TARGET_ZKVM="${1:-all}"

# Determine which ZKVMs to test
if [ "$TARGET_ZKVM" = "all" ]; then
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

  # Check if binary exists
  if [ ! -f "binaries/${ZKVM}-binary" ]; then
    # If testing a specific ZKVM, missing binary is a FAILURE
    if [ $(echo "$ZKVMS" | wc -w) -eq 1 ]; then
      echo "❌ FAILED - No binary found"
      echo "   Build with: ./run build $ZKVM"
      echo ""
      FAILED=$((FAILED + 1))
      continue
    else
      # If testing all ZKVMs, missing binary is just skipped
      echo "⏭️  SKIPPED - No binary found"
      echo "   Build with: ./run build $ZKVM"
      echo ""
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  # Check if test results exist with jal-01 test
  # Debug command expects test-results/{zkvm}/path/to/test/dut/my.elf
  TEST_ELF="test-results/${ZKVM}/rv32i_m/I/src/jal-01.S/dut/my.elf"

  if [ ! -f "$TEST_ELF" ]; then
    # If testing a specific ZKVM, missing test results is a FAILURE
    if [ $(echo "$ZKVMS" | wc -w) -eq 1 ]; then
      echo "❌ FAILED - No test results found"
      echo "   Run tests first: ./run test --arch $ZKVM"
      echo ""
      FAILED=$((FAILED + 1))
      continue
    else
      # If testing all ZKVMs, missing test results is just skipped
      echo "⏭️  SKIPPED - No test results found"
      echo "   Run tests first: ./run test --arch $ZKVM"
      echo ""
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
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
