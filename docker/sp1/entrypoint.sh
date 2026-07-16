#!/bin/bash
set -eu

# ACT4 SP1 ELF generator (split pipeline).
#
# Compiles the self-checking ELFs for the native (I,M) and target (I,M,Misalign)
# suites, patches them, and copies them to the /elfs mount. Test execution +
# GPU proving happen on the HOST via act4-runner (the GPU is not available inside
# this container), so no DUT binary is needed here.
#
# patch_elfs.py replaces embedded data words in executable sections with NOPs —
# SP1 pre-processes every word in an executable segment as an instruction and
# panics on the .word string pointers ACT4 emits after failedtest_* calls.
#
# Expected mounts:
#   /act4/config/sp1  — SP1 ACT4 config directory (host act4-configs/sp1)
#   /elfs/            — output directory for compiled+patched ELFs (native/, target/)

ZKVM=sp1
cd /act4

# generate_elfs <config-path> <config-name> <extensions> <extensions-txt> <output-subdir> <workdir>
#
# SP1 uses one DUT config for both suites, so each suite gets its own workdir to
# avoid clobbering the other's compiled ELFs.
generate_elfs() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local OUTPUT_SUBDIR="$5"
    local SUITE_WORKDIR="$6"

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $OUTPUT_SUBDIR"
        return
    fi

    # Pre-generate extensions.txt to skip UDB validation (needs Podman/Docker
    # inside the container). ACT skips UDB when this file exists and is newer.
    mkdir -p "$SUITE_WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$SUITE_WORKDIR/$CONFIG_NAME/extensions.txt"
    touch -t 209901010000 "$SUITE_WORKDIR/$CONFIG_NAME/extensions.txt"

    echo ""
    echo "=== Generating self-checking ELFs for $OUTPUT_SUBDIR ($CONFIG_NAME) ==="
    uv run act "$CONFIG" \
        --workdir "$SUITE_WORKDIR" \
        --test-dir tests \
        --extensions "$EXTENSIONS"

    local ELF_DIR="$SUITE_WORKDIR/$CONFIG_NAME/elfs"

    local ELF_COUNT
    ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$ELF_COUNT" -eq 0 ]; then
        echo "Error: No ELFs found in $ELF_DIR after compilation"
        return
    fi

    # Post-process ELFs so SP1's transpiler doesn't panic on data words.
    python3 /act4/patch_elfs.py "$ELF_DIR"
    echo "=== $ELF_COUNT ELFs compiled for $OUTPUT_SUBDIR ==="

    # Copy ELFs to output (find+cat to dereference ACT's build-cache symlinks
    # reliably; cp -rL can fail with "same file" on the mount destination).
    find "$ELF_DIR" -name "*.elf" | while read -r src; do
        rel="${src#$ELF_DIR/}"
        dst="/elfs/$OUTPUT_SUBDIR/$rel"
        mkdir -p "$(dirname "$dst")"
        cat "$src" > "$dst"
    done
    local COPIED
    COPIED=$(find "/elfs/$OUTPUT_SUBDIR" -name "*.elf" 2>/dev/null | wc -l)
    echo "=== Copied $COPIED ELFs to /elfs/$OUTPUT_SUBDIR/ ==="
}

# --- Main ---

if ! mountpoint -q /elfs 2>/dev/null && [ ! -d /elfs ]; then
    echo "Error: /elfs not mounted — this image only generates ELFs for the host runner"
    exit 1
fi

echo "=== ELF generation mode ==="
mkdir -p /elfs

# Native ISA (full-isa): I, M
generate_elfs \
    "config/sp1/sp1-rv64im-zicclsm/test_config.yaml" \
    "sp1-rv64im-zicclsm" \
    "I,M" \
    "$(printf 'I\nM\nZicsr\nSm')" \
    "native" \
    "/act4/work-native" || true

# ETH-ACT target ISA (standard-isa): I, M, Misalign
generate_elfs \
    "config/sp1/sp1-rv64im-zicclsm/test_config.yaml" \
    "sp1-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
    "target" \
    "/act4/work-target" || true

echo ""
echo "=== ELF generation complete ==="
