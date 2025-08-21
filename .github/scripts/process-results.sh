#!/bin/bash
# Process test results and update data files
set -euo pipefail

RESULTS_DIR="${1:-results}"
DATA_DIR="${2:-data/compliance}"
ZKVM_FILTER="${3:-all}"  # Optional: specific ZKVM to process, or "all" for everything

if [ "$ZKVM_FILTER" = "all" ]; then
    echo "Processing all results from $RESULTS_DIR"
else
    echo "Processing results only for $ZKVM_FILTER from $RESULTS_DIR"
fi

# Create data directories
mkdir -p "$DATA_DIR/current"
mkdir -p "$DATA_DIR/history/$(date +%Y-%m)"

# Initialize current status file if it doesn't exist
CURRENT_FILE="$DATA_DIR/current/status.json"
if [ ! -f "$CURRENT_FILE" ]; then
    echo '{"zkvms": {}}' > "$CURRENT_FILE"
fi

# Process each ZKVM's results
for ZKVM_DIR in "$RESULTS_DIR"/*; do
    if [ ! -d "$ZKVM_DIR" ]; then
        continue
    fi
    
    ZKVM_NAME=$(basename "$ZKVM_DIR")
    
    # Skip if we're filtering and this isn't the ZKVM we want
    if [ "$ZKVM_FILTER" != "all" ] && [ "$ZKVM_NAME" != "$ZKVM_FILTER" ]; then
        continue
    fi
    
    SUMMARY_FILE="$ZKVM_DIR/summary.json"
    
    if [ ! -f "$SUMMARY_FILE" ]; then
        echo "Warning: No summary file for $ZKVM_NAME"
        continue
    fi
    
    echo "Processing results for $ZKVM_NAME"
    
    # Read summary data
    SUMMARY=$(cat "$SUMMARY_FILE")
    
    # Update current status (each ZKVM has its own timestamp, no need for global last_updated)
    jq --arg zkvm "$ZKVM_NAME" \
       --argjson summary "$SUMMARY" \
       '.zkvms[$zkvm] = $summary' \
       "$CURRENT_FILE" > "$CURRENT_FILE.tmp"
    mv -f "$CURRENT_FILE.tmp" "$CURRENT_FILE"
    
    # Save to history
    HISTORY_FILE="$DATA_DIR/history/$(date +%Y-%m)/${ZKVM_NAME}-$(date +%Y%m%d-%H%M%S).json"
    cp "$SUMMARY_FILE" "$HISTORY_FILE"
    
    # Archive full report
    ARCHIVE_DIR="$DATA_DIR/archives/$ZKVM_NAME"
    mkdir -p "$ARCHIVE_DIR"
    if [ -f "$ZKVM_DIR/report.html" ]; then
        cp "$ZKVM_DIR/report.html" "$ARCHIVE_DIR/report-$(date +%Y%m%d-%H%M%S).html"
    fi
    
    echo "  - Summary updated in current status"
    echo "  - History saved to $HISTORY_FILE"
    echo "  - Report archived to $ARCHIVE_DIR"
done

# Generate aggregate statistics
echo "Generating aggregate statistics..."
jq '{
    total_zkvms: (.zkvms | length),
    last_updated: .last_updated,
    summary: .zkvms | to_entries | map({
        name: .key,
        passed: .value.passed,
        total: .value.total,
        pass_rate: .value.pass_rate
    })
}' "$CURRENT_FILE" > "$DATA_DIR/current/dashboard.json"

echo "Results processing complete"
echo "Current status: $CURRENT_FILE"
echo "Dashboard data: $DATA_DIR/current/dashboard.json"