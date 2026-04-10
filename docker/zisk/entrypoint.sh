#!/bin/bash
set -eu

# ACT4 Zisk ELF generator + optional legacy test runner
#
# Modes:
#   ELF generation (default when /elfs is mounted):
#     Compiles self-checking ELFs and copies them to /elfs mount.
#     No DUT binary needed — test execution happens on host via act4-runner.
#
#   Legacy test runner (when /dut/zisk-binary exists and /elfs is NOT mounted):
#     Runs tests inside Docker as before (backward compatible).
#
# Expected mounts:
#   /act4/config/zisk               — Zisk ACT4 config directory (host act4-configs/zisk)
#   /elfs/                          — (ELF mode) output directory for compiled ELFs
#   /dut/zisk-binary                — (legacy mode) the Zisk CLI binary (ziskemu)
#   /results/                       — (legacy mode) output directory for summary JSON

ZKVM=zisk
WORKDIR=/act4/work

cd /act4

# Determine parallelism for compilation
if [ -n "${ACT4_JOBS:-}" ]; then
    JOBS="$ACT4_JOBS"
else
    AVAIL_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    SAFE_JOBS=$(( AVAIL_MB * 80 / 100 / 8192 ))
    [ "$SAFE_JOBS" -lt 1 ] && SAFE_JOBS=1
    [ "$SAFE_JOBS" -gt 24 ] && SAFE_JOBS=24
    JOBS="$SAFE_JOBS"
    echo "Auto-scaled to $JOBS parallel jobs (${AVAIL_MB} MB available)"
fi

# generate_elfs <config-path> <config-name> <extensions-list> <extensions-txt-entries> <output-subdir>
#
# Generates Makefiles, compiles self-checking ELFs, patches them, and copies to output.
generate_elfs() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local OUTPUT_SUBDIR="$5"

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return
    fi

    # Pre-generate extensions.txt to skip UDB validation
    mkdir -p "$WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
    touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

    echo ""
    echo "=== Generating Makefiles for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
    make -C "$WORKDIR" -j "$JOBS" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"

    # NOP out the 6 lhu reads in failedtest_saveresults that read from .text.init.
    echo "=== Patching ELFs ($CONFIG_NAME) ==="
    python3 /act4/patch_elfs.py --zisk "$ELF_DIR"

    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi
    echo "=== $ELF_COUNT ELFs compiled for $CONFIG_NAME ==="

    # Copy ELFs to output (use find+cat to dereference symlinks reliably —
    # cp -rL fails with "same file" when ACT4's common build cache creates
    # symlinks that resolve to the same inode as the mount destination).
    if [ -n "$OUTPUT_SUBDIR" ]; then
        local COPIED=0
        find "$ELF_DIR" -name "*.elf" | while read -r src; do
            rel="${src#$ELF_DIR/}"
            dst="/elfs/$OUTPUT_SUBDIR/$rel"
            mkdir -p "$(dirname "$dst")"
            cat "$src" > "$dst"
        done
        COPIED=$(find "/elfs/$OUTPUT_SUBDIR" -name "*.elf" 2>/dev/null | wc -l)
        echo "=== Copied $COPIED ELFs to /elfs/$OUTPUT_SUBDIR/ ==="
    fi
}

# run_act4_suite <config-path> <config-name> <extensions-list> <extensions-txt-entries> <summary-suffix>
#
# Legacy mode: generates ELFs and runs them with the DUT binary.
run_act4_suite() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local SUFFIX="$5"
    local FILE_LABEL
    if [ -z "$SUFFIX" ]; then
        FILE_LABEL="full-isa"
    else
        FILE_LABEL="standard-isa"
    fi

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return
    fi

    mkdir -p "$WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
    touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

    echo ""
    echo "=== Generating Makefiles for $CONFIG_NAME ==="
    uv run act "$CONFIG" \
        --workdir "$WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
    make -C "$WORKDIR" -j "$JOBS" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"

    echo "=== Patching ELFs ($CONFIG_NAME) ==="
    python3 /act4/patch_elfs.py --zisk "$ELF_DIR"
    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi
    echo "=== Running $ELF_COUNT tests with Zisk ($CONFIG_NAME) ==="

    local RUN_OUTPUT
    RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1) || true
    echo "$RUN_OUTPUT"

    local FAILED TOTAL PASSED
    FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
    TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
    PASSED=$((TOTAL - FAILED))

    local RESULTS=/results
    mkdir -p "$RESULTS"

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

    python3 -c "
import json, os, re

elf_dir = '$ELF_DIR'
run_output = '''$RUN_OUTPUT'''
expected_passed = $PASSED
zkvm = '$ZKVM'

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
        'zkvm': zkvm,
        'suite': 'act4${SUFFIX}',
        'tests': tests
    }, out, indent=2)

print(f'Per-test results: {len(tests)} tests written to results-act4-${FILE_LABEL}.json')
"

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
}

# --- Main ---

# Detect mode: if /elfs is a mount point, generate ELFs only; otherwise run legacy pipeline.
# When Docker mounts -v host:/elfs, mountpoint detects it. If no mount, fall back to
# checking whether the DUT binary is absent (pure ELF-gen mode without Docker mount).
if mountpoint -q /elfs 2>/dev/null; then
    echo "=== ELF generation mode ==="
    mkdir -p /elfs

    # Native ISA
    generate_elfs \
        "config/zisk/zisk-rv64im/test_config.yaml" \
        "zisk-rv64im" \
        "I,M,F,D,Zca,Zcf,Zcd,Zaamo,Zalrsc" \
        "$(printf 'I\nM\nZaamo\nZalrsc\nF\nD\nZca\nZcd\nZicsr\nSm')" \
        "native" || true

    # Target ISA
    generate_elfs \
        "config/zisk/zisk-rv64im-zicclsm/test_config.yaml" \
        "zisk-rv64im-zicclsm" \
        "I,M,Misalign" \
        "$(printf 'I\nM\nZicclsm\nMisalign')" \
        "target" || true

    echo ""
    echo "=== ELF generation complete ==="
else
    # Legacy mode: run tests inside Docker
    DUT=/dut/zisk-binary
    if [ ! -x "$DUT" ]; then
        echo "Error: No executable found at $DUT"
        exit 1
    fi

    # Create wrapper script for Zisk
    cat > /act4/run-dut.sh << 'WRAPPER'
#!/bin/bash
/dut/zisk-binary -e "$1" > /dev/null
WRAPPER
    chmod +x /act4/run-dut.sh

    run_act4_suite \
        "config/zisk/zisk-rv64im/test_config.yaml" \
        "zisk-rv64im" \
        "I,M,F,D,Zca,Zcf,Zcd,Zaamo,Zalrsc" \
        "$(printf 'I\nM\nZaamo\nZalrsc\nF\nD\nZca\nZcd\nZicsr\nSm')" \
        "" || true

    run_act4_suite \
        "config/zisk/zisk-rv64im-zicclsm/test_config.yaml" \
        "zisk-rv64im-zicclsm" \
        "I,M,Misalign" \
        "$(printf 'I\nM\nZicclsm\nMisalign')" \
        "-target" || true

    echo ""
    echo "=== All ACT4 suites complete ==="
fi
