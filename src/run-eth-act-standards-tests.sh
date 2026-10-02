#!/bin/bash
# run-eth-act-standards-tests.sh <zkvm> — run the eth-act standards tests for one zkVM.
#
# 1. Builds the zkVM's C library and host executor
#    (zkvms/<zkvm>/standards/Dockerfile).
# 2. Builds the C test guests in tests/eth-act-standards/ as ACT4 C tests in the
#    zkVM's ACT4 image (zkvms/<zkvm>/act4.Dockerfile), linked against that library.
# 3. Runs them with runner, and appends a run to
#    results/history/<zkvm>-eth-act-standards.json:
#    - ere path (default): on the official ere image of the revision that
#      src/runner/Cargo.toml pins. ACT4_MODE=execute|prove|full (default: full);
#      prove and full need an NVIDIA GPU.
#    - BACKEND=noere: on the host executor from step 1, without ere.
#      ACT4_MODE=execute|prove|full (default: execute). Proving runs on an NVIDIA
#      GPU with the zkVM's prover: OpenVM's standards executor (built for the GPU
#      here), sp1-prover, or cargo-zisk-cuda (GPU=1 ./run build zisk).
set -euo pipefail

ZKVM="${1:?usage: run-eth-act-standards-tests.sh <zkvm>}"
# ere (default) or noere; see the header.
BACKEND_KIND="${BACKEND:-ere}"
case "$BACKEND_KIND" in
  ere) MODE="${ACT4_MODE:-full}" ;;
  noere) MODE="${ACT4_MODE:-execute}" ;;
  *) echo "  Error: BACKEND must be ere or noere, not $BACKEND_KIND"; exit 1 ;;
esac
# Proving on the noere path: the zkVM's prover tools for the runner.
NOERE_PROVE=""
if [ "$BACKEND_KIND" = "noere" ] && [ "$MODE" != "execute" ]; then NOERE_PROVE=1; fi
PLATFORM_DIR="zkvms/${ZKVM}/standards"
ELF_DIR="out/${ZKVM}/elfs/eth-act-standards"
RESULTS_DIR="out/${ZKVM}"
STANDARDS_DIR="out/deps/zkevm-standards"
VECTOR_CACHE="out/deps/accel-vectors"
IMAGE="${ZKVM}-eth-act-standards:latest"
RESULTS_FILE="$RESULTS_DIR/results-eth-act-standards.json"

if [ ! -d "$PLATFORM_DIR" ]; then
  echo "  No eth-act standards platform for $ZKVM; skipping"
  exit 0
fi
mkdir -p "$RESULTS_DIR" out/bin

