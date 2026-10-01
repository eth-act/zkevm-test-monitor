#!/bin/bash
# Build the eth-act standards test guests for one zkVM as ACT4 C tests.
#
# Usage: build-guests.sh <zkvm> <out-dir>
#
# Runs inside the zkVM's ACT4 image (zkvms/<zkvm>/act4.Dockerfile, ACT4 >= 4.1.0),
# with these mounts:
#   /eth-act-standards-tests  this directory (read-only)
#   /act4-config              zkvms/<zkvm>/isa-configs (read-only)
#   /platform                 zkvms/<zkvm>/standards (read-only)
#   /vendor                   the zkVM's C library (read-only)
#   /zkevm-standards          eth-act/zkevm-standards at the pinned commit (read-only)
#   /cache                    download cache for the accelerator vector sources and uv
#
# Every <group>/<name>.c (group: io, accelerators, memory) becomes
# <out-dir>/<group>/<name>.elf. The test vectors <name>.input, <name>.expected
# and <name>.outcome are copied next to the ELF, and <group>/write_io_vectors.py
# writes the rest of the I/O vectors.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ZKVM="${1:?usage: build-guests.sh <zkvm> <out-dir>}"
OUT="${2:?usage: build-guests.sh <zkvm> <out-dir>}"
PLATFORM_DIR="/platform"
STANDARDS="/zkevm-standards/standards"
GROUPS_LIST="io accelerators memory"

if [ ! -f "$STANDARDS/io-interface/zkvm_io.h" ]; then
  echo "error: $STANDARDS has no zkvm_io.h; mount eth-act/zkevm-standards at /zkevm-standards" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The zkVM's C library, and its own linker script when it publishes one.
