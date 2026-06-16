#!/bin/bash
set -eu

# ACT4 Airbender test runner
#
# Expected mounts:
#   /dut/airbender-binary          — the Airbender CLI binary (with run-with-transpiler command)
#   /act4/config/airbender         — Airbender ACT4 config directory (host act4-configs/airbender)
#   /results/                      — output directory for summary JSON

DUT=/dut/airbender-binary
ZKVM=airbender
RESULTS=/results
WORKDIR=/act4/work

if [ ! -x "$DUT" ]; then
    echo "Error: No executable found at $DUT"
    exit 1
fi

cd /act4
mkdir -p "$RESULTS"
JOBS="${ACT4_JOBS:-$(nproc)}"

# run_act4_suite <config-path> <config-name> <extensions-list> <extensions-txt-entries> <summary-suffix>
#
# Generates Makefiles, compiles ELFs, runs them, and writes summary + per-test JSON.
# summary-suffix: "" for native, "-target" for ETH-ACT target
run_act4_suite() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local SUFFIX="$5"
    # Derive file label from suffix
    local FILE_LABEL
    if [ -z "$SUFFIX" ]; then
        FILE_LABEL="full-isa"
    else
        FILE_LABEL="standard-isa"
    fi

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "⚠️  Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return
    fi

    # Pre-generate extensions.txt to skip UDB validation (which requires Podman/Docker
    # inside the container). The ACT framework skips UDB calls when this file exists
    # and is newer than the UDB config.
    mkdir -p "$WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
    # Touch with future timestamp to ensure it's always newer than the mounted config
    touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

    # Generate Makefiles and compile self-checking ELFs.
    # In 4.0.0, 'act' handles both Makefile generation and compilation.
    echo ""
    echo "=== Generating Makefiles for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi
    echo "=== Running $ELF_COUNT tests with Airbender ($CONFIG_NAME) ==="

    # Create a wrapper that converts each ELF to a flat binary and extracts the
    # entry point and tohost address before invoking run-with-transpiler.
    # ACT4 4.0.0 run_tests.py requires RVCP-SUMMARY in stdout to confirm pass/fail.
    # Airbender's RVMODEL_IO_WRITE_STR is a no-op, so synthesize it from exit code.
    cat > /act4/run-dut.sh << 'WRAPPER'
#!/bin/bash
ELF="$1"
BIN="${ELF%.elf}.bin"

# Convert ELF to flat binary (file starts at lowest load VMA)
riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"

# Extract entry point address from ELF header (hex → decimal for CLI)
ENTRY=$(riscv64-unknown-elf-readelf -h "$ELF" \
    | grep "Entry point" | grep -oE '0x[0-9a-f]+')
ENTRY_DEC=$(printf '%d' "$ENTRY")

# Extract tohost symbol address (nm outputs hex without 0x prefix → decimal for CLI)
TOHOST_HEX=$(riscv64-unknown-elf-nm "$ELF" \
    | awk '$3 == "tohost" {print $1; exit}')
TOHOST_DEC=$(printf '%d' "0x${TOHOST_HEX}")

OUTPUT=$(/dut/airbender-binary run-with-transpiler \
    --bin "$BIN" \
    --entry-point "$ENTRY_DEC" \
    --tohost-addr "$TOHOST_DEC" \
    --cycles 10000000 2>&1)
EC=$?
rm -f "$BIN"
echo "$OUTPUT"
if [ $EC -eq 0 ]; then
  echo "RVCP-SUMMARY: TEST PASSED - Test File \"$ELF\""
else
  echo "RVCP-SUMMARY: TEST FAILED - Test File \"$ELF\""
fi
exit $EC
WRAPPER
    chmod +x /act4/run-dut.sh

    # run_tests.py exits 0 if all pass, 1 if any fail.
    # Capture output for parsing; allow non-zero exit.
    local RUN_OUTPUT
    RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1) || true
    echo "$RUN_OUTPUT"

    # Parse results from run_tests.py output.
    # ACT4 4.0.0 format: "RESULT: N failed, M passed out of T tests."
    local FAILED TOTAL PASSED
    FAILED=$(echo "$RUN_OUTPUT" | grep -oE 'RESULT: [0-9]+ failed' | grep -oE '[0-9]+' || echo "0")
    TOTAL=$(echo "$RUN_OUTPUT" | grep -oE 'out of [0-9]+ tests' | grep -oE '[0-9]+' || echo "$ELF_COUNT")
    PASSED=$((TOTAL - FAILED))

    cat > "$RESULTS/summary-act4-${FILE_LABEL}.json" << EOF
{
  "zkvm": "$ZKVM",
  "suite": "act4${SUFFIX}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

    # Generate per-test results JSON.
    # Write run_output to a temp file to avoid shell-quoting issues in -c.
    local RUN_OUTPUT_FILE
    RUN_OUTPUT_FILE=$(mktemp)
    echo "$RUN_OUTPUT" > "$RUN_OUTPUT_FILE"
    python3 -c "
import json, os, re

elf_dir = '$ELF_DIR'
with open('$RUN_OUTPUT_FILE') as _f:
    run_output = _f.read()
expected_passed = $PASSED

# Parse failed test names from run_tests.py output (ACT4 4.0.0 format).
failed_names = set()
for line in run_output.splitlines():
    m = re.match(r'\s+FAIL\s+(\S+\.elf)\s', line)
    if m:
        failed_names.add(m.group(1))

# Enumerate all ELFs and build per-test results
tests = []
for root, dirs, files in os.walk(elf_dir):
    for f in sorted(files):
        if not f.endswith('.elf'):
            continue
        ext = os.path.basename(root)
        name = f.removesuffix('.elf')
        tests.append({
            'name': name,
            'extension': ext,
            'passed': f not in failed_names
        })

tests.sort(key=lambda t: (t['extension'], t['name']))

# Cross-check: if parsed pass count does not match the authoritative count,
# some tests failed silently. Mark all as failed since we cannot reliably
# distinguish which ones truly passed.
parsed_passed = sum(1 for t in tests if t['passed'])
if parsed_passed != expected_passed:
    for t in tests:
        t['passed'] = False

passed_names = [t['name'] for t in tests if t['passed']]
failed_names_list = [t['name'] for t in tests if not t['passed']]

with open('$RESULTS/results-act4-${FILE_LABEL}.json', 'w') as out:
    json.dump({
        'zkvm': '$ZKVM',
        'suite': 'act4${SUFFIX}',
        'tests': tests,
        'passed': passed_names,
        'failed': failed_names_list,
        'prove_failed': [],
        'verify_failed': []
    }, out, indent=2)

print(f'Per-test results: {len(tests)} tests written to results-act4-${FILE_LABEL}.json')
"
    rm -f "$RUN_OUTPUT_FILE"

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
}

# Run each suite; allow failures without aborting (set -e is active globally)
# ─── Run 1: Native ISA (rv32im) ───
run_act4_suite \
    "config/airbender/airbender-rv32im/test_config.yaml" \
    "airbender-rv32im" \
    "I,M" \
    "$(printf 'I\nM\nZicsr\nSm')" \
    "" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/airbender/airbender-rv64im-zicclsm/test_config.yaml" \
    "airbender-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "-target" || true

echo ""
echo "=== All ACT4 suites complete ==="
