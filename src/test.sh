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
  RUN_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Resolve commit: check Docker image first, then config.json
  ZKVM_COMMIT=$(docker run --rm --entrypoint cat "zkvm-${ZKVM}:latest" /commit.txt 2>/dev/null || \
    jq -r ".zkvms.${ZKVM}.commit // \"unknown\"" config.json 2>/dev/null || echo "unknown")

  for SUITE_TYPE in full standard; do
    if [ "$SUITE_TYPE" = "full" ]; then
      FILE_LABEL="full-isa"
      SUITE="act4-full"
    else
      FILE_LABEL="standard-isa"
      SUITE="act4-standard"
    fi

    SUMMARY_FILE="test-results/${ZKVM}/summary-act4-${FILE_LABEL}.json"
    RESULTS_FILE="test-results/${ZKVM}/results-act4-${FILE_LABEL}.json"

    if [ ! -f "$SUMMARY_FILE" ]; then
      if [ "$SUITE_TYPE" = "full" ]; then
        echo "  Warning: No summary generated for $ZKVM (container may have failed)"
      fi
      continue
    fi

    PASSED=$(jq '.passed' "$SUMMARY_FILE")
    FAILED=$(jq '.failed' "$SUMMARY_FILE")
    TOTAL=$(jq '.total' "$SUMMARY_FILE")

    # Build per-test array (empty array if results file missing)
    if [ -f "$RESULTS_FILE" ]; then
      TESTS_JSON=$(jq '.tests' "$RESULTS_FILE")
    else
      TESTS_JSON="[]"
    fi

    if [ "$FAILED" -eq 0 ]; then
      STATUS_EMOJI="+"
    else
      STATUS_EMOJI="x"
    fi

    echo "  ACT4 ${ZKVM} (${SUITE}): ${TOTAL} tests"
    echo "     ${STATUS_EMOJI} ${PASSED}/${TOTAL} passed"

    HISTORY_FILE="data/history/${ZKVM}-${SUITE}.json"

    # Build run entry as JSON
    RUN_ENTRY=$(jq -n \
      --arg date "$RUN_DATE" \
      --arg commit "$ZKVM_COMMIT" \
      --arg isa "$(jq -r ".zkvms.${ZKVM}.isa // \"unknown\"" config.json)" \
      --argjson passed "$PASSED" \
      --argjson failed "$FAILED" \
      --argjson total "$TOTAL" \
      --argjson tests "$TESTS_JSON" \
      '{date: $date, commit: $commit, isa: $isa, passed: $passed, failed: $failed, total: $total, tests: $tests}')

    if [ -f "$HISTORY_FILE" ]; then
      jq --argjson run "$RUN_ENTRY" '.runs += [$run]' \
        "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      jq -n --arg zkvm "$ZKVM" --arg suite "$SUITE" --argjson run "$RUN_ENTRY" \
        '{zkvm: $zkvm, suite: $suite, runs: [$run]}' > "$HISTORY_FILE"
    fi
  done
}

