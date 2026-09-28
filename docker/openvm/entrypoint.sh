#!/bin/bash
set -eu

# ACT4 OpenVM ELF generator (split pipeline).
#
# Compiles self-checking ELFs and copies them to /elfs/{native,target}. Test
# execution happens on the host via act4-runner, so no DUT binary is needed here.
#
# Expected mounts:
#   /act4/config/openvm             — OpenVM ACT4 config directory (host act4-configs/openvm)
#   /elfs/                          — output directory for generated ELFs

ZKVM=openvm
WORKDIR=/act4/work

if [ ! -d /elfs ]; then
    echo "Error: /elfs not mounted — this image only generates ELFs for the host runner"
    exit 1
fi

cd /act4

# generate_elfs <config-path> <config-name> <extensions-list>
#
# Compiles self-checking ELFs (act runs UDB validation, Sail and GCC) and patches them.
generate_elfs() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return 1
    fi

    # Generate self-checking ELFs. The 'act' tool builds the ELFs directly
    # (invoking Sail for expected values).
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

    # Patch non-instruction data words in executable sections with NOPs. OpenVM's
    # transpiler pre-decodes every word of every executable segment; ACT4 embeds
    # .word data after jal failedtest_* calls, which would otherwise make the
    # transpiler panic. See patch_elfs.py.
    echo "=== Patching ELFs for $CONFIG_NAME (replacing data words with NOPs) ==="
    python3 /act4/patch_elfs.py "$ELF_DIR"
}

# run_act4_suite <config-path> <config-name> <extensions-list> <elf-output-label>
#
# Generates ELFs and copies them to /elfs/<elf-output-label>.
run_act4_suite() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local OUTPUT_LABEL="$4"

    generate_elfs "$CONFIG" "$CONFIG_NAME" "$EXTENSIONS" || return

    local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
    mkdir -p "/elfs/$OUTPUT_LABEL"
    cp -rL "$ELF_DIR"/* "/elfs/$OUTPUT_LABEL/"
    local COUNT
    COUNT=$(find "/elfs/$OUTPUT_LABEL" -name "*.elf" | wc -l)
    echo "=== Copied $COUNT ELFs to /elfs/$OUTPUT_LABEL ==="
}

# Run each suite; allow failures without aborting (set -e is active globally)
# ─── Run 1: Native ISA (rv64im) ───
run_act4_suite \
    "config/openvm/openvm-rv64im/test_config.yaml" \
    "openvm-rv64im" \
    "I,M" \
    "native" || true

# ─── Run 2: ETH-ACT Target (rv64im-zicclsm) ───
run_act4_suite \
    "config/openvm/openvm-rv64im-zicclsm/test_config.yaml" \
    "openvm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "target" || true

echo ""
echo "=== ELF generation complete ==="
