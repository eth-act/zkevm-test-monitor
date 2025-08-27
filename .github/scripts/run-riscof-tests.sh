#!/bin/bash
# Script to run RISCOF tests using Docker
set -euo pipefail

ZKVM_NAME="$1"
BINARY_PATH="$2"
RESULTS_DIR="${3:-results/$ZKVM_NAME}"

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: Binary not found at $BINARY_PATH"
    exit 1
fi

# Use plugin from riscof repo
PLUGIN_DIR="riscof/plugins/$ZKVM_NAME"
if [ ! -d "$PLUGIN_DIR" ]; then
    echo "Error: Plugin directory not found at $PLUGIN_DIR"
    echo "Make sure the riscof symlink points to your riscof repository"
    exit 1
fi

echo "========================================="
echo "Running RISCOF tests for $ZKVM_NAME"
echo "Binary: $BINARY_PATH"
echo "Plugin: $PLUGIN_DIR"
echo "Results: $RESULTS_DIR"
echo "========================================="

# Create results directory
mkdir -p "$RESULTS_DIR"

# Always rebuild RISCOF Docker image to pick up latest changes
echo "Building RISCOF Docker image..."
if [ ! -d "riscof" ]; then
    echo "Error: riscof directory/symlink not found"
    echo "Please create a symlink: ln -s /path/to/your/riscof/repo riscof"
    exit 1
fi

# Build the Docker image with current commit hash
cd riscof && DOCKER_BUILDKIT=1 docker build --build-arg RISCOF_COMMIT=$(git rev-parse HEAD) -t riscof:latest . && cd ..

# Get RISCOF container version info
RISCOF_COMMIT=$(docker run --rm --entrypoint sh riscof:latest -c 'echo $RISCOF_COMMIT' 2>/dev/null || echo "unknown")
echo "Using RISCOF container built from commit: $RISCOF_COMMIT"

# Run RISCOF tests
echo "Running tests..."
docker run --rm \
    -v "$(pwd)/$PLUGIN_DIR:/dut/plugin" \
    -v "$(realpath $BINARY_PATH):/dut/bin/dut-exe" \
    -v "$(pwd)/$RESULTS_DIR:/riscof/riscof_work" \
    riscof:latest || true

# Check if report was generated
REPORT_FILE="$RESULTS_DIR/report.html"
if [ -f "$REPORT_FILE" ]; then
    echo "Test report generated: $REPORT_FILE"
    
    # Extract test summary
    echo "Extracting test summary..."
    
    # Try to extract from the summary line first (most reliable)
    # Format: <span class="passed">82Passed</span>, <span class="failed">0Failed</span>
    PASSED=$(grep -oE '<span class="passed">[0-9]+Passed</span>' "$REPORT_FILE" | grep -oE '[0-9]+' | head -1 || echo "0")
    FAILED=$(grep -oE '<span class="failed">[0-9]+Failed</span>' "$REPORT_FILE" | grep -oE '[0-9]+' | head -1 || echo "0")
    
    # If that didn't work, count the actual result rows
    if [ "$PASSED" = "0" ] && [ "$FAILED" = "0" ]; then
        PASSED=$(grep -c '<td class="col-result">Passed</td>' "$REPORT_FILE" 2>/dev/null || echo "0")
        FAILED=$(grep -c '<td class="col-result">Failed</td>' "$REPORT_FILE" 2>/dev/null || echo "0")
    fi
    
    TOTAL=$((PASSED + FAILED))
    
    # Avoid divide by zero
    if [ $TOTAL -eq 0 ]; then
        # If we still have no results, default to counting from expected 47 tests
        TOTAL=47
        PASSED=0
        FAILED=47
        PASS_RATE=0
    else
        PASS_RATE=$(echo "scale=2; $PASSED * 100 / $TOTAL" | bc)
    fi
    
    echo "Test Results: $PASSED/$TOTAL passed"
    
    # Try to get ZKVM commit from build info if available
    ZKVM_COMMIT=""
    if [ -f "artifacts/commit-info/${ZKVM_NAME}.json" ]; then
        ZKVM_COMMIT=$(jq -r '.commit' "artifacts/commit-info/${ZKVM_NAME}.json" 2>/dev/null || echo "")
    fi
    
    # If no commit info exists, try to get it from the config file
    if [ -z "$ZKVM_COMMIT" ] && [ -f "configs/zkvm-configs/${ZKVM_NAME}.json" ]; then
        CONFIG_COMMIT=$(jq -r '.commit' "configs/zkvm-configs/${ZKVM_NAME}.json" 2>/dev/null || echo "")
        if [ -n "$CONFIG_COMMIT" ] && [ "$CONFIG_COMMIT" != "null" ]; then
            echo "Using commit from config: $CONFIG_COMMIT"
            # Save it for future use
            mkdir -p artifacts/commit-info
            cat > "artifacts/commit-info/${ZKVM_NAME}.json" <<EOF
{
  "commit": "$CONFIG_COMMIT",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "config"
}
EOF
            ZKVM_COMMIT="$CONFIG_COMMIT"
        fi
    fi
    
    # Save summary to JSON (include zkvm_commit if available)
    if [ -n "$ZKVM_COMMIT" ]; then
        cat > "$RESULTS_DIR/summary.json" <<EOF
{
  "zkvm": "$ZKVM_NAME",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "riscof_commit": "$RISCOF_COMMIT",
  "zkvm_commit": "$ZKVM_COMMIT",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL,
  "pass_rate": $PASS_RATE
}
EOF
    else
        cat > "$RESULTS_DIR/summary.json" <<EOF
{
  "zkvm": "$ZKVM_NAME",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "riscof_commit": "$RISCOF_COMMIT",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL,
  "pass_rate": $PASS_RATE
}
EOF
    fi
    
    echo "Summary saved to $RESULTS_DIR/summary.json"
else
    echo "Error: Test report not generated"
    exit 1
fi

echo "RISCOF tests completed for $ZKVM_NAME"