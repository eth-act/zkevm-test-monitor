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

# Build Docker container from riscof repo
echo "Building Docker container from riscof repo..."
if [ ! -d "riscof" ]; then
    echo "Error: riscof directory/symlink not found"
    echo "Please create a symlink: ln -s /path/to/your/riscof/repo riscof"
    exit 1
fi
cd riscof
docker build -t riscof:latest .
cd ..

# Run RISCOF tests
echo "Running tests..."
docker run --rm \
    -v "$(pwd)/$PLUGIN_DIR:/dut/plugin" \
    -v "$(realpath $BINARY_PATH):/dut/bin/dut-exe" \
    -v "$(pwd)/$RESULTS_DIR:/riscof/riscof_work" \
    riscof:latest

# Check if report was generated
REPORT_FILE="$RESULTS_DIR/report.html"
if [ -f "$REPORT_FILE" ]; then
    echo "Test report generated: $REPORT_FILE"
    
    # Extract test summary
    echo "Extracting test summary..."
    
    # Count pass/fail from the HTML table rows (ensure clean numbers)
    PASSED=$(grep -c '<td>Passed</td>' "$REPORT_FILE" 2>/dev/null | tr -d '\n' || echo "0")
    FAILED=$(grep -c '<td>Failed</td>' "$REPORT_FILE" 2>/dev/null | tr -d '\n' || echo "0")
    
    # If that didn't work, try the summary format
    if [ "$PASSED" = "0" ] && [ "$FAILED" = "0" ]; then
        PASSED=$(grep -oE 'Total Passed:.*[0-9]+' "$REPORT_FILE" | grep -oE '[0-9]+' | tail -1 || echo "0")
        FAILED=$(grep -oE 'Total Failed:.*[0-9]+' "$REPORT_FILE" | grep -oE '[0-9]+' | tail -1 || echo "0")
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
    
    # Save summary to JSON
    cat > "$RESULTS_DIR/summary.json" <<EOF
{
  "zkvm": "$ZKVM_NAME",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL,
  "pass_rate": $PASS_RATE
}
EOF
    
    echo "Summary saved to $RESULTS_DIR/summary.json"
else
    echo "Error: Test report not generated"
    exit 1
fi

echo "RISCOF tests completed for $ZKVM_NAME"