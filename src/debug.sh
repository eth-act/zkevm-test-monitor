#!/bin/bash
set -e

# Parse arguments
ZKVM=""
TEST_PATH=""
SUITE="arch"

while [[ $# -gt 0 ]]; do
    case $1 in
        --arch)
            SUITE="arch"
            shift
            ;;
        --extra)
            SUITE="extra"
            shift
            ;;
        *)
            if [ -z "$ZKVM" ]; then
                ZKVM="$1"
            else
                TEST_PATH="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$ZKVM" ] || [ -z "$TEST_PATH" ]; then
    cat << EOF
Usage: ./run debug [--arch|--extra] <zkvm> <test-pattern>

Examples:
  ./run debug openvm div-01           # Find and debug div-01 test
  ./run debug --extra sp1 custom-01   # Debug extra test
  ./run debug openvm rv32i_m/M/div    # Partial path match

This command re-runs a specific test with full verbose logging,
bypassing RISCOF to help debug panics and failures.
EOF
    exit 1
fi

# Check binary exists
if [ ! -f "binaries/${ZKVM}-binary" ]; then
    echo "❌ No binary found for $ZKVM at binaries/${ZKVM}-binary"
    exit 1
fi

# Check if test results exist
if [ ! -d "test-results/${ZKVM}" ] || [ -z "$(find "test-results/${ZKVM}" -type d -path "*/dut" 2> /dev/null)" ]; then
    echo "❌ No test results found for $ZKVM"
    echo "   Run tests first: ./run test --${SUITE} $ZKVM"
    exit 1
fi

# Find matching test ELF in results
echo "🔍 Searching for test matching '$TEST_PATH' in ${SUITE} suite..."

# Try exact match first (e.g., "add" matches "add-01" but not "addi-01")
TEST_DIR=$(find "test-results/${ZKVM}" -type d -path "*/dut" -path "*/${TEST_PATH}-*" 2> /dev/null | head -1)

# Fall back to substring match if exact match fails
if [ -z "$TEST_DIR" ]; then
    TEST_DIR=$(find "test-results/${ZKVM}" -type d -path "*/dut" -path "*${TEST_PATH}*" 2> /dev/null | head -1)
fi

if [ -z "$TEST_DIR" ]; then
    echo "❌ No test found matching '$TEST_PATH'"
    echo ""
    echo "Available tests (showing first 20):"
    find "test-results/${ZKVM}" -type d -path "*/dut" 2> /dev/null \
        | sed 's|test-results/'"${ZKVM}"'/||' \
        | sed 's|/dut$||' \
        | head -20
    exit 1
fi

TEST_ELF="${TEST_DIR}/my.elf"
if [ ! -f "$TEST_ELF" ]; then
    echo "❌ Test ELF not found at $TEST_ELF"
    exit 1
fi

# Extract test name with directory structure for unique log paths
# e.g., test-results/openvm/rv32i_m/I/src/add-01.S/dut -> rv32i_m/I/add-01.S
TEST_NAME=$(echo "$TEST_DIR" | sed "s|test-results/${ZKVM}/||" | sed 's|/src/|/|' | sed 's|/dut$||')
echo "✓ Found test: $TEST_NAME"
echo "  ELF: $TEST_ELF"
echo ""

# Create debug output directory
DEBUG_DIR="debug-output/${ZKVM}"
mkdir -p "$DEBUG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${DEBUG_DIR}/${TEST_NAME//\//_}_${TIMESTAMP}.log"

echo "🐛 Running with verbose logging..."
echo "   Log output: $LOG_FILE"
echo ""

# Get absolute paths for use in test directory
ABS_BINARY="$(realpath "binaries/${ZKVM}-binary")"
ABS_TEST_ELF="$(realpath "$TEST_ELF")"
ABS_DEBUG_DIR="$(realpath "$DEBUG_DIR")"
ABS_LOG_FILE="$(realpath "$LOG_FILE")"

# Run based on ZKVM type
case "$ZKVM" in
    openvm)
        # OpenVM needs to run from a directory with Cargo.toml
        # Extract the test directory (parent of dut/)
        TEST_WORK_DIR="$(dirname "$(dirname "$TEST_ELF")")"

        # Create a temporary working directory we can write to
        TEMP_WORK_DIR="${DEBUG_DIR}/temp_work"
        mkdir -p "$TEMP_WORK_DIR"

        # Copy the ELF and create necessary files
        cp "$ABS_TEST_ELF" "$TEMP_WORK_DIR/my.elf"

        cd "$TEMP_WORK_DIR"

        # Create minimal Cargo.toml
        cat > Cargo.toml << 'CARGO_TOML'
[package]
name = "riscof-test"
version = "0.1.0"
edition = "2021"

[dependencies]
CARGO_TOML

        # Create minimal openvm.toml with required app_vm_config
        cat > openvm.toml << 'OPENVM_TOML'
