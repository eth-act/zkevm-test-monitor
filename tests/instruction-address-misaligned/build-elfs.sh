#!/bin/bash
# Build the instruction-address-misaligned tests for one zkVM as ACT4 assembly tests.
#
# Usage: build-elfs.sh <test_config.yaml> <out-dir>
#
# src/generate_elfs.sh runs this in the zkVM's ACT4 image (zkvms/<zkvm>/act4.Dockerfile),
# with this directory mounted at /misaligned-tests and zkvms/<zkvm>/isa-configs at
# /act4/config/<zkvm>. <test_config.yaml> is the zkVM's rv64im-zicclsm config,
# relative to /act4.
#
# Every <name>.S becomes <out-dir>/<name>.elf, with <name>.outcome and
# <name>.control copied next to it. The tests have NEEDS_SIGNATURE: false, so ACT
# compiles them without the reference model (Sail would trap at the misaligned jump).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CONFIG="${1:?usage: build-elfs.sh <test_config.yaml> <out-dir>}"
OUT="${2:?usage: build-elfs.sh <test_config.yaml> <out-dir>}"
GROUP=instruction-address-misaligned

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Test tree in ACT's layout: env/ from ACT, and the tests in one group.
mkdir -p "$WORK/tests/rv64i/$GROUP"
cp -r /act4/tests/env "$WORK/tests/env"
cp "$HERE"/*.S "$WORK/tests/rv64i/$GROUP/"

cd /act4
uv run act "$CONFIG" --workdir "$WORK/act" --test-dir "$WORK/tests" --extensions "$GROUP"

CONFIG_NAME=$(sed -n 's/^name: *\([^ ]*\).*/\1/p' "$CONFIG")
ELF_DIR="$WORK/act/$CONFIG_NAME/elfs/rv64i/$GROUP"
# The zkVMs decode every word of an executable segment, so replace the data
# words in executable sections with NOPs, as for the ISA tests.
python3 /act4/patch_elfs.py "$ELF_DIR"

mkdir -p "$OUT"
count=0
for src in "$HERE"/*.S; do
  name=$(basename "$src" .S)
  # cat, not cp: ACT's build cache may leave the ELFs as symlinks.
  cat "$ELF_DIR/$name.elf" > "$OUT/$name.elf"
  for vector in outcome control; do
    if [ -f "$HERE/$name.$vector" ]; then
      cp "$HERE/$name.$vector" "$OUT/$name.$vector"
    fi
  done
  count=$((count + 1))
done

echo "Built $count instruction-address-misaligned test ELFs in $OUT"
