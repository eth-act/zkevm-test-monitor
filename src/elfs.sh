#!/bin/bash
# elfs.sh - ACT4 self-checking ELF generation, shared by src/test.sh and `./run elfs`.
#
# Sourced:  defines generate_act4_elfs.
# Executed: ./src/elfs.sh <zkvm> [--force]
#   Generates ELFs into test-results/<zkvm>/elfs/{native,target}, sends progress to
#   stderr, and prints exactly one JSON line on stdout for machine consumers (ere):
#   {"zkvm", "elf_dir", "act4_commit", "act4_version", "native", "target"}

# generate_act4_elfs <zkvm> <elf_dir>
#
# Builds the <zkvm>:latest ELF-generation image and compiles self-checking ELFs into
# <elf_dir>/{native,target}. Reuses existing ELFs unless FORCE is set.
generate_act4_elfs() {
  local ZKVM="$1"
  local ELF_DIR
  ELF_DIR=$(realpath -m "$2")
  local DOCKER_DIR="docker/${ZKVM}"

  # Skip ELF generation if ELFs already exist (set FORCE=1 to regenerate)
  if [ -d "$ELF_DIR/native" ] && [ -z "${FORCE:-}" ]; then
    local NATIVE_COUNT
    NATIVE_COUNT=$(find "$ELF_DIR/native" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$NATIVE_COUNT" -gt 0 ]; then
      echo "  Reusing $NATIVE_COUNT existing ELFs in $ELF_DIR/native (set FORCE=1 to regenerate)"
    fi
  else
    echo "Building Docker image for $ZKVM (ELF generation)..."
    ACT4_COMMIT=$(jq -r '.act4_commit // "act4"' config.json)
    docker build --build-arg ARCH_TEST_COMMIT="$ACT4_COMMIT" -t "${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" . || {
      echo "Failed to build Docker image for $ZKVM"
      return 1
    }

    # Clean old ELFs before regenerating (Docker creates files as root,
    # so use a Docker container to remove them if rm -rf fails).
    rm -rf "$ELF_DIR" 2>/dev/null || \
      docker run --rm -v "$ELF_DIR:/elfs" ubuntu:24.04 sh -c 'rm -rf /elfs/*'
    rm -rf "$ELF_DIR" 2>/dev/null
    mkdir -p "$ELF_DIR" "test-results/${ZKVM}"

    JOBS_ARG=""
    if [ -n "${ACT4_JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${ACT4_JOBS}"
    elif [ -n "${JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${JOBS}"
    fi

    LOG_FILE="test-results/${ZKVM}/act4-elfgen.log"
    echo "Generating ELFs for $ZKVM... (log: $LOG_FILE)"
    docker run --rm --name zkvm-${ZKVM}-elfgen \
      ${JOBS_ARG} \
      -v "$PWD/act4-configs/${ZKVM}:/act4/config/${ZKVM}" \
      -v "$ELF_DIR:/elfs" \
      "${ZKVM}:latest" > "$LOG_FILE" 2>&1 || {
      echo "  Failed to generate ELFs for $ZKVM — check $LOG_FILE"
      return 1
    }
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  ZKVM="${1:?usage: $0 <zkvm> [--force]}"
  [ "${2:-}" = "--force" ] && export FORCE=1
  [ -d "docker/${ZKVM}" ] || { echo "Unknown ZKVM: $ZKVM (no docker/${ZKVM}/)" >&2; exit 1; }

  ELF_DIR="test-results/${ZKVM}/elfs"
  generate_act4_elfs "$ZKVM" "$ELF_DIR" >&2

  jq -cn \
    --arg zkvm "$ZKVM" \
    --arg elf_dir "$(realpath "$ELF_DIR")" \
    --arg act4_commit "$(jq -r '.act4_commit // ""' config.json)" \
    --arg act4_version "$(jq -r '.act4_version // ""' config.json)" \
    --argjson native "$(find "$ELF_DIR/native" -name '*.elf' 2>/dev/null | wc -l)" \
    --argjson target "$(find "$ELF_DIR/target" -name '*.elf' 2>/dev/null | wc -l)" \
    '{zkvm: $zkvm, elf_dir: $elf_dir, act4_commit: $act4_commit, act4_version: $act4_version, native: $native, target: $target}'
fi
