#!/bin/bash
# Build the runtime guests of the eth-act standards tests for one zkVM, and
# check its static library and linker script (the static library and linker
# script standard).
#
# Usage: build-runtime-guests.sh <zkvm> <out-dir>
#
# Runs inside the runtime image (runtime.Dockerfile), with these mounts:
#   /eth-act-standards-tests  this directory (read-only)
#   /platform                 zkvms/<zkvm>/standards (read-only)
#   /vendor                   the zkVM's C library, and its own linker script if
#                             it publishes one (read-only)
#   /zkevm-standards          eth-act/zkevm-standards at the pinned commit (read-only)
#
# The runtime guests runtime/*.c and runtime/*.cpp are plain C and C++
# programs, not ACT4 tests. Each one links only the vendor library, with the
# vendor's linker script unchanged (without link.ld.patch), once with GNU ld
# (<out-dir>/runtime/<name>.elf) and once with LLD
# (<out-dir>/runtime-lld/<name>-lld.elf). <name>.expected is copied next to
# each ELF. A zkVM that publishes no linker script (OpenVM) links with its
# link-args instead.
#
# A guest that does not link has no ELF: the linker's output goes to
# <name>.link-error instead. The probe library/rt-segments.c is linked the same
# way to <out-dir>/library/rt-segments.probe and rt-segments-lld.probe (it does
# not run). Last, tools/check_static_library.py checks the library, the linker
# script and the ELFs, and writes its verdicts and a failed test for each guest
# that did not link to <out-dir>/library/static-results.json.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ZKVM="${1:?usage: build-runtime-guests.sh <zkvm> <out-dir>}"
OUT="${2:?usage: build-runtime-guests.sh <zkvm> <out-dir>}"
PLATFORM_DIR="/platform"
STANDARDS="/zkevm-standards/standards"

if [ ! -f "$STANDARDS/io-interface/zkvm_io.h" ]; then
  echo "error: $STANDARDS has no zkvm_io.h; mount eth-act/zkevm-standards at /zkevm-standards" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

shopt -s nullglob
VENDOR_LIBS=(/vendor/*.a)
if [ "${#VENDOR_LIBS[@]}" -ne 1 ]; then
  echo "error: expected one vendor library in /vendor" >&2
  exit 1
fi
VENDOR_LIB="${VENDOR_LIBS[0]}"
VENDOR_LDS=(/vendor/*.ld)
if [ "${#VENDOR_LDS[@]}" -gt 1 ]; then
  echo "error: expected at most one linker script in /vendor" >&2
  exit 1
fi
VENDOR_LD="${VENDOR_LDS[0]:-}"
shopt -u nullglob

# The layout of the link: the vendor's linker script, unchanged. Without one,
# the zkVM's own link arguments, as build-guests.sh uses them.
if [ -n "$VENDOR_LD" ]; then
  LAYOUT=(-T "$VENDOR_LD")
else
  echo "note: the zkVM supplies no linker script; the guests link with $PLATFORM_DIR/link-args"
  read -r -a LAYOUT <<< "$(sed 's/^/-Wl,/' "$PLATFORM_DIR/link-args" | tr '\n' ' ')"
fi

# The RISC-V target of the standards (RV64IM, LP64), freestanding. medany,
# because ZisK places code and data above 2 GiB. -ffunction-sections,
# -fdata-sections and --gc-sections drop the parts of the vendor library that a
# guest does not use, as in build-guests.sh: without them a ZisK guest keeps
# all of ziskos, which ZisK's prover compiles for every ELF.
CFLAGS=(-march=rv64im_zicclsm -mabi=lp64 -mcmodel=medany -O2 -ffreestanding -ffunction-sections -fdata-sections
        -Wall -I"$STANDARDS/io-interface" -I"$HERE/runtime")
CXXFLAGS=("${CFLAGS[@]}" -fno-exceptions -fno-rtti -fno-threadsafe-statics)

for src in "$HERE"/runtime/*.c; do
  riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$src" -o "$WORK/$(basename "$src" .c).o"
done
for src in "$HERE"/runtime/*.cpp; do
  riscv64-unknown-elf-g++ "${CXXFLAGS[@]}" -c "$src" -o "$WORK/$(basename "$src" .cpp).o"
done
# -fasynchronous-unwind-tables gives the probe its .eh_frame.
riscv64-unknown-elf-gcc "${CFLAGS[@]}" -fasynchronous-unwind-tables -c "$HERE/library/rt-segments.c" \
  -o "$WORK/rt-segments.probe.o"

# link <out> <linker flags...> -- <object>: link the object with the vendor
# library and nothing else. On failure, write the linker's output to
# <out without extension>.link-error. The linker's warnings go to the log.
link() {
  local out="$1"
  shift
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  local obj="$2"
  local log="${out%.*}.link-error"
  if riscv64-unknown-elf-gcc "${flags[@]}" -nostdlib -nostartfiles -static "${LAYOUT[@]}" -o "$out" "$obj" \
      "$VENDOR_LIB" > "$log" 2>&1; then
    cat "$log"
    rm "$log"
  else
    echo "note: $(basename "$obj" .o) does not link with $LINKER_NAME:"
    sed 's/^/  /' "$log" | head -20
    rm -f "$out"
    return 1
  fi
}

mkdir -p "$OUT/library"
count=0
for linker in ld lld; do
  case "$linker" in
    ld) LINKER_NAME="GNU ld"; group=runtime; suffix=""; flags=() ;;
    lld) LINKER_NAME="LLD"; group=runtime-lld; suffix=-lld; flags=(-fuse-ld=lld) ;;
  esac
  mkdir -p "$OUT/$group"
  for obj in "$WORK"/rt-*.o; do
    name=$(basename "$obj" .o)
    case "$name" in *.probe) continue ;; esac
    if link "$OUT/$group/$name$suffix.elf" "${flags[@]}" -Wl,--gc-sections -- "$obj"; then
      cp "$HERE/runtime/$name.expected" "$OUT/$group/$name$suffix.expected"
      count=$((count + 1))
    fi
  done
  # The probe links without --gc-sections, which would drop its .eh_frame
  # with GNU ld.
  if [ -n "$VENDOR_LD" ]; then
    link "$OUT/library/rt-segments$suffix.probe" "${flags[@]}" -- "$WORK/rt-segments.probe.o" || true
  fi
done

SCRIPT_ARG=()
if [ -n "$VENDOR_LD" ]; then SCRIPT_ARG=(--linker-script "$VENDOR_LD"); fi
echo "Static checks of $(basename "$VENDOR_LIB")${VENDOR_LD:+ and $(basename "$VENDOR_LD")}:"
python3 "$HERE/tools/check_static_library.py" --library "$VENDOR_LIB" "${SCRIPT_ARG[@]}" \
  --io-header "$STANDARDS/io-interface/zkvm_io.h" \
  --accelerators-header "$STANDARDS/c-interface-accelerators/zkvm_accelerators.h" \
  --probe-object "$WORK/rt-segments.probe.o" "$OUT"

echo "Built $count runtime guest ELFs for $ZKVM in $OUT"
