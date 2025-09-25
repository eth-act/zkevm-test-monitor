#!/bin/bash
set -e

# Parse flags
TEST_SUITE=""
TARGETS=""

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
    *)
      TARGETS="$TARGETS $1"
      shift
      ;;
  esac
done

# Require one of the flags to be specified
if [ -z "$TEST_SUITE" ]; then
  echo "❌ Error: Must specify either --arch or --extra"
  echo "Usage: $0 [--arch|--extra] [target1 target2 ...]"
  exit 1
fi

# Default to "all" if no targets specified
TARGETS="${TARGETS:-all}"
# Remove leading space
TARGETS="${TARGETS# }"

export TEST_SUITE

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
  docker run --rm \
    -e "TEST_SUITE=${TEST_SUITE}" \
    -v "$PWD/binaries/${ZKVM}-binary:/dut/bin/dut-exe" \
    -v "$PWD/riscof/plugins/${ZKVM}:/dut/plugin" \
    -v "$PWD/test-results/${ZKVM}:/riscof/riscof_work" \
    riscof:latest || true

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

