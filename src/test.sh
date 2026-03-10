#!/bin/bash
set -e

# Parse targets (positional args only; no suite flag needed)
TARGETS=""
while [[ $# -gt 0 ]]; do
  TARGETS="$TARGETS $1"
  shift
done

# Default to "all" if no targets specified
TARGETS="${TARGETS:-all}"
TARGETS="${TARGETS# }"

# Determine which ZKVMs to test
if [ "$TARGETS" = "all" ] || [ -z "$TARGETS" ]; then
  ZKVMS=""
  for dir in docker/*/; do
    name=$(basename "$dir")
    # Skip build-* and shared
    [[ "$name" == build-* ]] && continue
    [[ "$name" == "shared" ]] && continue
    [ -d "$dir" ] && ZKVMS="$ZKVMS $name"
  done
  ZKVMS="${ZKVMS# }"
else
  ZKVMS="$TARGETS"
fi

# process_results <zkvm> — reads summary/results JSON and updates history
process_results() {
  local ZKVM="$1"

  mkdir -p data/history
  TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
  ZKVM_COMMIT=$(cat "data/commits/${ZKVM}.txt" 2>/dev/null || jq -r ".zkvms.${ZKVM}.commit // \"unknown\"" config.json 2>/dev/null || echo "unknown")
  RUN_DATE=$(date -u +"%Y-%m-%d")

  for ACT4_SUFFIX in "" "-target"; do
    if [ -z "$ACT4_SUFFIX" ]; then
      FILE_LABEL="full-isa"
      SUITE_LABEL="full ISA"
      ISA="rv32im"
      SUITE="act4"
    else
      FILE_LABEL="standard-isa"
      SUITE_LABEL="standard ISA"
      ISA="rv64im_zicclsm"
      SUITE="act4-target"
    fi
    SUMMARY_FILE="test-results/${ZKVM}/summary-act4-${FILE_LABEL}.json"
    RESULTS_FILE="test-results/${ZKVM}/results-act4-${FILE_LABEL}.json"

    if [ ! -f "$SUMMARY_FILE" ]; then
      if [ -z "$ACT4_SUFFIX" ]; then
        echo "  Warning: No summary generated for $ZKVM (container may have failed)"
      fi
      continue
    fi

    PASSED=$(jq '.passed' "$SUMMARY_FILE")
    FAILED=$(jq '.failed' "$SUMMARY_FILE")
    TOTAL=$(jq '.total' "$SUMMARY_FILE")

    if [ -f "$RESULTS_FILE" ]; then
      TEST_COUNT=$(jq '.tests | length' "$RESULTS_FILE")
    else
      TEST_COUNT="$TOTAL"
    fi

    if [ "$FAILED" -eq 0 ]; then
      STATUS_EMOJI="+"
    else
      STATUS_EMOJI="x"
    fi

    echo "  ACT4 ${ZKVM} (${SUITE_LABEL}): ${TEST_COUNT} tests in results-act4-${FILE_LABEL}.json"
    echo "     ${STATUS_EMOJI} ${PASSED}/${TOTAL} passed"

    HISTORY_FILE="data/history/${ZKVM}-${SUITE}.json"
    if [ -f "$HISTORY_FILE" ]; then
      jq --arg date "$RUN_DATE" \
        --arg monitor "$TEST_MONITOR_COMMIT" \
        --arg zkvm "$ZKVM_COMMIT" \
        --arg isa "$ISA" \
        --arg suite "$SUITE" \
        --argjson passed "$PASSED" \
        --argjson failed "$FAILED" \
        --argjson total "$TOTAL" \
        '.runs += [{"date": $date, "test_monitor_commit": $monitor,
                    "zkvm_commit": $zkvm, "isa": $isa, "suite": $suite,
                    "passed": $passed, "failed": $failed, "total": $total, "notes": ""}]' \
        "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      cat > "$HISTORY_FILE" << HISTORY
{
  "zkvm": "${ZKVM}",
  "suite": "${SUITE}",
  "runs": [
    {
      "date": "${RUN_DATE}",
      "test_monitor_commit": "${TEST_MONITOR_COMMIT}",
      "zkvm_commit": "${ZKVM_COMMIT}",
      "isa": "${ISA}",
      "suite": "${SUITE}",
      "passed": ${PASSED},
      "failed": ${FAILED},
      "total": ${TOTAL},
      "notes": ""
    }
  ]
}
HISTORY
    fi
  done
}

# run_zisk_split_pipeline — ELF generation in Docker, test execution on host via act4-runner
run_zisk_split_pipeline() {
  local ZKVM=zisk
  local ELF_DIR="test-results/${ZKVM}/elfs"
  local DOCKER_DIR="docker/${ZKVM}"

  # Zisk mode: execute (default), prove, or full. Set via ZISK_MODE env var.
  local MODE="${ZISK_MODE:-execute}"

  # Skip ELF generation if ELFs already exist (set FORCE=1 to regenerate)
  if [ -d "$ELF_DIR/native" ] && [ -z "${FORCE:-}" ]; then
    local NATIVE_COUNT
    NATIVE_COUNT=$(find "$ELF_DIR/native" -name "*.elf" 2>/dev/null | wc -l)
    if [ "$NATIVE_COUNT" -gt 0 ]; then
      echo "  Reusing $NATIVE_COUNT existing ELFs in $ELF_DIR/native (set FORCE=1 to regenerate)"
    fi
  else
    echo "Building Docker image for $ZKVM (ELF generation)..."
    docker build -t "${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" . || {
      echo "Failed to build Docker image for $ZKVM"
      return 1
    }

    # Clean old ELFs before regenerating (Docker creates files as root,
    # so use a Docker container to remove them if rm -rf fails).
    rm -rf "$ELF_DIR" 2>/dev/null || \
      docker run --rm -v "$PWD/$ELF_DIR:/elfs" ubuntu:24.04 sh -c 'rm -rf /elfs/*'
    rm -rf "$ELF_DIR" 2>/dev/null
    mkdir -p "$ELF_DIR"

    JOBS_ARG=""
    if [ -n "${ACT4_JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${ACT4_JOBS}"
    elif [ -n "${JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${JOBS}"
    fi

    LOG_FILE="test-results/${ZKVM}/act4-elfgen.log"
    echo "Generating ELFs for $ZKVM... (log: $LOG_FILE)"
    docker run --rm \
      ${JOBS_ARG} \
      -v "$PWD/act4-configs/${ZKVM}:/act4/config/${ZKVM}" \
      -v "$PWD/$ELF_DIR:/elfs" \
      "${ZKVM}:latest" > "$LOG_FILE" 2>&1 || {
      echo "  Failed to generate ELFs for $ZKVM — check $LOG_FILE"
      return 1
    }
  fi

  # Check act4-runner binary exists
  local RUNNER="act4-runner/target/release/act4-runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building act4-runner..."
    # ere-zisk links against libiomp5 (Intel OpenMP). On some systems (e.g. Arch)
    # only libomp.so exists. Create a shim symlink if needed.
    if ! ldconfig -p 2>/dev/null | grep -q libiomp5 && [ -f /usr/lib/libomp.so ]; then
      mkdir -p act4-runner/lib-shims
      ln -sf /usr/lib/libomp.so act4-runner/lib-shims/libiomp5.so
    fi
    RUSTFLAGS="-L $PWD/act4-runner/lib-shims" \
      cargo build --release --manifest-path act4-runner/Cargo.toml 2>&1 || {
      echo "  Failed to build act4-runner"
      return 1
    }
  fi

  # Ensure ziskemu is on PATH (ere-zisk shells out to it).
  # Prefer local build, fall back to binaries/zisk-binary.
  if ! command -v ziskemu &>/dev/null; then
    if [ -x "zisk/target/release/ziskemu" ]; then
      export PATH="$PWD/zisk/target/release:$PATH"
    elif [ -x "binaries/zisk-binary" ]; then
      mkdir -p /tmp/zisk-bin-shim
      ln -sf "$PWD/binaries/zisk-binary" /tmp/zisk-bin-shim/ziskemu
      export PATH="/tmp/zisk-bin-shim:$PATH"
    else
      echo "  Error: ziskemu not found on PATH, in zisk/target/release/, or binaries/zisk-binary"
      return 1
    fi
  fi

  # ere-zisk also needs libiomp5 at runtime
  if [ -d "act4-runner/lib-shims" ]; then
    export LD_LIBRARY_PATH="${PWD}/act4-runner/lib-shims${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi

  mkdir -p "test-results/${ZKVM}"

  # Determine job count for act4-runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # Run native suite
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: $MODE)..."
    "$RUNNER" \
      --zkvm zisk-ere \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "test-results/${ZKVM}" \
      --suite act4 \
      --label full-isa \
      --mode "$MODE" \
      $RUNNER_JOBS || true
  fi

  # Run target suite
  if [ -d "$ELF_DIR/target" ]; then
    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      --zkvm zisk-ere \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "test-results/${ZKVM}" \
      --suite act4-target \
      --label standard-isa \
      --mode "$MODE" \
      $RUNNER_JOBS || true
  fi

  process_results "$ZKVM"
}

# run_legacy_pipeline <zkvm> — original Docker-based test execution
run_legacy_pipeline() {
  local ZKVM="$1"

  if [ ! -f "binaries/${ZKVM}-binary" ]; then
    echo "  Warning: No binary found for $ZKVM at binaries/${ZKVM}-binary, skipping"
    return
  fi

  chmod +x "binaries/${ZKVM}-binary" 2>/dev/null || true

  DOCKER_DIR="docker/${ZKVM}"
  if [ ! -d "$DOCKER_DIR" ]; then
    echo "  Warning: No Docker config at $DOCKER_DIR, skipping $ZKVM"
    return
  fi

  echo "Building Docker image for $ZKVM..."
  docker build -t "${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" . || {
    echo "Failed to build Docker image for $ZKVM"
    return
  }

  mkdir -p "test-results/${ZKVM}"

  CPUSET_ARG=""
  if [ -n "${JOBS:-}" ]; then
    LAST_CORE=$((JOBS - 1))
    CPUSET_ARG="--cpuset-cpus=0-${LAST_CORE}"
    echo "  Limiting to cores 0-${LAST_CORE} (${JOBS} cores total)"
  fi

  JOBS_ARG=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    JOBS_ARG="-e ACT4_JOBS=${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    JOBS_ARG="-e ACT4_JOBS=${JOBS}"
  fi

  LOG_FILE="test-results/${ZKVM}/act4.log"
  echo "Running tests for $ZKVM... (log: $LOG_FILE)"
  docker run --rm \
    ${CPUSET_ARG} \
    ${JOBS_ARG} \
    -v "$PWD/binaries/${ZKVM}-binary:/dut/${ZKVM}-binary" \
    -v "$PWD/act4-configs/${ZKVM}:/act4/config/${ZKVM}" \
    -v "$PWD/test-results/${ZKVM}:/results" \
    "${ZKVM}:latest" > "$LOG_FILE" 2>&1 || {
    echo "  Container failed for $ZKVM — check $LOG_FILE"
    return
  }

  process_results "$ZKVM"
}

for ZKVM in $ZKVMS; do
  if [ "$ZKVM" = "zisk" ]; then
    run_zisk_split_pipeline || true
  else
    run_legacy_pipeline "$ZKVM" || true
  fi
done
