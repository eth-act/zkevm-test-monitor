#!/bin/bash

# Extract and run compiled ecall test from RISCOF container
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

./run test --extra zisk

# Find the most recent RISCOF test container
CONTAINER_NAME=$(docker ps -a --filter "name=riscof-test-" --format "{{.Names}}" | head -1)

if [ -z "$CONTAINER_NAME" ]; then
  echo "Error: No RISCOF test container found."
  echo "Please run: ./scripts/test.sh --extra zisk"
  exit 1
fi

# Extract compiled test files from container
WORKDIR="${SCRIPT_DIR}/copied"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

docker cp "$CONTAINER_NAME:/riscof/riscof_work/." "$WORKDIR" 2> /dev/null || {
  echo "Error: Could not extract from container"
  exit 1
}

# Find the DUT test ELF
TEST_ELF=$(find "$WORKDIR" -path "*/dut/*.elf" -type f | head -1)

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

