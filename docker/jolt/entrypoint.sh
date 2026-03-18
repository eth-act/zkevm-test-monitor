#!/bin/bash
set -eu

# ACT4 Jolt test runner
#
# Modes:
#   ELF-only mode: mount /elfs → generates ELFs and copies them to /elfs/{native,target}
#   Legacy mode:   mount /dut/jolt-binary + /results → generates ELFs, runs tests, writes JSON
#
# Expected mounts (legacy):
#   /dut/jolt-binary                — the Jolt CLI binary (ELF is positional arg)
#   /act4/config/jolt               — Jolt ACT4 config directory (host act4-configs/jolt)
#   /results/                       — output directory for summary JSON
#
# Expected mounts (ELF-only):
#   /act4/config/jolt               — Jolt ACT4 config directory
#   /elfs/                          — output directory for generated ELFs

ZKVM=jolt
WORKDIR=/act4/work

# Detect ELF-generation-only mode (split pipeline)
ELF_ONLY=0
if [ -d "/elfs" ]; then
    ELF_ONLY=1
fi

# In legacy mode, require the DUT binary
if [ "$ELF_ONLY" = "0" ]; then
    DUT=/dut/jolt-binary
    RESULTS=/results
    if [ ! -x "$DUT" ]; then
        echo "Error: No executable found at $DUT"
        exit 1
    fi
    mkdir -p "$RESULTS"
fi

cd /act4
JOBS="${ACT4_JOBS:-$(nproc)}"


# generate_elfs <config-path> <config-name> <extensions-list> <extensions-txt-entries> <elf-output-label>
#
# Generates Makefiles and compiles self-checking ELFs.
# elf-output-label: "native" or "target" (used for /elfs/ subdirectory in ELF-only mode)
generate_elfs() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return 1
    fi

    # Pre-generate extensions.txt to skip UDB validation (which requires Podman/Docker
    # inside the container). The ACT framework skips UDB calls when this file exists
    # and is newer than the UDB config.
    mkdir -p "$WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
    # Touch with future timestamp to ensure it's always newer than the mounted config
    touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

    # Generate and compile self-checking ELFs.
    # The 'act' tool generates Makefiles, invokes Sail for expected values,
    # and compiles ELFs in one step.
    echo ""
    echo "=== Generating self-checking ELFs for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return 1
    fi
    echo "=== Generated $ELF_COUNT ELFs for $CONFIG_NAME ==="

    # Patch data words in .text with NOPs for prover compatibility.
    # ACT4's SELFCHECK embeds .dword pointers after jal failedtest_* calls;
    # jolt's prover pre-scans all .text bytes as instructions and panics on these.
    echo "=== Patching ELFs for $CONFIG_NAME (replacing data words with NOPs) ==="
    python3 /act4/patch_elfs.py "$ELF_DIR"

    # Wrap ELFs with jolt ZeroOS boot code for prover compatibility.
    # Appends boot code as a new LOAD segment and sets entry point.
    if [ -f /act4/boot.bin ]; then
        echo "=== Wrapping ELFs with jolt boot code for $CONFIG_NAME ==="
        python3 /act4/wrap_boot.py /act4/boot.bin "$ELF_DIR"
    fi
}

# run_act4_suite <config-path> <config-name> <extensions-list> <extensions-txt-entries> <summary-suffix> <elf-output-label>
#
# Generates ELFs, runs them (legacy) or copies them (ELF-only), and writes results.
run_act4_suite() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local SUFFIX="$5"
    local OUTPUT_LABEL="$6"
    # Derive file label from suffix
    local FILE_LABEL
    if [ -z "$SUFFIX" ]; then
        FILE_LABEL="full-isa"
    else
        FILE_LABEL="standard-isa"
    fi

    generate_elfs "$CONFIG" "$CONFIG_NAME" "$EXTENSIONS" "$EXT_TXT" || return

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"

    # ELF-only mode: copy ELFs to output and return
    if [ "$ELF_ONLY" = "1" ]; then
        mkdir -p "/elfs/$OUTPUT_LABEL"
        cp -rL "$ELF_DIR"/* "/elfs/$OUTPUT_LABEL/"
        local COUNT
        COUNT=$(find "/elfs/$OUTPUT_LABEL" -name "*.elf" | wc -l)
        echo "=== Copied $COUNT ELFs to /elfs/$OUTPUT_LABEL ==="
        return
    fi

    # Legacy mode: run tests and write results
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    echo "=== Running $ELF_COUNT tests with Jolt ($CONFIG_NAME) ==="

    # run_tests.py exits 0 if all pass, 1 if any fail.
    local RUN_OUTPUT
    RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT" "$ELF_DIR" -j "$JOBS" 2>&1) || true
    echo "$RUN_OUTPUT"

    # Parse results from run_tests.py output.
    local FAILED TOTAL PASSED
    FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
    TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
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

with open('$RESULTS/results-act4-${FILE_LABEL}.json', 'w') as out:
    json.dump({
        'zkvm': '$ZKVM',
        'suite': 'act4${SUFFIX}',
        'tests': tests
    }, out, indent=2)

print(f'Per-test results: {len(tests)} tests written to results-act4-${FILE_LABEL}.json')
"

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
}

# Run each suite; allow failures without aborting (set -e is active globally)
# ─── Run 1: Native ISA (rv64im) ───
run_act4_suite \
    "config/jolt/jolt-rv64im/test_config.yaml" \
    "jolt-rv64im" \
    "I,M,Zaamo,Zalrsc,Zca" \
    "$(printf 'I\nM\nZaamo\nZalrsc\nZca\nZicsr\nSm')" \
    "" \
    "native" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/jolt/jolt-rv64im-zicclsm/test_config.yaml" \
    "jolt-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "-target" \
    "target" || true

echo ""
echo "=== All ACT4 suites complete ==="
