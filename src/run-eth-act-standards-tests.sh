#!/bin/bash
# run-eth-act-standards-tests.sh <zkvm> — run the eth-act standards tests for one zkVM
# (execute only).
#
# 1. Builds the zkVM's C library and host executor
#    (zkvms/<zkvm>/standards/Dockerfile).
# 2. Builds the C test guests in tests/eth-act-standards/ as ACT4 C tests in the
#    zkVM's ACT4 image (zkvms/<zkvm>/act4.Dockerfile), linked against that library.
# 3. Runs them on the host with runner (a standards backend), and appends a run
#    to results/history/<zkvm>-eth-act-standards.json.
set -euo pipefail

ZKVM="${1:?usage: run-eth-act-standards-tests.sh <zkvm>}"
PLATFORM_DIR="zkvms/${ZKVM}/standards"
ELF_DIR="out/${ZKVM}/elfs/eth-act-standards"
RESULTS_DIR="out/${ZKVM}"
STANDARDS_DIR="out/deps/zkevm-standards"
IMAGE="${ZKVM}-eth-act-standards:latest"

if [ ! -d "$PLATFORM_DIR" ]; then
  echo "  No eth-act standards platform for $ZKVM; skipping"
  exit 0
fi

# IMAGE_EMULATOR: the executor is built in the eth-act standards image and copied out.
# IMAGE_EMULATOR_LIBS: an image directory of shared libraries the emulator
#   needs, copied to "${EMULATOR}-lib".
# VENDOR_LIB: the zkVM's C library in the image, copied out for the guest build.
# IMAGE_COMMIT_FILES: "<image path>:<name>" commit files copied next to the ELFs.
# COMMIT_FILE: the zkVM commit to record for the run.
# NOTES: a note to record with every run (shown on the dashboard).
IMAGE_EMULATOR=""
IMAGE_EMULATOR_LIBS=""
COMMIT_FILE="out/commits/${ZKVM}.txt"
NOTES=""
case "$ZKVM" in
  zisk)
    BACKEND="zisk-standards"
    EMULATOR="out/bin/zisk-eth-act-standards-emu"
    IMAGE_EMULATOR="/usr/local/bin/ziskemu"
    IMAGE_EMULATOR_LIBS="/usr/local/lib/ziskemu"
    VENDOR_LIB="/opt/zisk/lib/libziskos_staticlib.a"
    IMAGE_COMMIT_FILES="/zisk-commit.txt:vendor-commit.txt"
    # The image pins the ZisK version that eth-act/ere uses, so record that commit.
    COMMIT_FILE="$ELF_DIR/vendor-commit.txt"
    ;;
  sp1)
    BACKEND="sp1-standards"
    EMULATOR="out/bin/sp1-eth-act-standards-executor"
    IMAGE_EMULATOR="/usr/local/bin/sp1-eth-act-standards-executor"
    VENDOR_LIB="/opt/sp1/libzkevm.a"
    IMAGE_COMMIT_FILES="/sp1-commit.txt:vendor-commit.txt"
    # The image pins its own SP1 tag (the ISA pin has no C SDK), so record that commit.
    COMMIT_FILE="$ELF_DIR/vendor-commit.txt"
    ;;
  openvm)
    BACKEND="openvm-standards"
    EMULATOR="out/bin/openvm-eth-act-standards-executor"
    IMAGE_EMULATOR="/usr/local/bin/openvm-eth-act-standards-executor"
    VENDOR_LIB="/opt/openvm/lib/libere_openvm_c.a"
    IMAGE_COMMIT_FILES="/ere-commit.txt:vendor-commit.txt /openvm-commit.txt:openvm-commit.txt"
    # The image pins OpenVM at the tag eth-act/ere uses and records its commit.
    COMMIT_FILE="$ELF_DIR/openvm-commit.txt"
    ERE_COMMIT=$(sed -n 's/^ARG ERE_COMMIT=//p' "$PLATFORM_DIR/Dockerfile")
    NOTES="OpenVM ships no C library for guests (its C-interface PRs https://github.com/openvm-org/openvm/pull/3075 to #3080 were closed unmerged). These results use eth-act/ere's C layer (ere-platform-openvm at https://github.com/eth-act/ere/commit/${ERE_COMMIT}) over OpenVM v2.1.0-preview guest libraries, plus a thin read_input/write_output wrapper (zkvms/openvm/standards/vendor). ere caps public output at 256 bytes."
    ;;
  *) echo "  eth-act standards tests: no executor for $ZKVM"; exit 1 ;;