# run_zisk_split_pipeline — ELF generation in Docker, test execution on host via act4-runner
run_zisk_split_pipeline() {
  local ZKVM=zisk
  local ELF_DIR="test-results/${ZKVM}/elfs"
  local DOCKER_DIR="docker/${ZKVM}"

  # Zisk mode: execute, prove, or full (default). Set via ZISK_MODE env var.
  local MODE="${ZISK_MODE:-full}"

  # Check required binaries (built by ./run build zisk)
  if [ ! -f "binaries/zisk-binary" ]; then
    echo "  Error: binaries/zisk-binary not found. Run './run build zisk' first."
    return 1
  fi
  if [ "$MODE" != "execute" ]; then
    if [ ! -f "binaries/cargo-zisk" ]; then
      echo "  Error: binaries/cargo-zisk not found (required for mode=$MODE). Run './run build zisk' first."
      return 1
    fi
    if [ ! -f "binaries/libzisk_witness.so" ]; then
      echo "  Warning: binaries/libzisk_witness.so not found (may be required for proving)"
    fi
  fi

  # GPU binary selection
  local CARGO_ZISK="binaries/cargo-zisk"
  if [ -n "${ZISK_GPU:-}" ]; then
    if [ -f "binaries/cargo-zisk-cuda" ]; then
      CARGO_ZISK="binaries/cargo-zisk-cuda"
    else
      echo "  Error: GPU requested but cargo-zisk-cuda not found. Run 'ZISK_GPU=1 ./run build zisk' first."
      return 1
    fi
  fi

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

  # Build act4-runner if needed
  local RUNNER="act4-runner/target/release/act4-runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building act4-runner..."
    cargo build --release --manifest-path act4-runner/Cargo.toml 2>&1 || {
      echo "  Failed to build act4-runner"
      return 1
    }
  fi

  mkdir -p "test-results/${ZKVM}"

  # Determine job count for act4-runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # GPU flag for proving
  local GPU_ARG=""
  if [ -n "${ZISK_GPU:-}" ]; then
    GPU_ARG="--gpu"
  fi

  # Set LD_LIBRARY_PATH for bundled Zisk shared libs (built in Docker).
  # Host CUDA libs (/usr/local/cuda/lib64) must come first for GPU proving —
  # the Docker-bundled libcudart may not match the host driver exactly.
  if [ -d "binaries/zisk-lib" ]; then
    if [ -d "/usr/local/cuda/lib64" ]; then
      export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
      export LD_LIBRARY_PATH="$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  fi

  # Run native suite — always execute-only (no proving needed for full ISA)
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm zisk --binary binaries/zisk-binary \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "test-results/${ZKVM}" \
      --suite act4-full \
      --label full-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — uses requested mode (execute/prove/full)
  if [ -d "$ELF_DIR/target" ]; then
    local TARGET_ZKVM_ARG TARGET_PROVE_ARGS
    if [ "$MODE" = "execute" ]; then
      TARGET_ZKVM_ARG="--zkvm zisk --binary binaries/zisk-binary"
      TARGET_PROVE_ARGS=""
    else
      TARGET_ZKVM_ARG="--zkvm zisk-prove --binary binaries/zisk-binary --cargo-zisk $CARGO_ZISK"
      TARGET_PROVE_ARGS="$GPU_ARG"
      if [ -f "binaries/libzisk_witness.so" ]; then
        TARGET_ZKVM_ARG="$TARGET_ZKVM_ARG --witness-lib binaries/libzisk_witness.so"
      fi
    fi

    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      $TARGET_ZKVM_ARG \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "test-results/${ZKVM}" \
      --suite act4-standard \
      --label standard-isa \
      --mode "$MODE" \
      $TARGET_PROVE_ARGS $RUNNER_JOBS || true
  fi

  process_results "$ZKVM"
}

# run_jolt_split_pipeline — ELF generation in Docker, test execution + proving on host
run_jolt_split_pipeline() {
  local ZKVM=jolt
  local ELF_DIR="test-results/${ZKVM}/elfs"
  local DOCKER_DIR="docker/${ZKVM}"

  # Check required binary
  if [ ! -f "binaries/jolt-binary" ]; then
    echo "  Error: binaries/jolt-binary not found. Run './run build jolt' first."
    return 1
  fi

  # Auto-detect proving capability
  local HAS_PROVER=0
  if [ -f "binaries/jolt-prover" ]; then
    HAS_PROVER=1
    echo "  Jolt prover detected — proving will be enabled for target suite"
  fi

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

    # Clean old ELFs before regenerating
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

  # Build act4-runner if needed
  local RUNNER="act4-runner/target/release/act4-runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building act4-runner..."
    cargo build --release --manifest-path act4-runner/Cargo.toml 2>&1 || {
      echo "  Failed to build act4-runner"
      return 1
    }
  fi

  mkdir -p "test-results/${ZKVM}"

  # Determine job count for act4-runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # Run native suite — always execute-only
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm jolt --binary binaries/jolt-binary \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "test-results/${ZKVM}" \
      --suite act4-full \
      --label full-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — prove if prover is available
  if [ -d "$ELF_DIR/target" ]; then
    if [ "$HAS_PROVER" = "1" ]; then
      echo "Running $ZKVM target suite (mode: full)..."
      "$RUNNER" \
        --zkvm jolt-prove --binary binaries/jolt-binary \
        --jolt-prover binaries/jolt-prover \
        --elf-dir "$ELF_DIR/target" \
        --output-dir "test-results/${ZKVM}" \
        --suite act4-standard \
        --label standard-isa \
        --mode full \
        $RUNNER_JOBS || true
    else
      echo "Running $ZKVM target suite (mode: execute)..."
      "$RUNNER" \
        --zkvm jolt --binary binaries/jolt-binary \
        --elf-dir "$ELF_DIR/target" \
        --output-dir "test-results/${ZKVM}" \
        --suite act4-standard \
        --label standard-isa \
        --mode execute \
        $RUNNER_JOBS || true
    fi
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
  elif [ "$ZKVM" = "jolt" ]; then
    run_jolt_split_pipeline || true
  else
    run_legacy_pipeline "$ZKVM" || true
  fi
done
