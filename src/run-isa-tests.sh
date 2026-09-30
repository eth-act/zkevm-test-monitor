#!/bin/bash
set -e

source "$(dirname "$0")/generate_elfs.sh"

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
  for dir in zkvms/*/; do
    ZKVMS="$ZKVMS $(basename "$dir")"
  done
  ZKVMS="${ZKVMS# }"
else
  ZKVMS="$TARGETS"
fi

# process_results <zkvm> [notes] [native|ere] — reads summary/results JSON and updates
# history. The ere path reads out/<zkvm>/ere/, writes
# results/history/<zkvm>-ere-<suite>.json, and records the ere provenance of the run
# (ere-act4-<label>.json) and its mode (ERE_MODE)
# instead of the native build commit.
process_results() {
  local ZKVM="$1"
  local NOTES="${2:-}"
  local BACKEND_KIND="${3:-native}"
  local RESULTS_DIR="out/${ZKVM}"
  [ "$BACKEND_KIND" = "ere" ] && RESULTS_DIR="out/${ZKVM}/ere"

  mkdir -p results/history
  TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
  RUN_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ACT4_COMMIT_VAL=$(jq -r '.act4_commit // "unknown"' config.json)
  ACT4_VERSION_VAL=$(jq -r '.act4_version // ""' config.json)

  # Resolve commit from the binary that actually ran the tests.
  # Primary source: out/commits/<zkvm>.txt written by build.sh.
  # Fallback: resolve from the Docker image used for building.
  # (The ere path records its provenance file instead.)
  if [ "$BACKEND_KIND" = "ere" ]; then
    ZKVM_COMMIT=""
  elif [ -f "out/commits/${ZKVM}.txt" ]; then
    ZKVM_COMMIT=$(cat "out/commits/${ZKVM}.txt")
  else
    ZKVM_COMMIT=$(docker run --rm --entrypoint cat "zkvm-${ZKVM}:latest" /commit.txt 2>/dev/null | head -c 8 || echo "unknown")
    if [ "$ZKVM_COMMIT" != "unknown" ]; then
      mkdir -p out/commits
      echo "$ZKVM_COMMIT" > "out/commits/${ZKVM}.txt"
    fi
  fi

  # NATIVE_SUITES limits which native suites are recorded (the ere default records
  # only the native Full ISA suite).
  local SUITE_TYPES="${NATIVE_SUITES:-full standard}"
  [ "$BACKEND_KIND" = "ere" ] && SUITE_TYPES="standard"
  for SUITE_TYPE in $SUITE_TYPES; do
    if [ "$SUITE_TYPE" = "full" ]; then
      FILE_LABEL="full-isa"
      SUITE="act4-full"
    else
      FILE_LABEL="standard-isa"
      SUITE="act4-standard"
    fi

    SUMMARY_FILE="${RESULTS_DIR}/summary-act4-${FILE_LABEL}.json"
    RESULTS_FILE="${RESULTS_DIR}/results-act4-${FILE_LABEL}.json"

    if [ ! -f "$SUMMARY_FILE" ]; then
      if [ "$SUITE_TYPE" = "full" ]; then
        echo "  Warning: No summary generated for $ZKVM (container may have failed)"
      fi
      continue
    fi

    TOTAL=$(jq '.total' "$SUMMARY_FILE")
    PASSED_COUNT=$(jq '.passed' "$SUMMARY_FILE")
    FAILED_COUNT=$(jq '.failed' "$SUMMARY_FILE")

    # Read per-test arrays from results file (new compact format)
    if [ -f "$RESULTS_FILE" ]; then
      PASSED_JSON=$(jq '.passed' "$RESULTS_FILE")
      FAILED_JSON=$(jq '.failed' "$RESULTS_FILE")
      PROVE_FAILED_JSON=$(jq '.prove_failed' "$RESULTS_FILE")
      VERIFY_FAILED_JSON=$(jq '.verify_failed' "$RESULTS_FILE")
    else
      PASSED_JSON="[]"
      FAILED_JSON="[]"
      PROVE_FAILED_JSON="[]"
      VERIFY_FAILED_JSON="[]"
    fi

    # Check if proving was attempted (summary has "proved" field)
    HAS_PROVING=$(jq 'if .proved != null then true else false end' "$SUMMARY_FILE")

    if [ "$FAILED_COUNT" -eq 0 ]; then
      STATUS_EMOJI="+"
    else
      STATUS_EMOJI="x"
    fi

    echo "  ACT4 ${ZKVM} (${SUITE}): ${TOTAL} tests"
    echo "     ${STATUS_EMOJI} ${PASSED_COUNT}/${TOTAL} passed"

    HISTORY_FILE="results/history/${ZKVM}-${SUITE}.json"
    [ "$BACKEND_KIND" = "ere" ] && HISTORY_FILE="results/history/${ZKVM}-ere-${SUITE}.json"

    # Build run entry as JSON
    RUN_ENTRY=$(jq -n \
      --arg date "$RUN_DATE" \
      --arg commit "$ZKVM_COMMIT" \
      --arg monitor_commit "$TEST_MONITOR_COMMIT" \
      --arg act4_commit "$ACT4_COMMIT_VAL" \
      --arg act4_version "$ACT4_VERSION_VAL" \
      --arg isa "$(jq -r ".zkvms.${ZKVM}.isa // \"unknown\"" config.json)" \
      --argjson total "$TOTAL" \
      --argjson passed "$PASSED_JSON" \
      --argjson failed "$FAILED_JSON" \
      --argjson prove_failed "$PROVE_FAILED_JSON" \
      --argjson verify_failed "$VERIFY_FAILED_JSON" \
      --argjson has_proving "$HAS_PROVING" \
      --arg notes "$NOTES" \
      '{date: $date, commit: $commit, monitor_commit: $monitor_commit, act4_commit: $act4_commit, act4_version: $act4_version, isa: $isa, total: $total, passed: $passed, failed: $failed, prove_failed: $prove_failed, verify_failed: $verify_failed, has_proving: $has_proving} | if $notes != "" then . + {notes: $notes} else . end')

    if [ "$BACKEND_KIND" = "ere" ]; then
      RUN_ENTRY=$(jq -c --slurpfile ere "${RESULTS_DIR}/ere-act4-${FILE_LABEL}.json" \
        --arg mode "$ERE_MODE" \
        'del(.commit) + $ere[0] + {mode: $mode}' <<< "$RUN_ENTRY")
    fi

    if [ -f "$HISTORY_FILE" ]; then
      jq --argjson run "$RUN_ENTRY" '.runs += [$run]' \
        "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      jq -n --arg zkvm "$ZKVM" --arg suite "$SUITE" --argjson run "$RUN_ENTRY" \
        '{zkvm: $zkvm, suite: $suite, runs: [$run]}' > "$HISTORY_FILE"
    fi
  done
}

# run_zisk_split_pipeline — ELF generation in Docker, test execution on host via runner
run_zisk_split_pipeline() {
  local ZKVM=zisk
  local ELF_DIR="out/${ZKVM}/elfs"
  local DOCKER_DIR="zkvms/${ZKVM}"

  # Test mode: execute (emulate only), prove (emulate + prove), or full
  # (emulate + prove + verify, default). Set via ACT4_MODE env var.
  local MODE="${ACT4_MODE:-full}"

  # Check required binaries (built by ./run build zisk)
  if [ ! -f "out/bin/zisk-binary" ]; then
    echo "  Error: out/bin/zisk-binary not found. Run './run build zisk' first."
    return 1
  fi
  if [ "$MODE" != "execute" ]; then
    if [ ! -f "out/bin/cargo-zisk" ]; then
      echo "  Error: out/bin/cargo-zisk not found (required for mode=$MODE). Run './run build zisk' first."
      return 1
    fi
    if [ ! -f "out/bin/libzisk_witness.so" ]; then
      echo "  Warning: out/bin/libzisk_witness.so not found (may be required for proving)"
    fi
  fi

  # GPU binary selection
  local CARGO_ZISK="out/bin/cargo-zisk"
  if [ -n "${GPU:-}" ]; then
    if [ -f "out/bin/cargo-zisk-cuda" ]; then
      CARGO_ZISK="out/bin/cargo-zisk-cuda"
    else
      echo "  Error: GPU requested but cargo-zisk-cuda not found. Run 'GPU=1 ./run build zisk' first."
      return 1
    fi
  fi

  generate_act4_elfs "$ZKVM" "$ELF_DIR" || return 1

  # Build runner if needed
  local RUNNER="src/runner/target/release/runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building runner..."
    cargo build --release --manifest-path src/runner/Cargo.toml 2>&1 || {
      echo "  Failed to build runner"
      return 1
    }
  fi

  mkdir -p "out/${ZKVM}"

  # Determine job count for runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # GPU flag for proving
  local GPU_ARG=""
  if [ -n "${GPU:-}" ]; then
    GPU_ARG="--gpu"
  fi

  # Set LD_LIBRARY_PATH for bundled Zisk shared libs (built in Docker).
  # Host CUDA libs (/usr/local/cuda/lib64) must come first for GPU proving —
  # the Docker-bundled libcudart may not match the host driver exactly.
  if [ -d "out/bin/zisk-lib" ]; then
    if [ -d "/usr/local/cuda/lib64" ]; then
      export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$PWD/out/bin/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    else
      export LD_LIBRARY_PATH="$PWD/out/bin/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
  fi

  # Run native suite — always execute-only (no proving needed for full ISA)
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm zisk --binary out/bin/zisk-binary \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "out/${ZKVM}" \
      --suite act4-full \
      --label full-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — uses requested mode (execute/prove/full)
  if [ -d "$ELF_DIR/target" ]; then
    local TARGET_ZKVM_ARG TARGET_PROVE_ARGS
    if [ "$MODE" = "execute" ]; then
      TARGET_ZKVM_ARG="--zkvm zisk --binary out/bin/zisk-binary"
      TARGET_PROVE_ARGS=""
    else
      TARGET_ZKVM_ARG="--zkvm zisk --binary out/bin/zisk-binary --cargo-zisk $CARGO_ZISK"
      TARGET_PROVE_ARGS="$GPU_ARG"
      if [ -f "out/bin/libzisk_witness.so" ]; then
        TARGET_ZKVM_ARG="$TARGET_ZKVM_ARG --witness-lib out/bin/libzisk_witness.so"
      fi
    fi

    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      $TARGET_ZKVM_ARG \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "out/${ZKVM}" \
      --suite act4-standard \
      --label standard-isa \
      --mode "$MODE" \
      $TARGET_PROVE_ARGS $RUNNER_JOBS || true
  fi

  process_results "$ZKVM"

}

# run_sp1_split_pipeline — ELF generation in Docker, execution + GPU proving on host
run_sp1_split_pipeline() {
  local ZKVM=sp1
  local ELF_DIR="out/${ZKVM}/elfs"
  local DOCKER_DIR="zkvms/${ZKVM}"

  # Test mode: execute (emulate only), prove (emulate + prove), or full
  # (emulate + prove + verify, default). Set via ACT4_MODE env var.
  local MODE="${ACT4_MODE:-full}"

  # sp1-binary = sp1-perf-executor (execute-only). Required for every mode.
  if [ ! -f "out/bin/sp1-binary" ]; then
    echo "  Error: out/bin/sp1-binary not found. Run './run build sp1' first."
    return 1
  fi
  # sp1-prover = sp1-perf (execute + GPU prove + verify). Required for prove/full.
  if [ "$MODE" != "execute" ] && [ ! -f "out/bin/sp1-prover" ]; then
    echo "  Error: out/bin/sp1-prover not found (required for mode=$MODE). Run './run build sp1' first."
    return 1
  fi
  chmod +x out/bin/sp1-binary out/bin/sp1-prover 2>/dev/null || true

  generate_act4_elfs "$ZKVM" "$ELF_DIR" || return 1

  # Build runner if needed
  local RUNNER="src/runner/target/release/runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building runner..."
    cargo build --release --manifest-path src/runner/Cargo.toml 2>&1 || {
      echo "  Failed to build runner"
      return 1
    }
  fi

  mkdir -p "out/${ZKVM}"

  # Determine job count for runner (native execute; prove is forced to 1)
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # sp1-perf's CUDA prover spawns a host-native sp1-gpu-server that needs
  # libcudart.so.12. The host /opt/cuda may be absent, so locate a dir that
  # provides it (SP1_CUDA_LIB env overrides).
  if [ "$MODE" != "execute" ]; then
    local CUDA_LIB="${SP1_CUDA_LIB:-}"
    if [ -z "$CUDA_LIB" ]; then
      for d in /usr/local/cuda/lib64 /opt/cuda/lib64 /usr/local/cuda-12/lib64 \
               /usr/local/cuda-12.8/lib64 /usr/local/lib/ollama/cuda_v12; do
        if ls "$d"/libcudart.so.12* >/dev/null 2>&1; then CUDA_LIB="$d"; break; fi
      done
    fi
    if [ -n "$CUDA_LIB" ]; then
      export LD_LIBRARY_PATH="${CUDA_LIB}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      echo "  CUDA runtime for sp1-gpu-server: $CUDA_LIB"
    else
      echo "  Warning: no libcudart.so.12 found — GPU proving may fail. Set SP1_CUDA_LIB=<dir>."
    fi
  fi

  # Run native suite — always execute-only (proving only applies to the target ISA)
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm sp1 --binary out/bin/sp1-binary --sp1-perf out/bin/sp1-prover \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "out/${ZKVM}" \
      --suite act4-full \
      --label full-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — execute (+ GPU prove + verify per MODE)
  if [ -d "$ELF_DIR/target" ]; then
    local TARGET_GPU_ARG=""
    if [ "$MODE" != "execute" ]; then
      TARGET_GPU_ARG="--gpu"  # GPU-only proving per project scope
    fi
    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      --zkvm sp1 --binary out/bin/sp1-binary --sp1-perf out/bin/sp1-prover \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "out/${ZKVM}" \
      --suite act4-standard \
      --label standard-isa \
      --mode "$MODE" \
      $TARGET_GPU_ARG $RUNNER_JOBS || true
  fi

  process_results "$ZKVM"

}

# run_lambdavm_split_pipeline — ELF generation in Docker, test execution + proving on host
run_lambdavm_split_pipeline() {
  local ZKVM=lambdavm
  local ELF_DIR="out/${ZKVM}/elfs"
  local DOCKER_DIR="zkvms/${ZKVM}"

  # Test mode: execute (emulate only), prove (emulate + prove), or full
  # (emulate + prove + verify, default). Set via ACT4_MODE env var.
  local MODE="${ACT4_MODE:-full}"

  # A single binary (the lambdavm cli) handles execute, prove, and verify.
  if [ ! -f "out/bin/lambdavm-binary" ]; then
    echo "  Error: out/bin/lambdavm-binary not found. Run './run build lambdavm' first."
    return 1
  fi

  generate_act4_elfs "$ZKVM" "$ELF_DIR" || return 1

  # Build runner if needed
  local RUNNER="src/runner/target/release/runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building runner..."
    cargo build --release --manifest-path src/runner/Cargo.toml 2>&1 || {
      echo "  Failed to build runner"
      return 1
    }
  fi

  mkdir -p "out/${ZKVM}"

  # Determine job count for runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # Run native suite (execute-only)
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm lambdavm --binary out/bin/lambdavm-binary \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "out/${ZKVM}" \
      --suite act4-full \
      --label full-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — uses requested mode (execute/prove/full)
  if [ -d "$ELF_DIR/target" ]; then
    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      --zkvm lambdavm --binary out/bin/lambdavm-binary \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "out/${ZKVM}" \
      --suite act4-standard \
      --label standard-isa \
      --mode "$MODE" \
      $RUNNER_JOBS || true
  fi

  process_results "$ZKVM"
}

# run_openvm_split_pipeline — ELF generation in Docker, GPU execution + proving on host.
#
# OpenVM's runner binary is built with the `cuda` feature (GPU prover), so it links the
# CUDA runtime libs and must run with them on LD_LIBRARY_PATH. The native RV64IM
# suite is an auxiliary execute-only check; the ETH-ACT target suite supplies both
# Full and Standard dashboard results because those categories coincide for OpenVM.
run_openvm_split_pipeline() {
  local ZKVM=openvm
  local ELF_DIR="out/${ZKVM}/elfs"
  local DOCKER_DIR="zkvms/${ZKVM}"

  # Test mode: execute (emulate only), prove (emulate + prove), or full
  # (emulate + prove + verify, default). Set via ACT4_MODE env var.
  local MODE="${ACT4_MODE:-full}"

  # A single binary (openvm-binary) handles execute, prove, and verify.
  if [ ! -f "out/bin/openvm-binary" ]; then
    echo "  Error: out/bin/openvm-binary not found. Run './run build openvm' first."
    return 1
  fi

  generate_act4_elfs "$ZKVM" "$ELF_DIR" || return 1

  # Build runner if needed
  local RUNNER="src/runner/target/release/runner"
  if [ ! -x "$RUNNER" ]; then
    echo "  Building runner..."
    cargo build --release --manifest-path src/runner/Cargo.toml 2>&1 || {
      echo "  Failed to build runner"
      return 1
    }
  fi

  mkdir -p "out/${ZKVM}"

  # Determine job count for runner
  local RUNNER_JOBS=""
  if [ -n "${ACT4_JOBS:-}" ]; then
    RUNNER_JOBS="-j ${ACT4_JOBS}"
  elif [ -n "${JOBS:-}" ]; then
    RUNNER_JOBS="-j ${JOBS}"
  fi

  # The openvm-binary links the bundled CUDA runtime libs (libcudart/libcublas, built
  # against CUDA 12.9). Put the bundled libs first so the version-matched runtime is
  # used; the host driver's libcuda.so is resolved from the default loader paths. Host
  # CUDA dirs are appended as a fallback. Needed even for execute (the binary links the
  # CUDA libs at load time regardless of whether a proof runs).
  if [ -d "out/bin/openvm-lib" ]; then
    export LD_LIBRARY_PATH="$PWD/out/bin/openvm-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  for cuda_dir in /opt/cuda/lib64 /usr/local/cuda/lib64; do
    [ -d "$cuda_dir" ] && export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}$cuda_dir"
  done

  # Run the auxiliary native suite (execute-only). Do not publish this as Full:
  # OpenVM's Full and Standard compliance sets are both the 72-test target suite.
  if [ -d "$ELF_DIR/native" ]; then
    echo "Running $ZKVM native suite (mode: execute)..."
    "$RUNNER" \
      --zkvm openvm --binary out/bin/openvm-binary \
      --elf-dir "$ELF_DIR/native" \
      --output-dir "out/${ZKVM}" \
      --suite act4-native \
      --label native-isa \
      --mode execute \
      $RUNNER_JOBS || true
  fi

  # Run target suite — uses requested mode (execute/prove/full). Proving runs on the GPU.
  if [ -d "$ELF_DIR/target" ]; then
    local TARGET_ZKVM_ARG TARGET_PROVE_ARGS
    if [ "$MODE" = "execute" ]; then
      TARGET_ZKVM_ARG="--zkvm openvm --binary out/bin/openvm-binary"
      TARGET_PROVE_ARGS=""
    else
      TARGET_ZKVM_ARG="--zkvm openvm --binary out/bin/openvm-binary"
      TARGET_PROVE_ARGS="--gpu"
    fi

    echo "Running $ZKVM target suite (mode: $MODE)..."
    "$RUNNER" \
      $TARGET_ZKVM_ARG \
      --elf-dir "$ELF_DIR/target" \
      --output-dir "out/${ZKVM}" \
      --suite act4-standard \
      --label standard-isa \
      --mode "$MODE" \
      $TARGET_PROVE_ARGS $RUNNER_JOBS || true

    # Full == Standard for OpenVM. Reuse the one target execution/proof result
    # for both dashboard categories, changing only the suite metadata.
    if [ -f "out/${ZKVM}/summary-act4-standard-isa.json" ] &&
       [ -f "out/${ZKVM}/results-act4-standard-isa.json" ]; then
      jq '.suite = "act4-full"' \
        "out/${ZKVM}/summary-act4-standard-isa.json" \
        > "out/${ZKVM}/summary-act4-full-isa.json"
      jq '.suite = "act4-full"' \
        "out/${ZKVM}/results-act4-standard-isa.json" \
        > "out/${ZKVM}/results-act4-full-isa.json"
    fi
  fi

  process_results "$ZKVM"

}

# run_ere_pipeline <zkvm> — BACKEND=ere: ELFs from this repository, run on the
# official ghcr.io/eth-act/ere images of the ere revision that the runner pins
# (src/runner/Cargo.toml). ere builds and runs the zkVM; no local zkVM build.
run_ere_pipeline() {
  local ZKVM="$1"
  local ELF_DIR="out/${ZKVM}/elfs"
  local OUT_DIR="out/${ZKVM}/ere"
  # Standard ISA mode: execute, prove or full (execute + prove + verify, default).
  local MODE="${ACT4_MODE:-full}"

  generate_act4_elfs "$ZKVM" "$ELF_DIR" || return 1

  # Always build: cargo rebuilds only what changed, so the binary is never stale.
  local RUNNER="src/runner/target/ere/release/runner"
  echo "  Building runner (ere)..."
  cargo build --release --quiet --features ere --target-dir src/runner/target/ere \
    --manifest-path src/runner/Cargo.toml || { echo "  Failed to build runner (ere)"; return 1; }

  rm -rf "$OUT_DIR" && mkdir -p "$OUT_DIR"
  # Proving needs the GPU images; execute runs on the CPU images.
  local GPU_ARG=""
  [ "$MODE" != "execute" ] && GPU_ARG="--gpu"

  echo "Running $ZKVM target suite on ere (mode: $MODE)..."
  "$RUNNER" --zkvm "ere-$ZKVM" --elf-dir "$ELF_DIR/target" --output-dir "$OUT_DIR" \
    --suite act4-standard --label standard-isa --mode "$MODE" $GPU_ARG || true

  # ere runs the Standard ISA (RV64IM_Zicclsm) only; Full ISA stays on the native path.
  ERE_MODE="$MODE" process_results "$ZKVM" "" ere
}

# BACKEND=ere (default) runs the Standard ISA suite of OpenVM, SP1 and ZisK through ere,
# then the Full ISA suite on the native path (execute only; needs ./run build <zkvm>).
# BACKEND=native builds and runs both suites in this repository's containers, for
# reproducing bugs and testing branches. LambdaVM always runs native until ere supports it.
BACKEND="${BACKEND:-ere}"
case "$BACKEND" in
  native|ere) ;;
  *) echo "Unknown BACKEND=$BACKEND (expected native or ere)" >&2; exit 2 ;;
esac

for ZKVM in $ZKVMS; do
  if [ "$BACKEND" = "ere" ] && [[ " openvm sp1 zisk " == *" $ZKVM "* ]]; then
    run_ere_pipeline "$ZKVM" || true
    echo "Running $ZKVM Full ISA suite on the native path (mode: execute)..."
    ACT4_MODE=execute NATIVE_SUITES=full "run_${ZKVM}_split_pipeline" || true
  elif [ "$ZKVM" = "zisk" ]; then
    run_zisk_split_pipeline || true
  elif [ "$ZKVM" = "lambdavm" ]; then
    run_lambdavm_split_pipeline || true
  elif [ "$ZKVM" = "sp1" ]; then
    run_sp1_split_pipeline || true
  elif [ "$ZKVM" = "openvm" ]; then
    run_openvm_split_pipeline || true
  else
    echo "  Warning: No test pipeline for $ZKVM, skipping"
  fi
done