# IMAGE_EMULATOR: the executor is built in the eth-act standards image and copied out.
# IMAGE_EMULATOR_LIBS: an image directory of shared libraries the emulator
#   needs, copied to "${EMULATOR}-lib".
# VENDOR_LIB: the zkVM's C library in the image, copied out for the guest build.
# IMAGE_COMMIT_FILES: "<image path>:<name>" commit files copied next to the ELFs.
# COMMIT_FILE: the zkVM commit to record for the run.
# NOTES: a note to record with every run (shown on the dashboard).
# EXECUTOR_ARG: the runner flag for the emulator: --binary for the zkVM's own
#   executor, --io-executor for an eth-act standards executor.
# PROVER_ARGS: the runner's prover flags when the noere path proves.
# BUILD_ARGS: extra `docker build` arguments for the image.
IMAGE_EMULATOR=""
IMAGE_EMULATOR_LIBS=""
PROVER_ARGS=()
BUILD_ARGS=()
COMMIT_FILE="out/commits/${ZKVM}.txt"
NOTES=""
case "$ZKVM" in
  zisk)
    EXECUTOR_ARG="--binary"
    EMULATOR="out/bin/zisk-eth-act-standards-emu"
    IMAGE_EMULATOR="/usr/local/bin/ziskemu"
    IMAGE_EMULATOR_LIBS="/usr/local/lib/ziskemu"
    VENDOR_LIB="/opt/zisk/lib/libziskos_staticlib.a"
    IMAGE_COMMIT_FILES="/zisk-commit.txt:vendor-commit.txt"
    # The image pins the ZisK version that eth-act/ere uses, so record that commit.
    COMMIT_FILE="$ELF_DIR/vendor-commit.txt"
    # cargo-zisk-cuda from ./run build zisk, at the same commit (config.json).
    if [ -n "$NOERE_PROVE" ]; then
      PROVER_ARGS=(--cargo-zisk out/bin/cargo-zisk-cuda)
      if [ -f out/bin/libzisk_witness.so ]; then
        PROVER_ARGS+=(--witness-lib out/bin/libzisk_witness.so)
      fi
    fi
    ;;
  sp1)
    EXECUTOR_ARG="--io-executor"
    EMULATOR="out/bin/sp1-eth-act-standards-executor"
    IMAGE_EMULATOR="/usr/local/bin/sp1-eth-act-standards-executor"
    VENDOR_LIB="/opt/sp1/libzkevm.a"
    IMAGE_COMMIT_FILES="/sp1-commit.txt:vendor-commit.txt"
    # The image pins its own SP1 tag (the ISA pin has no C SDK), so record that commit.
    COMMIT_FILE="$ELF_DIR/vendor-commit.txt"
    # sp1-prover (sp1-perf) from ./run build sp1, at the same commit (config.json).
    if [ -n "$NOERE_PROVE" ]; then PROVER_ARGS=(--sp1-perf out/bin/sp1-prover); fi
    ;;
  openvm)
    EXECUTOR_ARG="--io-executor"
    EMULATOR="out/bin/openvm-eth-act-standards-executor"
    IMAGE_EMULATOR="/usr/local/bin/openvm-eth-act-standards-executor"
    IMAGE_EMULATOR_LIBS="/usr/local/lib/openvm-executor"
    VENDOR_LIB="/opt/openvm/lib/libere_openvm_c.a"
    IMAGE_COMMIT_FILES="/ere-commit.txt:vendor-commit.txt /openvm-commit.txt:openvm-commit.txt"
    # The image pins OpenVM at the tag eth-act/ere uses and records its commit.
    COMMIT_FILE="$ELF_DIR/openvm-commit.txt"
    ERE_COMMIT=$(sed -n 's/^ARG ERE_COMMIT=//p' "$PLATFORM_DIR/Dockerfile")
    # The executor also proves: build it with OpenVM's GPU prover.
    if [ -n "$NOERE_PROVE" ]; then
      CUDA_ARCH="${CUDA_ARCH:-$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d .)}"
      BUILD_ARGS=(--build-arg BASE_IMAGE=nvidia/cuda:12.9.1-devel-ubuntu24.04 --build-arg GPU=1
                  --build-arg "CUDA_ARCH=${CUDA_ARCH:-120}")
    fi
    NOTES="OpenVM ships no C library for guests (its C-interface PRs https://github.com/openvm-org/openvm/pull/3075 to #3080 were closed unmerged). These results use eth-act/ere's C layer (ere-platform-openvm at https://github.com/eth-act/ere/commit/${ERE_COMMIT}) over OpenVM v2.1.0-preview guest libraries, plus a thin read_input/write_output wrapper (zkvms/openvm/standards/vendor). ere caps public output at 256 bytes."
    ;;
  *) echo "  eth-act standards tests: no executor for $ZKVM"; exit 1 ;;
esac
if [ -z "$IMAGE_EMULATOR" ] && [ ! -f "$EMULATOR" ]; then
  echo "  Error: $EMULATOR not found. Run './run build $ZKVM' first."
  exit 1
