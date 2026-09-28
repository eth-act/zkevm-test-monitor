#!/bin/bash
# generate_elfs.sh - ACT4 self-checking ELF generation, shared by src/test.sh and `./run elfs`.
#
# Sourced:  defines generate_act4_elfs.
# Executed: ./src/generate_elfs.sh <zkvm> [--force]
#   Generates ELFs into out/<zkvm>/elfs/{native,target} and prints how many
#   there are. It needs no zkVM binary and runs no tests.

# elfs_reusable <elf-dir> — true if the cached ELFs can be reused: FORCE is
# unset and the ELFs were generated at the ACT4 commit that config.json pins.
elfs_reusable() {
  local ELF_DIR="$1"
  [ -z "${FORCE:-}" ] && [ -d "$ELF_DIR/native" ] || return 1
  local WANT HAVE
  WANT=$(jq -r '.act4_commit // "act4"' config.json)
  HAVE=$(cat "$ELF_DIR/act4-commit.txt" 2>/dev/null || true)
  if [ "$HAVE" != "$WANT" ]; then
    echo "  Cached ELFs are from ACT4 commit '${HAVE:-unknown}', config.json pins '$WANT': regenerating"
    return 1
  fi
}

# generate_act4_elfs <zkvm> <elf_dir>
#
# Builds the <zkvm>:latest ELF-generation image and compiles self-checking ELFs into
# <elf_dir>/{native,target}. Reuses cached ELFs (see elfs_reusable) unless FORCE is set.
generate_act4_elfs() {
  local ZKVM="$1"
  local ELF_DIR
  ELF_DIR=$(realpath -m "$2")
  local DOCKER_DIR="zkvms/${ZKVM}"

  # Skip ELF generation if ELFs already exist (set FORCE=1 to regenerate)
  if elfs_reusable "$ELF_DIR"; then
    local NATIVE_COUNT
    NATIVE_COUNT=$(find "$ELF_DIR/native" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$NATIVE_COUNT" -gt 0 ]; then
      echo "  Reusing $NATIVE_COUNT existing ELFs in $ELF_DIR/native (set FORCE=1 to regenerate)"
    fi
  else
    echo "Building Docker image for $ZKVM (ELF generation)..."
    ACT4_COMMIT=$(jq -r '.act4_commit // "act4"' config.json)
    ACT4_VERSION=$(jq -r '.act4_version // "act4"' config.json)
    docker build --build-arg ARCH_TEST_COMMIT="$ACT4_COMMIT" --build-arg ARCH_TEST_VERSION="$ACT4_VERSION" -t "${ZKVM}:latest" -f "$DOCKER_DIR/act4.Dockerfile" . || {
      echo "Failed to build Docker image for $ZKVM"
      return 1
    }

    # Clean old ELFs before regenerating (Docker creates files as root,
    # so use a Docker container to remove them if rm -rf fails).
    rm -rf "$ELF_DIR" 2>/dev/null || \
      docker run --rm -v "$ELF_DIR:/elfs" ubuntu:24.04 sh -c 'rm -rf /elfs/*'
    # The container empties the directory; remove the now-empty directory too.
    rm -rf "$ELF_DIR" 2>/dev/null
    # The log below goes to out/<zkvm>/, which may not exist yet.
    mkdir -p "$ELF_DIR" "out/${ZKVM}"

    # Pass the job count (ACT4_JOBS, else JOBS) to the container as ACT4_JOBS.
    # The entrypoints differ: openvm and lambdavm use it (default: nproc), zisk
    # reads only JOBS and otherwise sizes itself from free memory, sp1 ignores it.
    JOBS_ARG=""
    if [ -n "${ACT4_JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${ACT4_JOBS}"
    elif [ -n "${JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${JOBS}"
    fi

    # Generate the ELFs. The entrypoint compiles the ACT4 tests with the zkVM's
    # config (zkvms/<zkvm>/isa-configs, mounted at /act4/config/<zkvm>), patches them
    # where the zkVM needs it, and writes native/ and target/ into /elfs. No zkVM
    # binary is involved. (The zisk entrypoint also has a legacy test mode; it
    # selects ELF-only mode because /elfs is a mount point.) The full output goes
    # to the log file.
    LOG_FILE="out/${ZKVM}/act4-elfgen.log"
    echo "Generating ELFs for $ZKVM... (log: $LOG_FILE)"
    docker run --rm --name zkvm-${ZKVM}-elfgen \
      ${JOBS_ARG} \
      -v "$PWD/zkvms/${ZKVM}/isa-configs:/act4/config/${ZKVM}" \
      -v "$ELF_DIR:/elfs" \
      "${ZKVM}:latest" > "$LOG_FILE" 2>&1 || {
      echo "  Failed to generate ELFs for $ZKVM — check $LOG_FILE"
      return 1
    }
    echo "$ACT4_COMMIT" > "$ELF_DIR/act4-commit.txt"
  fi
}

# Executed mode (`./run elfs`): run the function above for one zkVM.
# When src/test.sh sources this file, BASH_SOURCE[0] is this file and $0 is
# src/test.sh, so this block does not run.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -e
  ZKVM="${1:?usage: $0 <zkvm> [--force]}"
  [ "${2:-}" = "--force" ] && export FORCE=1
  # Each zkVM with ISA tests has an ELF-generation image in zkvms/<zkvm>/act4.Dockerfile.
  [ -f "zkvms/${ZKVM}/act4.Dockerfile" ] || { echo "Unknown ZKVM: $ZKVM (no zkvms/${ZKVM}/act4.Dockerfile)" >&2; exit 1; }

  # Same location as `./run test`, so both commands share the ELFs.
  ELF_DIR="out/${ZKVM}/elfs"
  generate_act4_elfs "$ZKVM" "$ELF_DIR"

  echo "ELFs for $ZKVM in $ELF_DIR:" \
    "$(find "$ELF_DIR/native" -name '*.elf' 2>/dev/null | wc -l) native," \
    "$(find "$ELF_DIR/target" -name '*.elf' 2>/dev/null | wc -l) target"
fi
