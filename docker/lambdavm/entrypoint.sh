#!/bin/bash
set -eu

# ACT4 LambdaVM test runner
#
# Modes:
#   ELF-only mode: mount /elfs → generates ELFs and copies them to /elfs/{native,target}
#   Legacy mode:   mount /dut/lambdavm-binary + /results → generates ELFs, runs tests, writes JSON
#
# Expected mounts (legacy):
#   /dut/lambdavm-binary            — the LambdaVM cli binary
#   /act4/config/lambdavm           — LambdaVM ACT4 config directory (host act4-configs/lambdavm)
#   /results/                       — output directory for summary JSON
#
# Expected mounts (ELF-only):
#   /act4/config/lambdavm           — LambdaVM ACT4 config directory
#   /elfs/                          — output directory for generated ELFs

ZKVM=lambdavm
WORKDIR=/act4/work

# Detect ELF-generation-only mode (split pipeline)
ELF_ONLY=0
if [ -d "/elfs" ]; then
    ELF_ONLY=1
fi

# In legacy mode, require the DUT binary
if [ "$ELF_ONLY" = "0" ]; then
    DUT=/dut/lambdavm-binary
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

    # Generate self-checking ELFs. The 'act' tool generates the Makefiles
    # (invoking Sail for expected values); `make compile` then builds the ELFs.
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

    # Patch non-instruction data words in executable sections with NOPs.
    # LambdaVM's InstructionCache decodes every word of every executable segment
    # at construction time; ACT4 embeds .word data after jal failedtest_* calls,
    # which would otherwise fail to decode (UnknownOpcode).
    echo "=== Patching ELFs for $CONFIG_NAME (replacing data words with NOPs) ==="
    python3 /act4/patch_elfs.py "$ELF_DIR"
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
    echo "=== Running $ELF_COUNT tests with LambdaVM ($CONFIG_NAME) ==="

    local PASSED=0
    local FAILED=0
    local FAILED_NAMES=""
    while IFS= read -r elf; do
        if "$DUT" execute "$elf" > /dev/null 2>&1; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_NAMES="$FAILED_NAMES $(basename "$elf")"
        fi
    done < <(find "$ELF_DIR" -name "*.elf" | sort)
    local TOTAL=$((PASSED + FAILED))

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

    echo ""
    echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
    [ -n "$FAILED_NAMES" ] && echo "    Failed:$FAILED_NAMES"
}

# Run each suite; allow failures without aborting (set -e is active globally)
# ─── Run 1: Native ISA (rv64im-zicclsm) ───
# LambdaVM natively supports Zicclsm (misaligned LD/ST), so include Misalign tests.
run_act4_suite \
    "config/lambdavm/lambdavm-rv64im-zicclsm/test_config.yaml" \
    "lambdavm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "" \
    "native" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/lambdavm/lambdavm-rv64im-zicclsm/test_config.yaml" \
    "lambdavm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "-target" \
    "target" || true

echo ""
echo "=== All ACT4 suites complete ==="