[app_vm_config.rv32i]
[app_vm_config.io]
[app_vm_config.rv32m]
[app_vm_config.rv32f]
OPENVM_TOML

        set +e  # Disable exit-on-error to capture exit code
        RUST_LOG=trace RUST_BACKTRACE=1 \
            "$ABS_BINARY" openvm run \
            --exe my.elf \
            --signatures "${ABS_DEBUG_DIR}/debug.signature" \
            2>&1 | tee "$ABS_LOG_FILE"

        EXIT_CODE=${PIPESTATUS[0]}  # Get exit code of openvm command, not tee
        set -e  # Re-enable exit-on-error
        cd - > /dev/null
        ;;

    sp1)
        # Run SP1 with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" \
            --elf "$TEST_ELF" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    jolt)
        # Run Jolt with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" \
            "$TEST_ELF" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    r0vm)
        # Run r0vm with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" \
            "$TEST_ELF" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    zisk)
        # Run zisk with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" \
            "$TEST_ELF" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    pico)
        # Run pico with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" pico test-emulator \
            --elf "$TEST_ELF" \
            --signatures "${DEBUG_DIR}/debug.signature" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    airbender)
        # Run airbender with verbose output
        set +e
        RUST_LOG=debug RUST_BACKTRACE=full \
            "binaries/${ZKVM}-binary" \
            "$TEST_ELF" \
            2>&1 | tee "$LOG_FILE"
        EXIT_CODE=${PIPESTATUS[0]}
        set -e
        ;;

    *)
        echo "❌ Unknown ZKVM: $ZKVM"
        echo "   Supported: openvm, sp1, jolt, r0vm, zisk, pico, airbender"
        exit 1
        ;;
esac

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Test completed successfully"
else
    echo "❌ Test failed with exit code: $EXIT_CODE"

    # Check if this is a VM exit code failure (OpenVM wraps the exit code in an error)
    if [ "$ZKVM" = "openvm" ] && grep -q "program exit code" "$ABS_LOG_FILE" 2>/dev/null; then
        # Extract the VM exit code from the error message
        VM_EXIT_CODE=$(grep "program exit code" "$ABS_LOG_FILE" | head -1 | sed -n 's/.*program exit code \([0-9]*\).*/\1/p')

        if [ "$VM_EXIT_CODE" = "2" ]; then
            echo ""
            echo "🔍 Analyzing FLOAT_ASSERT failure (VM exited with code 2)..."

            # Look for STOREW operations to address 0 (which would be register x0 = 0x0)
            # The FLOAT_ASSERT macro writes: *(uint64_t *)0x0 = __LINE__;
            # This becomes: sw a5, 0(zero) and sw a6, 4(zero)
            # In the trace, STOREW to base register x0 (b: 0x0) with offset 0 or 4

            # Find PC values of stores to address 0
            STORE_PCS=$(grep -n "vm_opcode: 53[0-9].*b: 0x0.*f: 0x1" "$ABS_LOG_FILE" | tail -2 | sed 's/:.*pc: 0x\([0-9a-f]*\).*/\1/')

            if [ -n "$STORE_PCS" ]; then
                # Get the PC of the first store (lower 32 bits)
                STORE_PC_LOW=$(echo "$STORE_PCS" | head -1)
                # Find the instruction right before it that loads the value
                LINE_NUM_LOW=$(grep "pc: 0x" "$ABS_LOG_FILE" | grep -B1 "pc: 0x$STORE_PC_LOW" | head -1 | sed -n 's/.*c: 0x\([0-9a-f]*\).*/\1/p')

                if [ -n "$LINE_NUM_LOW" ]; then
                    LINE_NUM_DEC=$((0x$LINE_NUM_LOW))
                    echo "   FLOAT_ASSERT triggered at line: $LINE_NUM_DEC (0x$LINE_NUM_LOW)"
                    echo "   Check: extensions/floats/guest/vendor/zisk/lib-float/c/src/float/float.c:$LINE_NUM_DEC"
                else
                    echo "   Could not extract line number value from trace"
                fi
            else
                echo "   Could not find stores to address 0 in trace"
            fi
        fi
    fi
fi

echo ""
echo "📝 Full log saved to: $LOG_FILE"

# Save signature to output folder if it exists
if [ -f "${DEBUG_DIR}/debug.signature" ]; then
    echo ""
    echo "📄 Signature saved to: ${DEBUG_DIR}/debug.signature"
fi

# Compare with expected if available
EXPECTED_SIG="${TEST_DIR}/../ref/Reference-sail_cSim.signature"
if [ -f "$EXPECTED_SIG" ]; then
    if [ -f "${DEBUG_DIR}/debug.signature" ]; then
        echo ""
        if diff -q "${DEBUG_DIR}/debug.signature" "$EXPECTED_SIG" > /dev/null; then
            echo "✅ Signatures match!"
        else
            echo "❌ Signatures differ (see ${DEBUG_DIR}/debug.signature and ${EXPECTED_SIG})"
        fi
    fi
fi

exit $EXIT_CODE
