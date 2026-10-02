#!/bin/bash
set -eu

# ACT4 Zisk ELF generator (split pipeline).
#
# Compiles self-checking ELFs and copies them to the /elfs mount. No DUT binary
# is needed — test execution happens on the host via src/runner/.
#
# Expected mounts:
#   /act4/config/zisk               — Zisk ACT4 config directory (host zkvms/zisk/isa-configs)
#   /elfs/                          — output directory for compiled ELFs

ZKVM=zisk
WORKDIR=/act4/work

cd /act4

# generate_elfs <config-path> <config-name> <extensions-list> <output-subdir>
#
# Compiles self-checking ELFs (act runs UDB validation, Sail and GCC), patches them,
# and copies them to output.
generate_elfs() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local OUTPUT_SUBDIR="$4"

    if [ ! -f "/act4/$CONFIG" ]; then
        echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
        return
    fi

    # Install the minimal failure handler. riscv_arch_test.h includes
    # "rvtest_failure_code.h" with quotes, so tests/env/ wins over dut_include_dir.
    # The default handler reads the words that patch_elfs.py replaces with NOPs.
    cp "/act4/$(dirname "$CONFIG")/rvtest_failure_code.h" /act4/tests/env/rvtest_failure_code.h

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
        return
    fi
    echo "=== $ELF_COUNT ELFs compiled for $CONFIG_NAME ==="

    # Post-process ELFs so ZisK >= 1.2's transpiler doesn't panic on data words
    # (it decodes ACT4's .word string pointers as compressed instructions).
    python3 /act4/patch_elfs.py "$ELF_DIR"

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

# --- Main ---

if ! mountpoint -q /elfs 2>/dev/null && [ ! -d /elfs ]; then
    echo "Error: /elfs not mounted — this image only generates ELFs for the host runner"
    exit 1
fi

echo "=== ELF generation mode ==="
mkdir -p /elfs

# Native ISA
generate_elfs \
    "config/zisk/zisk-rv64im/test_config.yaml" \
    "zisk-rv64im" \
    "I,M,F,D,Zca,Zcf,Zcd,Zaamo,Zalrsc" \
    "native" || true

# Target ISA
generate_elfs \
    "config/zisk/zisk-rv64im-zicclsm/test_config.yaml" \
    "zisk-rv64im-zicclsm" \
    "I,M,Misalign" \
    "target" || true

echo ""
echo "=== ELF generation complete ==="
