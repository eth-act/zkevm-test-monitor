#!/bin/bash
# extra.sh <zkvm> — run the act-extra suite for one zkVM (execute only).
#
# Builds the C guests in extra-tests/ against the zkVM's vendor library in
# Docker, runs them on the host with act4-runner, and appends a run to
# data/history/<zkvm>-act-extra.json.
set -euo pipefail

ZKVM="${1:?usage: extra.sh <zkvm>}"
PLATFORM_DIR="extra-tests/platforms/${ZKVM}"
ELF_DIR="test-results/${ZKVM}/elfs/extra"
RESULTS_DIR="test-results/${ZKVM}"
IMAGE="${ZKVM}-extra:latest"

if [ ! -d "$PLATFORM_DIR" ]; then
  echo "  No act-extra platform for $ZKVM; skipping"
  exit 0
fi

# IMAGE_EMULATOR: the emulator is built in the act-extra image and copied out.
# COMMIT_FILE: the zkVM commit to record for the run.
IMAGE_EMULATOR=""
COMMIT_FILE="data/commits/${ZKVM}.txt"
case "$ZKVM" in
  zisk) EMULATOR="binaries/zisk-binary" ;;
  sp1)
    EMULATOR="binaries/sp1-extra-executor"
    IMAGE_EMULATOR="/usr/local/bin/sp1-extra-executor"
    # The image pins its own SP1 tag (the ISA pin has no C SDK), so record that commit.
    COMMIT_FILE="$ELF_DIR/vendor-commit.txt"
    ;;
  *) echo "  act-extra: no runner backend for $ZKVM"; exit 1 ;;
esac
if [ -z "$IMAGE_EMULATOR" ] && [ ! -f "$EMULATOR" ]; then
  echo "  Error: $EMULATOR not found. Run './run build $ZKVM' first."
  exit 1
fi

COMMIT=$(jq -r ".zkvms.${ZKVM}.commit" config.json)
echo "Building act-extra image for $ZKVM..."
docker build --build-arg COMMIT_HASH="$COMMIT" -t "$IMAGE" \
  -f "$PLATFORM_DIR/Dockerfile" "$PLATFORM_DIR" > "$RESULTS_DIR/extra-image.log" 2>&1 || {
  echo "  Failed to build $IMAGE — check $RESULTS_DIR/extra-image.log"
  exit 1
}

if [ -n "$IMAGE_EMULATOR" ]; then
  mkdir -p binaries
  docker run --rm --entrypoint cat "$IMAGE" "$IMAGE_EMULATOR" > "$EMULATOR"
  chmod +x "$EMULATOR"
fi

# The guests are cheap to build, so always rebuild them from current sources.
rm -rf "$ELF_DIR"
mkdir -p "$ELF_DIR"
echo "Building act-extra guests for $ZKVM..."
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD/extra-tests:/extra-tests:ro" \
  -v "$PWD/$ELF_DIR:/elfs" \
  "$IMAGE" > "$RESULTS_DIR/extra-build.log" 2>&1 || {
  echo "  Failed to build act-extra guests — check $RESULTS_DIR/extra-build.log"
  exit 1
}

RUNNER="act4-runner/target/release/act4-runner"
if [ ! -x "$RUNNER" ]; then
  echo "  Building act4-runner..."
  cargo build --release --manifest-path act4-runner/Cargo.toml
fi

RUNNER_JOBS=""
if [ -n "${ACT4_JOBS:-${JOBS:-}}" ]; then
  RUNNER_JOBS="-j ${ACT4_JOBS:-${JOBS:-}}"
fi

if [ -d "binaries/${ZKVM}-lib" ]; then
  export LD_LIBRARY_PATH="$PWD/binaries/${ZKVM}-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

echo "Running $ZKVM act-extra suite (mode: execute)..."
# shellcheck disable=SC2086
"$RUNNER" \
  --zkvm "$ZKVM" --binary "$EMULATOR" \
  --elf-dir "$ELF_DIR" \
  --output-dir "$RESULTS_DIR" \
  --suite act-extra \
  --label extra \
  --mode execute \
  --io-sidecars \
  $RUNNER_JOBS || true

RESULTS_FILE="$RESULTS_DIR/results-act4-extra.json"
if [ ! -f "$RESULTS_FILE" ]; then
  echo "  Warning: no act-extra results generated for $ZKVM"
  exit 1
fi

mkdir -p data/history
HISTORY_FILE="data/history/${ZKVM}-act-extra.json"
ZKVM_COMMIT=$(head -c 8 "$COMMIT_FILE" 2>/dev/null || echo "unknown")
RUN_ENTRY=$(jq -n \
  --arg date "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg commit "$ZKVM_COMMIT" \
  --arg library_commit "$(head -c 8 "$ELF_DIR/vendor-commit.txt" 2>/dev/null || echo unknown)" \
  --arg monitor_commit "$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo unknown)" \
  --arg standards_commit "$(cat extra-tests/include/STANDARDS_COMMIT)" \
  --arg isa "$(jq -r ".zkvms.${ZKVM}.isa // \"unknown\"" config.json)" \
  --slurpfile results "$RESULTS_FILE" \
  '$results[0] as $r | {
     date: $date, commit: $commit, library_commit: $library_commit,
     monitor_commit: $monitor_commit, standards_commit: $standards_commit, isa: $isa,
     total: $r.total, passed: $r.passed, failed: $r.failed,
     prove_failed: [], verify_failed: [], has_proving: false,
     groups: $r.groups, details: $r.details
   }')

if [ -f "$HISTORY_FILE" ]; then
  jq --argjson run "$RUN_ENTRY" '.runs += [$run]' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" \
    && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
else
  jq -n --arg zkvm "$ZKVM" --argjson run "$RUN_ENTRY" \
    '{zkvm: $zkvm, suite: "act-extra", runs: [$run]}' > "$HISTORY_FILE"
fi

echo "  act-extra ${ZKVM}: $(jq '.passed | length' "$RESULTS_FILE")/$(jq '.total' "$RESULTS_FILE") passed"
