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
# Every <group>/<name>.c (group: io, accelerators, memory, termination, randomness) becomes
# <out-dir>/<group>/<name>.elf. The test vectors <name>.input, <name>.expected
# and <name>.outcome are copied next to the ELF, and <group>/write_io_vectors.py
# writes the rest of the I/O vectors.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ZKVM="${1:?usage: build-guests.sh <zkvm> <out-dir>}"
OUT="${2:?usage: build-guests.sh <zkvm> <out-dir>}"
PLATFORM_DIR="/platform"
STANDARDS="/zkevm-standards/standards"
GROUPS_LIST="io accelerators memory termination randomness"

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
  "$STANDARDS/host-randomness/zkvm_random.h" "$HERE/include/checks.h" "$DUT/"

# A vendor library without zkvm_random_u64 would fail every link. This archive
# comes after the vendor library in link.ld, so the linker uses its
# zkvm_random_u64 only when the vendor has none; that one fails the test.
riscv64-unknown-elf-gcc -march=rv64im -mabi=lp64 -O2 \
  -c "$HERE/include/zkvm_random_fallback.c" -o "$DUT/zkvm_random_fallback.o"
riscv64-unknown-elf-ar crs "$DUT/libzkvm_random_fallback.a" "$DUT/zkvm_random_fallback.o"
echo "INPUT($DUT/libzkvm_random_fallback.a)" >> "$DUT/link.ld"

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
for group in $GROUPS_LIST; do
  cp -r "$HERE/$group" "$TESTS/rv64i/$group"
done

# The accelerator known-answer vectors are generated from pinned, sha256-checked
# go-ethereum and execution-specs files (tools/accel_vector_sources.json).
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
