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

# DUT directory: this platform's test_config.yaml and link.ld, the rest of the
# zkVM's ISA config (rvmodel_macros.h, UDB config, sail.json, ...), the
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
cp "$PLATFORM_DIR/test_config.yaml" "$PLATFORM_DIR/link.ld" "$DUT/"
cp "$STANDARDS/io-interface/zkvm_io.h" "$STANDARDS/c-interface-accelerators/zkvm_accelerators.h" \
  "$HERE/include/checks.h" "$DUT/"

# ACT compiles C tests with -std=gnu99; zkvm_accelerators.h requires C11. The
# last -std option wins, so the wrapper appends -std=gnu11.
cat > "$DUT/riscv64-unknown-elf-gcc-gnu11" <<'EOF'
#!/bin/sh
exec riscv64-unknown-elf-gcc "$@" -std=gnu11
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

# The accelerator known-answer vectors are generated from pinned, sha256-checked
# go-ethereum and execution-specs files (tools/accel_vector_sources.json) and
# the extracted execution-specs pytest cases (tools/eest_pytest_vectors.json).
UV_CACHE_DIR=/cache/uv uv run --no-project --with pycryptodome --with ecdsa \
  "$HERE/tools/gen_accel_vectors.py" --out "$TESTS/rv64i/accelerators/vectors" --cache /cache/vectors

(cd /act4 && uv run act "$DUT/test_config.yaml" --workdir "$WORK/act" --test-dir "$TESTS" \
  --extensions "$(echo $GROUPS_LIST | tr ' ' ',')")

ELF_ROOT="$WORK/act/$ZKVM-eth-act-standards/elfs/rv64i"
# SP1 and OpenVM decode every word of the code segment; replace the data words
# that ACT places in code with NOPs, as for the ISA tests.
python3 /act4/patch_elfs.py "$ELF_ROOT"

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
