#!/bin/bash
set -e

# Parse ZKVM argument
ZKVM="$1"  # run script shifts args, so $1 is the zkvm name

if [ -z "$ZKVM" ]; then
  cat << EOF
Usage: ./run generate-test-artifact <zkvm>

Generates a test artifact (compiled ELF) for the specified ZKVM.
Uses RISCOF to compile tests without running them.

Supported ZKVMs: openvm, sp1, jolt, r0vm, zisk, pico, airbender

Example:
  ./run generate-test-artifact openvm

The artifact will be saved to test-artifacts/{zkvm}/
EOF
  exit 1
fi

# Validate ZKVM
VALID_ZKVMS="openvm sp1 jolt r0vm zisk pico airbender"
if [[ ! " $VALID_ZKVMS " =~ " $ZKVM " ]]; then
  echo "❌ Invalid ZKVM: $ZKVM"
  echo "   Supported: $VALID_ZKVMS"
  exit 1
fi

# Check binary exists
if [ ! -f "binaries/${ZKVM}-binary" ]; then
  echo "❌ No binary found for $ZKVM"
  echo "   Run: ./run build $ZKVM"
  exit 1
fi

echo "🔧 Generating test artifact for $ZKVM"
echo ""

# Clean previous results for this ZKVM (best effort, ignore errors from Docker-created files)
echo "🧹 Cleaning previous test results..."
rm -rf "test-results/${ZKVM}" 2>/dev/null || true

# Build RISCOF Docker image if needed
if ! docker images | grep -q "^riscof "; then
  echo "🔨 Building RISCOF Docker image..."
  cd riscof
  docker build -t riscof:latest . || {
    echo "❌ Failed to build RISCOF Docker image"
    cd ..
    exit 1
  }
  cd ..
fi

# Check plugin exists
if [ ! -d "riscof/plugins/${ZKVM}" ]; then
  echo "❌ No plugin found at riscof/plugins/${ZKVM}"
  exit 1
fi

# Run RISCOF in compile-only mode
echo "🔨 Compiling tests with RISCOF (no execution)..."

# Make binary executable
chmod +x "binaries/${ZKVM}-binary" 2> /dev/null || true

# Create results directory
mkdir -p "test-results/${ZKVM}"

# Run Docker with same pattern as test.sh but with compile-only flag
# entrypoint.sh expects: $1=zkvm $2=suite $3=compile-only
docker run --rm \
  -v "$PWD/binaries/${ZKVM}-binary:/dut/bin/dut-exe" \
  -v "$PWD/riscof/plugins/${ZKVM}:/dut/plugin" \
  -v "$PWD/test-results/${ZKVM}:/riscof/riscof_work" \
  -v "$PWD/extra-tests:/extra-tests" \
  riscof:latest \
  "${ZKVM}" arch compile-only || {
    echo "❌ RISCOF compilation failed"
    exit 1
  }

# Find the jal-01.S test
# Check if this is RV64 (currently only zisk)
if [ "$ZKVM" = "zisk" ]; then
  ISA_PREFIX="rv64i_m"
else
  ISA_PREFIX="rv32i_m"
fi

TEST_PATH="test-results/${ZKVM}/${ISA_PREFIX}/I/src/jal-01.S/dut/my.elf"

if [ ! -f "$TEST_PATH" ]; then
  echo "❌ Test ELF not found at $TEST_PATH"
  echo "   RISCOF may have failed to compile tests"
  exit 1
fi

# Create artifact directory
ARTIFACT_DIR="test-artifacts/${ZKVM}"
mkdir -p "$ARTIFACT_DIR"

# Copy artifact
echo "📦 Copying artifact..."
cp "$TEST_PATH" "$ARTIFACT_DIR/jal-01.elf"

# Generate metadata
echo "📝 Generating metadata..."
cat > "$ARTIFACT_DIR/metadata.json" << EOF_META
{
  "zkvm": "$ZKVM",
  "test_name": "jal-01.S",
  "test_suite": "${ISA_PREFIX}/I",
  "generated_at": "$(date -Iseconds)",
  "elf_size": $(stat -f%z "$ARTIFACT_DIR/jal-01.elf" 2>/dev/null || stat -c%s "$ARTIFACT_DIR/jal-01.elf"),
  "source_path": "$TEST_PATH",
  "riscof_suite": "arch"
}
EOF_META

echo "✅ Artifact generated successfully"
echo ""
echo "📁 Artifact location: $ARTIFACT_DIR/"
echo "   - jal-01.elf ($(du -h "$ARTIFACT_DIR/jal-01.elf" | cut -f1))"
echo "   - metadata.json"
echo ""
echo "Next steps:"
echo "  1. Test: ./run test-debug $ZKVM"
echo "  2. Commit: git add test-artifacts/${ZKVM} && git commit"