esac
if [ -z "$IMAGE_EMULATOR" ] && [ ! -f "$EMULATOR" ]; then
  echo "  Error: $EMULATOR not found. Run './run build $ZKVM' first."
  exit 1
fi

# The guests include the standard headers from eth-act/zkevm-standards at the
# commit config.json pins, fetched once into a local cache.
STANDARDS_COMMIT=$(jq -r .zkevm_standards_commit config.json)
if [ "$(git -C "$STANDARDS_DIR" rev-parse HEAD 2>/dev/null)" != "$STANDARDS_COMMIT" ]; then
  echo "Fetching eth-act/zkevm-standards at ${STANDARDS_COMMIT:0:8}..."
  rm -rf "$STANDARDS_DIR"
  mkdir -p "$STANDARDS_DIR"
  git -C "$STANDARDS_DIR" init -q
  git -C "$STANDARDS_DIR" fetch -q --depth 1 https://github.com/eth-act/zkevm-standards "$STANDARDS_COMMIT"
  git -C "$STANDARDS_DIR" checkout -q FETCH_HEAD
fi

COMMIT=$(jq -r ".zkvms.${ZKVM}.commit" config.json)
echo "Building eth-act standards image for $ZKVM..."
docker build --build-arg COMMIT_HASH="$COMMIT" -t "$IMAGE" \
  -f "$PLATFORM_DIR/Dockerfile" "$PLATFORM_DIR" > "$RESULTS_DIR/eth-act-standards-image.log" 2>&1 || {
  echo "  Failed to build $IMAGE — check $RESULTS_DIR/eth-act-standards-image.log"
  exit 1
}

if [ -n "$IMAGE_EMULATOR" ]; then
  mkdir -p binaries
  docker run --rm --entrypoint cat "$IMAGE" "$IMAGE_EMULATOR" > "$EMULATOR"
  chmod +x "$EMULATOR"
fi
EMULATOR_LIB_DIR="out/bin/${ZKVM}-lib"
if [ -n "$IMAGE_EMULATOR_LIBS" ]; then
  EMULATOR_LIB_DIR="${EMULATOR}-lib"
  rm -rf "$EMULATOR_LIB_DIR"
  mkdir -p "$EMULATOR_LIB_DIR"
  docker run --rm --entrypoint tar "$IMAGE" -C "$IMAGE_EMULATOR_LIBS" -cf - . | tar -xf - -C "$EMULATOR_LIB_DIR"
fi

VENDOR_DIR="$RESULTS_DIR/eth-act-standards-vendor"
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR"
docker run --rm --entrypoint cat "$IMAGE" "$VENDOR_LIB" > "$VENDOR_DIR/$(basename "$VENDOR_LIB")"

# The guests are built as ACT4 C tests in the zkVM's ACT4 image, the image the
# ISA tests use (same Dockerfile and build arguments as src/run-isa-tests.sh).
ACT_IMAGE="${ZKVM}:latest"
echo "Building the ACT4 image for $ZKVM..."
docker build --build-arg ARCH_TEST_COMMIT="$(jq -r .act4_commit config.json)" \
  --build-arg ARCH_TEST_VERSION="$(jq -r .act4_version config.json)" \
  -t "$ACT_IMAGE" -f "zkvms/${ZKVM}/act4.Dockerfile" . > "$RESULTS_DIR/eth-act-standards-act-image.log" 2>&1 || {
  echo "  Failed to build $ACT_IMAGE — check $RESULTS_DIR/eth-act-standards-act-image.log"
  exit 1
}