VENDOR_LIBS=(/vendor/*.a)
if [ "${#VENDOR_LIBS[@]}" -ne 1 ] || [ ! -f "${VENDOR_LIBS[0]}" ]; then
  echo "error: expected one vendor library in /vendor" >&2
  exit 1
fi
VENDOR_LIB="${VENDOR_LIBS[0]}"

# DUT directory: this platform's test_config.yaml and linker script, the rest
# of the zkVM's ISA config (rvmodel_macros.h, UDB config, sail.json, ...), the
# standard headers and our checks.h.
DUT="$WORK/dut"
mkdir -p "$DUT"
ISA_CONFIG=$(sed -n 's/^udb_config: *\([^ ]*\)\.yaml.*/\1/p' "$PLATFORM_DIR/test_config.yaml")
for f in /act4-config/"$ISA_CONFIG"/*; do
  case "$(basename "$f")" in
    test_config.yaml | link.ld) ;;
    *) cp "$f" "$DUT/" ;;
  esac
done
cp "$PLATFORM_DIR/test_config.yaml" "$DUT/"
# The linker script is the zkVM's own, unchanged except for link.ld.patch. A
# zkVM that publishes no linker script (OpenVM) has its own link.ld here.
if [ -f "$PLATFORM_DIR/link.ld.patch" ]; then
  VENDOR_LDS=(/vendor/*.ld)
  if [ "${#VENDOR_LDS[@]}" -ne 1 ] || [ ! -f "${VENDOR_LDS[0]}" ]; then
    echo "error: expected the zkVM's linker script in /vendor" >&2
    exit 1
  fi
  cp "${VENDOR_LDS[0]}" "$DUT/link.ld"
  patch --quiet --fuzz=0 --no-backup-if-mismatch "$DUT/link.ld" "$PLATFORM_DIR/link.ld.patch" || {
    echo "error: link.ld.patch does not apply to $(basename "${VENDOR_LDS[0]}")" >&2
    exit 1
  }
else
  cp "$PLATFORM_DIR/link.ld" "$DUT/"
fi
cp "$STANDARDS/io-interface/zkvm_io.h" "$STANDARDS/c-interface-accelerators/zkvm_accelerators.h" \
  "$HERE/include/checks.h" "$DUT/"

# ACT compiles C tests with -std=gnu99; zkvm_accelerators.h requires C11. The
# last -std option wins, so the wrapper appends -std=gnu11.
# --gc-sections drops the parts of the vendor library that a guest does not
# use. Without it a ZisK guest keeps all of ziskos (4.7 MB of code, including
# its proof verifier), and ZisK's prover compiles all that code for every ELF.
# A link (no -c, -S or -E) also gets the zkVM's library, because ACT's link
# line takes no libraries, and the zkVM's own link arguments (link-args, for a
# zkVM that links with the default layout, such as OpenVM's -Ttext).
LINK_ARGS=""
if [ -f "$PLATFORM_DIR/link-args" ]; then
  LINK_ARGS=$(sed 's/^/-Wl,/' "$PLATFORM_DIR/link-args" | tr '\n' ' ')
fi
cat > "$DUT/riscv64-unknown-elf-gcc-gnu11" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    -c | -S | -E) exec riscv64-unknown-elf-gcc "\$@" -std=gnu11 -ffunction-sections -fdata-sections ;;
  esac
done
exec riscv64-unknown-elf-gcc "\$@" -std=gnu11 -ffunction-sections -fdata-sections -Wl,--gc-sections $LINK_ARGS"$VENDOR_LIB"
EOF
chmod +x "$DUT/riscv64-unknown-elf-gcc-gnu11"
export PATH="$DUT:$PATH"

# Test tree in ACT's layout: env/ from ACT, and one directory per group.
TESTS="$WORK/tests"
mkdir -p "$TESTS/rv64i"
cp -r /act4/tests/env "$TESTS/env"
# The guests target rv64im_zicclsm, without Zicsr. ACT's C start code reads
# mhartid; the zkVMs have one hart, so its ID is 0. (The vendor's _start is the
# entry point, so this code is linked but not run.)
sed -i 's/^\([[:space:]]*\)csrr[[:space:]]*t0,[[:space:]]*mhartid/\1li    t0, 0/' "$TESTS/env/c_test_start.S"
if grep -q csrr "$TESTS/env/c_test_start.S"; then
  echo "error: ACT's c_test_start.S has a CSR access that the rv64im_zicclsm build cannot assemble" >&2
  exit 1
fi
for group in $GROUPS_LIST; do
  cp -r "$HERE/$group" "$TESTS/rv64i/$group"
done
# The vendored optimized-routines tests sweep lengths up to LEN = 250000, which
# is billions of guest instructions per test. Build them with a smaller LEN.
AOR_LEN=1024
for f in "$TESTS/rv64i/memory/optimized-routines"/mem*.c; do
  if ! grep -qx '#define LEN 250000' "$f"; then
    echo "error: $f has no '#define LEN 250000' to replace" >&2
    exit 1
  fi
  sed -i "s/^#define LEN 250000\$/#define LEN $AOR_LEN/" "$f"
done

# mem-link-<fn> checks that the library's strong <fn> wins symbol resolution
# against a weak <fn> in the guest. Acceleration is optional: without a strong
# <fn>, a guest falls back to the toolchain's <fn>, so the test does not apply.
VENDOR_SYMS=$(riscv64-unknown-elf-nm -g --defined-only "$VENDOR_LIB")
MEMOPS="memcpy memmove memset memcmp"
for fn in $MEMOPS; do
  if ! grep -Eqx "[0-9a-f]+ T $fn" <<< "$VENDOR_SYMS"; then
    echo "note: $(basename "${VENDOR_LIBS[0]}") has no strong $fn, so mem-link-$fn does not apply"
    rm "$TESTS/rv64i/memory/mem-link-$fn.c"
  fi
done

# The accelerator known-answer vectors are generated from pinned, sha256-checked
# go-ethereum and execution-specs files (tools/accel_vector_sources.json) and
# the extracted execution-specs pytest cases (tools/eest_pytest_vectors.json).
UV_CACHE_DIR=/cache/uv uv run --no-project --with pycryptodome --with ecdsa \
  "$HERE/tools/gen_accel_vectors.py" --out "$TESTS/rv64i/accelerators/vectors" --cache /cache/vectors

(cd /act4 && uv run act "$DUT/test_config.yaml" --workdir "$WORK/act" --test-dir "$TESTS" \
  --extensions "$(echo $GROUPS_LIST | tr ' ' ',')")

ELF_ROOT="$WORK/act/$ZKVM-eth-act-standards/elfs/rv64i"

# Each mem-link-<fn> ELF must resolve <fn> to the vendor's strong definition
# (pass) or to the guest's decoy_<fn> (fail). Any other weak definition, such
# as compiler-builtins', would copy correctly and let the test pass.
for fn in $MEMOPS; do
  elf="$ELF_ROOT/memory/mem-link-$fn.elf"
  [ -f "$elf" ] || continue
  syms=$(riscv64-unknown-elf-nm "$elf")
  kind=$(awk -v s="$fn" '$3 == s { print $2 }' <<< "$syms")
  addr=$(awk -v s="$fn" '$3 == s { print $1 }' <<< "$syms")
  decoy=$(awk -v s="decoy_$fn" '$3 == s { print $1 }' <<< "$syms")
  if [ "$kind" != T ] && { [ -z "$addr" ] || [ "$addr" != "$decoy" ]; }; then
    echo "error: mem-link-$fn resolves $fn to neither the vendor nor decoy_$fn" >&2
    exit 1
  fi
done

count=0
for group in $GROUPS_LIST; do
  mkdir -p "$OUT/$group"
  for elf in "$ELF_ROOT/$group"/*.elf; do
    name=$(basename "$elf" .elf)
    # cat, not cp: ACT's build cache may leave the ELFs as symlinks.
    cat "$elf" > "$OUT/$group/$name.elf"
    for vector in input expected outcome; do
      if [ -f "$HERE/$group/$name.$vector" ]; then
        cp "$HERE/$group/$name.$vector" "$OUT/$group/$name.$vector"
      fi
    done
    count=$((count + 1))
  done
  if [ -f "$HERE/$group/write_io_vectors.py" ]; then
    python3 "$HERE/$group/write_io_vectors.py" "$OUT/$group"
  fi
done

echo "Built $count eth-act standards test ELFs for $ZKVM in $OUT"