fi
for arg in "${PROVER_ARGS[@]}"; do
  case "$arg" in
    out/bin/*) [ -f "$arg" ] || { echo "  Error: $arg not found (needed for mode $MODE). Run './run build $ZKVM' first."; exit 1; } ;;
  esac
done

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
docker build --build-arg COMMIT_HASH="$COMMIT" "${BUILD_ARGS[@]}" -t "$IMAGE" \
  -f "$PLATFORM_DIR/Dockerfile" "$PLATFORM_DIR" > "$RESULTS_DIR/eth-act-standards-image.log" 2>&1 || {
  echo "  Failed to build $IMAGE — check $RESULTS_DIR/eth-act-standards-image.log"
  exit 1
}

if [ -n "$IMAGE_EMULATOR" ]; then
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
mkdir -p "$ELF_DIR" "$VECTOR_CACHE"
echo "Building eth-act standards test guests for $ZKVM..."
# ACT runs as root in its image (uv and UDB write inside /act4); the outputs
# are handed back to the calling user.
docker run --rm --entrypoint bash \
  -v "$PWD/tests/eth-act-standards:/eth-act-standards-tests:ro" \
  -v "$PWD/$PLATFORM_DIR:/platform:ro" \
  -v "$PWD/$STANDARDS_DIR:/zkevm-standards:ro" \
  -v "$PWD/$VECTOR_CACHE:/cache" \
  -v "$PWD/zkvms/${ZKVM}/isa-configs:/act4-config:ro" \
  -v "$PWD/$VENDOR_DIR:/vendor:ro" \
  -v "$PWD/$ELF_DIR:/elfs" \
  "$ACT_IMAGE" -c "/eth-act-standards-tests/build-guests.sh $ZKVM /elfs; status=\$?; chown -R $(id -u):$(id -g) /elfs /cache; exit \$status" \
  > "$RESULTS_DIR/eth-act-standards-build.log" 2>&1 || {
  echo "  Failed to build eth-act standards test guests — check $RESULTS_DIR/eth-act-standards-build.log"
  exit 1
}
for entry in $IMAGE_COMMIT_FILES; do
  docker run --rm --entrypoint cat "$IMAGE" "${entry%%:*}" > "$ELF_DIR/${entry#*:}"
done
# A noere prover from ./run build must be the zkVM version that runs the tests:
# build.sh records the commit it built in out/commits/<zkvm>.txt.
if [ -n "$NOERE_PROVE" ] && [ "$ZKVM" != "openvm" ]; then
  BUILT_COMMIT=$(head -c 8 "out/commits/${ZKVM}.txt" 2> /dev/null || echo none)
  if [ "$BUILT_COMMIT" != "$(head -c 8 "$COMMIT_FILE")" ]; then
    echo "  Error: the $ZKVM prover in out/bin is from $BUILT_COMMIT, but the tests run $(head -c 8 "$COMMIT_FILE")."
    echo "  Run './run build $ZKVM' first (GPU=1 for zisk)."
    exit 1
  fi
fi

RUNNER_ARGS=(--zkvm "$ZKVM" "$EXECUTOR_ARG" "$EMULATOR" --mode "$MODE" "${PROVER_ARGS[@]}")
RUNNER="src/runner/target/release/runner"
CARGO_ARGS=()
if [ "$BACKEND_KIND" = "ere" ]; then
  RUNNER_ARGS=(--zkvm "ere-$ZKVM" --mode "$MODE")
  RUNNER="src/runner/target/ere/release/runner"
  CARGO_ARGS=(--features ere --target-dir src/runner/target/ere)
fi
# Proving runs on the GPU (ere: its GPU images; execute runs on the CPU images).
if [ "$MODE" != "execute" ]; then RUNNER_ARGS+=(--gpu); fi

# Always build the runner, so a stale binary cannot judge the tests.
echo "Building runner..."
cargo build --release "${CARGO_ARGS[@]}" --manifest-path src/runner/Cargo.toml > "$RESULTS_DIR/eth-act-standards-runner-build.log" 2>&1 || {
  echo "  Failed to build the runner — check $RESULTS_DIR/eth-act-standards-runner-build.log"
  exit 1
}

RUNNER_JOBS=""
if [ -n "${ACT4_JOBS:-${JOBS:-}}" ]; then
  RUNNER_JOBS="-j ${ACT4_JOBS:-${JOBS:-}}"
fi

if [ -d "$EMULATOR_LIB_DIR" ]; then
  export LD_LIBRARY_PATH="$PWD/$EMULATOR_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi
# The noere provers' shared libraries, as src/run-isa-tests.sh sets them: cargo-zisk's
# bundled libraries, and a CUDA runtime for sp1-perf's GPU server.
if [ -n "$NOERE_PROVE" ]; then
  if [ "$ZKVM" = "zisk" ] && [ -d out/bin/zisk-lib ]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$PWD/out/bin/zisk-lib"
  fi
  for cuda_dir in /usr/local/cuda/lib64 /opt/cuda/lib64 "$PWD/out/bin/openvm-lib"; do
    if ls "$cuda_dir"/libcudart.so.12* > /dev/null 2>&1; then
      export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$cuda_dir"
      break
    fi
  done
fi

echo "Running $ZKVM eth-act standards tests ($BACKEND_KIND, mode: $MODE)..."
# Only this run's results may reach the history.
rm -f "$RESULTS_FILE" "$RESULTS_DIR/summary-eth-act-standards.json" \
  "$RESULTS_DIR/details-act4-eth-act-standards.json" "$RESULTS_DIR/ere-act4-eth-act-standards.json"
# Runner exit status: 0 all passed, 1 some test failed; anything else (a
# usage error, no ELFs, a host error) means the run is not valid.
RUNNER_STATUS=0
# shellcheck disable=SC2086
"$RUNNER" \
  "${RUNNER_ARGS[@]}" \
  --elf-dir "$ELF_DIR" \
  --output-dir "$RESULTS_DIR" \
  --suite eth-act-standards --groups \
  $RUNNER_JOBS || RUNNER_STATUS=$?
if [ "$RUNNER_STATUS" -gt 1 ]; then
  echo "  Error: the runner could not complete the $ZKVM run (exit $RUNNER_STATUS); no history recorded"
  exit 1
fi
if [ ! -f "$RESULTS_FILE" ]; then
  echo "  Error: no eth-act standards results generated for $ZKVM; no history recorded"
  exit 1
fi
# Every ELF this run built must have a result.
ELF_COUNT=$(find "$ELF_DIR" -name '*.elf' | wc -l)
if [ "$(jq .total "$RESULTS_FILE")" -ne "$ELF_COUNT" ]; then
  echo "  Error: $(jq .total "$RESULTS_FILE") results for $ELF_COUNT ELFs; no history recorded"
  exit 1
fi

# Tests that expect an abnormal termination (.outcome) have no valid proof, so
# the dashboard counts proving and verification over the other tests.
EXPECTED_FAILURES=$(find "$ELF_DIR" -name '*.outcome' -printf '%f\n' | sed 's/\.outcome$//' | sort | jq -R . | jq -sc .)

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
  --arg mode "$MODE" \
  --argjson expected_failures "$EXPECTED_FAILURES" \
  --slurpfile results "$RESULTS_FILE" \
  '$results[0] as $r | {
     date: $date, commit: $commit, library_commit: $library_commit,
     monitor_commit: $monitor_commit, standards_commit: $standards_commit, isa: $isa,
     mode: $mode, total: $r.total, passed: $r.passed, failed: $r.failed,
     prove_failed: $r.prove_failed, verify_failed: $r.verify_failed,
     expected_failures: $expected_failures, has_proving: ($mode != "execute"),
     groups: $r.groups, details: $r.details
   } + (if $notes == "" then {} else {notes: $notes} end)')
# The ere path records what ran the tests: the ere revision, image and SDK version.
if [ "$BACKEND_KIND" = "ere" ]; then
  RUN_ENTRY=$(jq -c --slurpfile ere "$RESULTS_DIR/ere-act4-eth-act-standards.json" \
    '. + $ere[0]' <<< "$RUN_ENTRY")
fi

if [ -f "$HISTORY_FILE" ]; then
  jq --argjson run "$RUN_ENTRY" '.runs += [$run]' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
    && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
else
  jq -n --arg zkvm "$ZKVM" --argjson run "$RUN_ENTRY" \
    '{zkvm: $zkvm, suite: "eth-act-standards", runs: [$run]}' > "$HISTORY_FILE"
fi

echo "  eth-act standards ${ZKVM}: $(jq '.passed | length' "$RESULTS_FILE")/$(jq '.total' "$RESULTS_FILE") passed"
