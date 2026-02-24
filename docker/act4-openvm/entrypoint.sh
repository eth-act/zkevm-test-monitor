#!/bin/bash
set -eu

# ACT4 OpenVM test runner
#
# Expected mounts:
#   /dut/openvm-binary              — the OpenVM CLI binary (cargo-openvm)
#   /act4/config/openvm             — OpenVM ACT4 config directory (host act4-configs/openvm)
#   /results/                       — output directory for summary JSON

DUT=/dut/openvm-binary
ZKVM=openvm
RESULTS=/results
WORKDIR=/act4/work

if [ ! -x "$DUT" ]; then
    echo "Error: No executable found at $DUT"
    exit 1
fi

cd /act4
mkdir -p "$RESULTS"
JOBS="${ACT4_JOBS:-$(nproc)}"

# Create wrapper script for running OpenVM
# OpenVM requires Cargo.toml + openvm.toml in CWD to function.
# We create a temp directory with these files for each invocation.
cat > /act4/run-dut.sh << 'WRAPPER'
#!/bin/bash
ELF_PATH="$(realpath "$1")"
TMPDIR=$(mktemp -d)
printf '[package]\nname = "act4-test"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' > "$TMPDIR/Cargo.toml"
printf 'app_vm_config = { exe = "%s" }\n' "$ELF_PATH" > "$TMPDIR/openvm.toml"
cd "$TMPDIR"
/dut/openvm-binary openvm run --exe "$ELF_PATH"
EC=$?
cd /
rm -rf "$TMPDIR"
exit $EC
WRAPPER
chmod +x /act4/run-dut.sh

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
    # The 'act' tool reads the DUT config, generates a Makefile, then invokes Sail
    # to compute expected register values which are baked directly into the ELFs.
    echo ""
    echo "=== Generating Makefiles for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
    # Must compile from top-level workdir so common ELF dependencies are built first.
    make -C "$WORKDIR" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi
    # Post-process ELFs: strip RVC flag, replace non-instruction data words and CSR
    # instructions with NOPs so OpenVM's transpiler doesn't panic. See patch_elfs.py.
    python3 /act4/patch_elfs.py "$ELF_DIR"
    echo "=== Running $ELF_COUNT tests with OpenVM ($CONFIG_NAME) ==="

    # run_tests.py exits 0 if all pass, 1 if any fail.
    # Capture output for parsing; allow non-zero exit.
    local RUN_OUTPUT
    RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1) || true
    echo "$RUN_OUTPUT"

    # Parse results from run_tests.py output.
    # Possible formats:
    #   "\tX out of N tests failed."  → X failures, N total
    #   "\tAll N tests passed."       → 0 failures, N total
    local FAILED TOTAL PASSED
    FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
    TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
    PASSED=$((TOTAL - FAILED))

    cat > "$RESULTS/summary-act4${SUFFIX}.json" << EOF
{
  "zkvm": "$ZKVM",
  "suite": "act4${SUFFIX}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

    # Generate per-test results JSON (enumerate ELFs, mark failed ones).
    # Pass authoritative PASSED count so tests that failed silently (timeout/kill)
    # are not incorrectly marked as passed.
    python3 -c "
import json, os, re

elf_dir = '$ELF_DIR'
run_output = '''$RUN_OUTPUT'''
expected_passed = $PASSED

# Parse failed test names from run_tests.py output
failed_names = set()
for line in run_output.splitlines():
    m = re.match(r'\tTest (\S+\.elf) failed', line)
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

# Cross-check: if parsed pass count doesn't match the authoritative count,
# some tests failed silently (timeout/OOM). Mark all as failed since we
# can't reliably distinguish which ones truly passed.
parsed_passed = sum(1 for t in tests if t['passed'])
if parsed_passed != expected_passed:
    for t in tests:
        t['passed'] = False

with open('$RESULTS/results-act4${SUFFIX}.json', 'w') as out:
    json.dump({
        'zkvm': '$ZKVM',
        'suite': 'act4${SUFFIX}',
        'tests': tests
    }, out, indent=2)

print(f'Per-test results: {len(tests)} tests written to results-act4${SUFFIX}.json')
"

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
}

# Run each suite; allow failures without aborting (set -e is active globally)
# ─── Run 1: Native ISA (rv32im) ───
run_act4_suite \
    "config/openvm/openvm-rv32im/test_config.yaml" \
    "openvm-rv32im" \
    "I,M" \
    "$(printf 'I\nM\nZicsr\nSm')" \
    "" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/openvm/openvm-rv64im-zicclsm/test_config.yaml" \
    "openvm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "-target" || true

echo ""
echo "=== All ACT4 suites complete ==="
