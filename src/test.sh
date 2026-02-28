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

for ZKVM in $ZKVMS; do
  if [ ! -f "binaries/${ZKVM}-binary" ]; then
    echo "  ⚠️  No binary found for $ZKVM at binaries/${ZKVM}-binary, skipping"
    continue
  fi

  chmod +x "binaries/${ZKVM}-binary" 2>/dev/null || true

  DOCKER_DIR="docker/${ZKVM}"
  if [ ! -d "$DOCKER_DIR" ]; then
    echo "  ⚠️  No Docker config at $DOCKER_DIR, skipping $ZKVM"
    continue
  fi

  echo "🔨 Building Docker image for $ZKVM..."
  docker build -t "${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" . || {
    echo "❌ Failed to build Docker image for $ZKVM"
    continue
  }

  mkdir -p "test-results/${ZKVM}"

  CPUSET_ARG=""
  if [ -n "${JOBS:-}" ]; then
    LAST_CORE=$((JOBS - 1))
    CPUSET_ARG="--cpuset-cpus=0-${LAST_CORE}"
    echo "  📌 Limiting to cores 0-${LAST_CORE} (${JOBS} cores total)"
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
    echo "  ❌ Container failed for $ZKVM — check $LOG_FILE"
    continue
  }

  mkdir -p data/history
  TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
  ZKVM_COMMIT=$(cat "data/commits/${ZKVM}.txt" 2>/dev/null || jq -r ".zkvms.${ZKVM}.commit // \"unknown\"" config.json 2>/dev/null || echo "unknown")
  RUN_DATE=$(date -u +"%Y-%m-%d")

  # Process results for native and target suites
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
        echo "  ⚠️  No summary generated for $ZKVM (container may have failed)"
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
      STATUS_EMOJI="✅"
    else
      STATUS_EMOJI="❌"
    fi

    echo "  📋 ACT4 ${ZKVM} (${SUITE_LABEL}): ${TEST_COUNT} tests in results-act4-${FILE_LABEL}.json"
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
done
