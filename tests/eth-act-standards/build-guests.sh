#!/bin/bash
# Build the eth-act standards test guest ELFs for one platform.
#
# Usage: build-guests.sh <platform> <out-dir>
#
# Every <group>/<name>.c becomes <out-dir>/<group>/<name>.elf. The test
# vectors <name>.input, <name>.expected and <name>.outcome are copied next to
# the ELF; a group
# may instead write them with <group>/write_io_vectors.py <out-dir>/<group>.
# A source that contains the marker "eth-act-standards: link-decoy-memops" is linked
# with a decoy archive of weak memory functions placed before the vendor library.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLATFORM="${1:?usage: build-guests.sh <platform> <out-dir>}"
OUT="${2:?usage: build-guests.sh <platform> <out-dir>}"
PLATFORM_DIR="$HERE/platforms/$PLATFORM"
# The standard headers come from the eth-act/zkevm-standards submodule.
STANDARDS="$HERE/external/zkevm-standards/standards"
INCLUDES="-I $HERE/include -I $STANDARDS/io-interface -I $STANDARDS/c-interface-accelerators"

# shellcheck source=/dev/null
source "$PLATFORM_DIR/platform.sh"

if [ ! -f "$VENDOR_LIB" ]; then
  echo "error: vendor library not found: $VENDOR_LIB" >&2
  exit 1
fi

if [ ! -f "$STANDARDS/io-interface/zkvm_io.h" ]; then
  echo "error: $STANDARDS is empty; run 'git submodule update --init tests/eth-act-standards/external/zkevm-standards'" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck disable=SC2086
$CC $CFLAGS -c "$HERE/tools/decoy_memops.c" -o "$WORK/decoy_memops.o"
$AR rcs "$WORK/libdecoy_memops.a" "$WORK/decoy_memops.o"

count=0
for src in "$HERE"/*/*.c; do
  group=$(basename "$(dirname "$src")")
  [ "$group" = "tools" ] && continue
  name=$(basename "$src" .c)
  mkdir -p "$OUT/$group"

  pre_libs=""
  if grep -q "eth-act-standards: link-decoy-memops" "$src"; then
    pre_libs="$WORK/libdecoy_memops.a"
  fi

  # shellcheck disable=SC2086
  $CC $CFLAGS $INCLUDES "$src" ${LINKER_SCRIPT:+-T "$LINKER_SCRIPT"} $LDFLAGS \
    $pre_libs "$VENDOR_LIB" $LIBS -o "$OUT/$group/$name.elf"

  for vector in input expected outcome; do
    if [ -f "$HERE/$group/$name.$vector" ]; then
      cp "$HERE/$group/$name.$vector" "$OUT/$group/$name.$vector"
    fi
  done
  count=$((count + 1))
done

for gen in "$HERE"/*/write_io_vectors.py; do
  [ -f "$gen" ] || continue
  group=$(basename "$(dirname "$gen")")
  python3 "$gen" "$OUT/$group"
done

echo "Built $count eth-act standards test ELFs for $PLATFORM in $OUT"