# The guests are cheap to build, so always rebuild them from current sources.
rm -rf "$ELF_DIR"
mkdir -p "$ELF_DIR"
echo "Building eth-act standards test guests for $ZKVM..."
# ACT runs as root in its image (uv and UDB write inside /act4); the outputs
# are handed back to the calling user.
docker run --rm --entrypoint bash \
  -v "$PWD/tests/eth-act-standards:/eth-act-standards-tests:ro" \
  -v "$PWD/$PLATFORM_DIR:/platform:ro" \
  -v "$PWD/$STANDARDS_DIR:/zkevm-standards:ro" \
  -v "$PWD/zkvms/${ZKVM}/isa-configs:/act4-config:ro" \
  -v "$PWD/$VENDOR_DIR:/vendor:ro" \
  -v "$PWD/$ELF_DIR:/elfs" \
  "$ACT_IMAGE" -c "/eth-act-standards-tests/build-guests.sh $ZKVM /elfs; status=\$?; chown -R $(id -u):$(id -g) /elfs; exit \$status" \
  > "$RESULTS_DIR/eth-act-standards-build.log" 2>&1 || {
  echo "  Failed to build eth-act standards test guests — check $RESULTS_DIR/eth-act-standards-build.log"
  exit 1
}
for entry in $IMAGE_COMMIT_FILES; do
  docker run --rm --entrypoint cat "$IMAGE" "${entry%%:*}" > "$ELF_DIR/${entry#*:}"
done

RUNNER="src/runner/target/release/runner"
if [ ! -x "$RUNNER" ]; then
  echo "  Building runner..."
  cargo build --release --manifest-path src/runner/Cargo.toml
fi

RUNNER_JOBS=""
if [ -n "${ACT4_JOBS:-${JOBS:-}}" ]; then
  RUNNER_JOBS="-j ${ACT4_JOBS:-${JOBS:-}}"
fi

if [ -d "$EMULATOR_LIB_DIR" ]; then
  export LD_LIBRARY_PATH="$PWD/$EMULATOR_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

echo "Running $ZKVM eth-act standards tests (execute only)..."
# shellcheck disable=SC2086
"$RUNNER" \
  --zkvm "$BACKEND" --binary "$EMULATOR" \
  --elf-dir "$ELF_DIR" \
  --output-dir "$RESULTS_DIR" \
  --suite eth-act-standards --groups \
  $RUNNER_JOBS || true

RESULTS_FILE="$RESULTS_DIR/results-eth-act-standards.json"
if [ ! -f "$RESULTS_FILE" ]; then
  echo "  Warning: no eth-act standards results generated for $ZKVM"
  exit 1
fi

mkdir -p results/history
HISTORY_FILE="results/history/${ZKVM}-eth-act-standards.json"
ZKVM_COMMIT=$(head -c 8 "$COMMIT_FILE" 2>/dev/null || echo "unknown")
RUN_ENTRY=$(jq -n \
  --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg commit "$ZKVM_COMMIT" \
  --arg library_commit "$(head -c 8 "$ELF_DIR/vendor-commit.txt" 2>/dev/null || echo unknown)" \
  --arg monitor_commit "$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo unknown)" \
  --arg standards_commit "$STANDARDS_COMMIT" \
  --arg isa "$(jq -r ".zkvms.${ZKVM}.isa // \"unknown\"" config.json)" \
  --arg notes "$NOTES" \
  --slurpfile results "$RESULTS_FILE" \
  '$results[0] as $r | {
     date: $date, commit: $commit, library_commit: $library_commit,
     monitor_commit: $monitor_commit, standards_commit: $standards_commit, isa: $isa,
     total: $r.total, passed: $r.passed, failed: $r.failed,
     prove_failed: [], verify_failed: [], has_proving: false,
     groups: $r.groups, details: $r.details
   } + (if $notes == "" then {} else {notes: $notes} end)')

if [ -f "$HISTORY_FILE" ]; then
  jq --argjson run "$RUN_ENTRY" '.runs += [$run]' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
    && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
else
  jq -n --arg zkvm "$ZKVM" --argjson run "$RUN_ENTRY" \
    '{zkvm: $zkvm, suite: "eth-act-standards", runs: [$run]}' > "$HISTORY_FILE"
fi

echo "  eth-act standards ${ZKVM}: $(jq '.passed | length' "$RESULTS_FILE")/$(jq '.total' "$RESULTS_FILE") passed"
