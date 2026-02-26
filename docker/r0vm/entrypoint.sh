#!/bin/bash
set -eu

# ACT4 r0vm test runner
#
# Expected mounts:
#   /dut/r0vm-binary               — the r0vm binary (with --execute-only flag)
#   /act4/config/r0vm              — r0vm ACT4 config directory (host act4-configs/r0vm)
#   /results/                      — output directory for summary JSON

DUT=/dut/r0vm-binary
RESULTS=/results
WORKDIR=/act4/work

if [ ! -x "$DUT" ]; then
    echo "Error: No executable found at $DUT"
    exit 1
fi

cd /act4
mkdir -p "$RESULTS"
JOBS="${ACT4_JOBS:-$(nproc)}"

# Wrapper: runs r0vm in execute-only mode on the ELF directly.
# Must use --test-elf (not --elf): --elf expects risc0's custom ProgramBinary format,
# while --test-elf calls from_kernel_elf() which loads a standard RISC-V ELF.
# --execute-only: skip ZK proving; exit with guest exit code (0=pass, 1=fail, 2=timeout).
cat > /act4/run-dut.sh << 'WRAPPER'
#!/bin/bash
ELF="$1"
/dut/r0vm-binary --test-elf "$ELF" --execute-only
exit $?
WRAPPER
chmod +x /act4/run-dut.sh

# run_act4_suite <config-path> <config-name> <extensions-list> <extensions-txt-entries> <summary-suffix>
#
# Generates Makefiles, compiles ELFs, runs them, and writes summary + per-test JSON.
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

    echo ""
    echo "=== Generating Makefiles for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
    make -C "$WORKDIR" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi
    echo "=== Running $ELF_COUNT tests with r0vm ($CONFIG_NAME) ==="

    local RUN_OUTPUT
    RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1) || true
    echo "$RUN_OUTPUT"

    local FAILED TOTAL PASSED
    FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
    TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
    PASSED=$((TOTAL - FAILED))

    cat > "$RESULTS/summary-act4${SUFFIX}.json" << EOF
{
  "zkvm": "r0vm",
  "suite": "act4${SUFFIX}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

    # Generate per-test results JSON
    python3 -c "
import json, os, re

elf_dir = '$ELF_DIR'
run_output = '''$RUN_OUTPUT'''
expected_passed = $PASSED

failed_names = set()
for line in run_output.splitlines():
    m = re.match(r'\tTest (\S+\.elf) failed', line)
    if m:
        failed_names.add(m.group(1))

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

parsed_passed = sum(1 for t in tests if t['passed'])
if parsed_passed != expected_passed:
    for t in tests:
        t['passed'] = False

with open('$RESULTS/results-act4${SUFFIX}.json', 'w') as out:
    json.dump({
        'zkvm': 'r0vm',
        'suite': 'act4${SUFFIX}',
        'tests': tests
    }, out, indent=2)

print(f'Per-test results: {len(tests)} tests written to results-act4${SUFFIX}.json')
"

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
}

# ─── Run 1: Native ISA (rv32im) ───
run_act4_suite \
    "config/r0vm/r0vm-rv32im/test_config.yaml" \
    "r0vm-rv32im" \
    "I,M" \
    "$(printf 'I\nM\nZicsr\nSm')" \
    "" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/r0vm/r0vm-rv64im-zicclsm/test_config.yaml" \
    "r0vm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "-target" || true

echo ""
echo "=== All ACT4 suites complete ==="
