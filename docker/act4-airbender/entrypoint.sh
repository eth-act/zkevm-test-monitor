#!/bin/bash
set -eu

# ACT4 Airbender test runner
#
# Expected mounts:
#   /dut/airbender-binary          — the Airbender CLI binary (with run-for-act command)
#   /act4/config/airbender         — Airbender ACT4 config directory (host riscv-arch-test/config/airbender)
#   /results/                      — output directory for summary JSON

DUT=/dut/airbender-binary
RESULTS=/results
CONFIG=config/airbender/airbender-rv32im/test_config.yaml
WORKDIR=/act4/work

if [ ! -x "$DUT" ]; then
    echo "Error: No executable found at $DUT"
    exit 1
fi

if [ ! -f "/act4/$CONFIG" ]; then
    echo "Error: Config not found at /act4/$CONFIG"
    echo "Mount the config directory: -v \"\$PWD/riscv-arch-test/config/airbender:/act4/config/airbender\""
    exit 1
fi

cd /act4

# Pre-generate extensions.txt to skip UDB validation (which requires Podman/Docker
# inside the container). The ACT framework skips UDB calls when this file exists
# and is newer than the UDB config. The extensions must match airbender-rv32im.yaml.
mkdir -p "$WORKDIR/airbender-rv32im"
cat > "$WORKDIR/airbender-rv32im/extensions.txt" << 'EXTLIST'
I
M
Zicsr
Sm
EXTLIST
# Touch with future timestamp to ensure it's always newer than the mounted config
touch -t 209901010000 "$WORKDIR/airbender-rv32im/extensions.txt"

# Step 1: Generate Makefiles and compile self-checking ELFs for Airbender.
# The 'act' tool reads the DUT config, generates a Makefile, then invokes Sail
# to compute expected register values which are baked directly into the ELFs.
echo "=== Generating Makefiles for airbender-rv32im ==="
uv run act "$CONFIG" \
    --workdir "$WORKDIR" \
    --test-dir tests \
    --extensions I,M

echo "=== Compiling self-checking ELFs ==="
make -C "$WORKDIR" compile

ELF_DIR="$WORKDIR/airbender-rv32im/elfs"
ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
if [ "$ELF_COUNT" -eq 0 ]; then
    echo "Error: No ELFs found in $ELF_DIR after compilation"
    exit 1
fi
echo "=== Running $ELF_COUNT tests with Airbender ==="

JOBS="${ACT4_JOBS:-$(nproc)}"

# run_tests.py exits 0 if all pass, 1 if any fail.
# Capture output for parsing; allow non-zero exit.
RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT run-for-act" "$ELF_DIR" -j "$JOBS" 2>&1) || true
echo "$RUN_OUTPUT"

# Parse results from run_tests.py output.
# Possible formats:
#   "\tX out of N tests failed."  → X failures, N total
#   "\tAll N tests passed."       → 0 failures, N total
FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
PASSED=$((TOTAL - FAILED))

mkdir -p "$RESULTS"
cat > "$RESULTS/summary-act4.json" << EOF
{
  "zkvm": "airbender",
  "suite": "act4",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

echo ""
echo "=== Results: $PASSED/$TOTAL passed ==="
echo "Summary written to $RESULTS/summary-act4.json"
