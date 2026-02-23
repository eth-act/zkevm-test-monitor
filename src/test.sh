#!/bin/bash
set -e

# Parse flags
TEST_SUITE=""
TARGETS=""
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --arch)
      TEST_SUITE="arch"
      shift
      ;;
    --extra)
      TEST_SUITE="extra"
      shift
      ;;
    --act4)
      TEST_SUITE="act4"
      shift
      ;;
    --build-only)
      BUILD_ONLY=true
      shift
      ;;
    *)
      TARGETS="$TARGETS $1"
      shift
      ;;
  esac
done

# Require one of the flags to be specified
if [ -z "$TEST_SUITE" ]; then
  echo "❌ Error: Must specify --arch, --extra, or --act4"
  echo "Usage: $0 [--arch|--extra|--act4] [--build-only] [target1 target2 ...]"
  exit 1
fi

# Default to "all" if no targets specified
TARGETS="${TARGETS:-all}"
# Remove leading space
TARGETS="${TARGETS# }"

export TEST_SUITE

# Handle ACT4 test suite (self-checking ELFs, no signature comparison)
if [ "$TEST_SUITE" = "act4" ]; then
  # Determine which ZKVMs to test
  if [ "$TARGETS" = "all" ] || [ -z "$TARGETS" ]; then
    ZKVMS=""
    for dir in docker/act4-*/; do
      [ -d "$dir" ] && ZKVMS="$ZKVMS $(basename "$dir" | sed 's/^act4-//')"
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

    DOCKER_DIR="docker/act4-${ZKVM}"
    if [ ! -d "$DOCKER_DIR" ]; then
      echo "  ⚠️  No ACT4 Docker config at $DOCKER_DIR, skipping $ZKVM"
      continue
    fi

    echo "🔨 Building ACT4 Docker image for $ZKVM..."
    docker build -t "act4-${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" . || {
      echo "❌ Failed to build ACT4 Docker image for $ZKVM"
      continue
    }

    mkdir -p "test-results/${ZKVM}"

    CPUSET_ARG=""
    if [ -n "${JOBS:-}" ]; then
      LAST_CORE=$((JOBS - 1))
      CPUSET_ARG="--cpuset-cpus=0-${LAST_CORE}"
      echo "  📌 Limiting to cores 0-${LAST_CORE} (${JOBS} cores total)"
    fi

    # Only pass ACT4_JOBS if explicitly set; otherwise let the container
    # entrypoint decide (e.g. Zisk auto-scales based on available RAM).
    JOBS_ARG=""
    if [ -n "${ACT4_JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${ACT4_JOBS}"
    elif [ -n "${JOBS:-}" ]; then
      JOBS_ARG="-e ACT4_JOBS=${JOBS}"
    fi

    echo "Running ACT4 tests for $ZKVM..."
    docker run --rm \
      ${CPUSET_ARG} \
      ${JOBS_ARG} \
      -v "$PWD/binaries/${ZKVM}-binary:/dut/${ZKVM}-binary" \
      -v "$PWD/riscv-arch-test/config/${ZKVM}:/act4/config/${ZKVM}" \
      -v "$PWD/test-results/${ZKVM}:/results" \
      "act4-${ZKVM}:latest" || true

    mkdir -p data/history
    TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
    ZKVM_COMMIT=$(cat "data/commits/${ZKVM}.txt" 2>/dev/null || jq -r ".zkvms.${ZKVM}.commit // \"unknown\"" config.json 2>/dev/null || echo "unknown")
    RUN_DATE=$(date -u +"%Y-%m-%d")

    # Process results for native, target, and rvi20 suites
    for ACT4_SUFFIX in "" "-target" "-rvi20"; do
      SUMMARY_FILE="test-results/${ZKVM}/summary-act4${ACT4_SUFFIX}.json"
      RESULTS_FILE="test-results/${ZKVM}/results-act4${ACT4_SUFFIX}.json"
      LABEL="ACT4${ACT4_SUFFIX:+ (${ACT4_SUFFIX#-})}"
      ISA="rv32im"
      SUITE="act4"
      if [ "$ACT4_SUFFIX" = "-target" ]; then
        ISA="rv64im_zicclsm"
        SUITE="act4-target"
      elif [ "$ACT4_SUFFIX" = "-rvi20" ]; then
        ISA="rv64imafdc_rvi20"
        SUITE="act4-rvi20"
      fi

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
        echo "  📋 ${LABEL} per-test results: ${TEST_COUNT} tests in results-act4${ACT4_SUFFIX}.json"
      fi
      echo "  ✅ ${LABEL} ${ZKVM}: ${PASSED}/${TOTAL} passed"

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
  exit 0
fi

# Load config
if [ ! -f config.json ]; then
  echo "❌ config.json not found"
  exit 1
fi

# Setup RISCOF (now integrated locally)
if [ ! -d "riscof" ]; then
  echo "❌ riscof directory not found - riscof should be integrated into this repository"
  exit 1
fi

# Build RISCOF Docker image from local directory
echo "🔨 Building RISCOF Docker image..."
cd riscof
docker build -t riscof:latest . || {
  echo "❌ Failed to build RISCOF Docker image"
  cd ..
  exit 1
}
cd ..

# Determine which ZKVMs to test
if [ "$TARGETS" = "all" ]; then
  ZKVMS=$(jq -r '.zkvms | keys[]' config.json)
else
  ZKVMS="$TARGETS"
fi

# Test each ZKVM
for ZKVM in $ZKVMS; do
  echo "Testing $ZKVM..."

  # Check binary exists
  if [ ! -f "binaries/${ZKVM}-binary" ]; then
    echo "  ⚠️  No binary found, skipping"
    continue
  fi

  # Check plugin exists in riscof repo
  if [ ! -d "riscof/plugins/${ZKVM}" ]; then
    echo "  ⚠️  No plugin found at riscof/plugins/${ZKVM}"
    echo "  Make sure the riscof symlink points to your riscof repository"
    continue
  fi

  # Make binary executable if not already (skip if permission denied)
  chmod +x "binaries/${ZKVM}-binary" 2> /dev/null || true

  # Run RISCOF tests (allow non-zero exit for test failures)
  mkdir -p test-results/${ZKVM}

  # Prepare compile-only argument if --build-only flag is set
  COMPILE_ONLY_ARG=""
  if [ "$BUILD_ONLY" = true ]; then
    COMPILE_ONLY_ARG="compile-only"
  fi

  # Use JOBS environment variable if set, otherwise default to 48
  RISCOF_JOBS=${JOBS:-48}

  # Build cpuset argument to pin container to specific cores
  # If JOBS=8, use cores 0-7; if JOBS=48, use cores 0-47
  CPUSET_ARG=""
  if [ -n "$JOBS" ]; then
    LAST_CORE=$((JOBS - 1))
    CPUSET_ARG="--cpuset-cpus=0-${LAST_CORE}"
    echo "  📌 Limiting to cores 0-${LAST_CORE} (${JOBS} cores total)"
  fi

  docker run --rm \
    ${CPUSET_ARG} \
    -e RISCOF_JOBS=${RISCOF_JOBS} \
    -v "$PWD/binaries/${ZKVM}-binary:/dut/bin/dut-exe" \
    -v "$PWD/riscof/plugins/${ZKVM}:/dut/plugin" \
    -v "$PWD/test-results/${ZKVM}:/riscof/riscof_work" \
    -v "$PWD/extra-tests:/extra-tests" \
    riscof:latest \
    "${ZKVM}" "${TEST_SUITE}" ${COMPILE_ONLY_ARG} || true

  # Copy report with suite suffix
  if [ -f "test-results/${ZKVM}/report.html" ]; then
    cp "test-results/${ZKVM}/report.html" "test-results/${ZKVM}/report-${TEST_SUITE}.html"
  fi

  # Parse test results from HTML report
  if [ -f "test-results/${ZKVM}/report-${TEST_SUITE}.html" ]; then
    # Extract pass/fail counts from the HTML report
    PASSED=$(grep -oE '<span class="passed">[0-9]+Passed</span>' "test-results/${ZKVM}/report-${TEST_SUITE}.html" | grep -oE '[0-9]+' | head -1 || echo "0")
    FAILED=$(grep -oE '<span class="failed">[0-9]+Failed</span>' "test-results/${ZKVM}/report-${TEST_SUITE}.html" | grep -oE '[0-9]+' | head -1 || echo "0")

    # If that didn't work, count the actual result rows
    if [ "$PASSED" = "0" ] && [ "$FAILED" = "0" ]; then
      PASSED=$(grep -c '<td class="col-result">Passed</td>' "test-results/${ZKVM}/report-${TEST_SUITE}.html" 2> /dev/null || echo "0")
      FAILED=$(grep -c '<td class="col-result">Failed</td>' "test-results/${ZKVM}/report-${TEST_SUITE}.html" 2> /dev/null || echo "0")
    fi

    TOTAL=$((PASSED + FAILED))

    # Create summary.json for update script (with suite-specific file)
    cat > "test-results/${ZKVM}/summary-${TEST_SUITE}.json" << EOF
{
  "zkvm": "${ZKVM}",
  "suite": "${TEST_SUITE}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF

    # Record history with suite tracking
    mkdir -p data/history
    HISTORY_FILE="data/history/${ZKVM}-${TEST_SUITE}.json"
    TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2> /dev/null | head -c 8 || echo "unknown")
    ZKVM_COMMIT=$(cat "data/commits/${ZKVM}.txt" 2> /dev/null || jq -r ".zkvms.${ZKVM}.commit" config.json || echo "unknown")
    ISA=$(grep -oP 'ISA:\s*\K\S+' "riscof/plugins/${ZKVM}/${ZKVM}_isa.yaml" 2> /dev/null | tr '[:upper:]' '[:lower:]' || echo "unknown")
    RUN_DATE=$(date -u +"%Y-%m-%d")

    # Create or update history file
    if [ -f "$HISTORY_FILE" ]; then
      # Append to existing history
      jq --arg date "$RUN_DATE" \
        --arg monitor "$TEST_MONITOR_COMMIT" \
        --arg zkvm "$ZKVM_COMMIT" \
        --arg isa "$ISA" \
        --arg suite "$TEST_SUITE" \
        --argjson passed "$PASSED" \
        --argjson total "$TOTAL" \
        '.runs += [{
                   "date": $date,
                   "test_monitor_commit": $monitor,
                   "zkvm_commit": $zkvm,
                   "isa": $isa,
                   "suite": $suite,
                   "passed": $passed,
                   "total": $total,
                   "notes": ""
               }]' "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      # Create new history file
      cat > "$HISTORY_FILE" << HISTORY
{
  "zkvm": "${ZKVM}",
  "suite": "${TEST_SUITE}",
  "runs": [
    {
      "date": "${RUN_DATE}",
      "test_monitor_commit": "${TEST_MONITOR_COMMIT}",
      "zkvm_commit": "${ZKVM_COMMIT}",
      "isa": "${ISA}",
      "suite": "${TEST_SUITE}",
      "passed": ${PASSED},
      "total": ${TOTAL},
      "notes": ""
    }
  ]
}
HISTORY
    fi

    echo "  ✅ Tested ${ZKVM}: ${PASSED}/${TOTAL} passed"
  else
    echo "  ⚠️  Tests ran but no report generated"
  fi
done

