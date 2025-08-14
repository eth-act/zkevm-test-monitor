#!/bin/bash
# Generate static dashboard files for GitHub Pages
set -euo pipefail

DATA_DIR="${1:-data/compliance}"
DOCS_DIR="${2:-docs}"

echo "Generating dashboard from $DATA_DIR to $DOCS_DIR"

# Create docs directories
mkdir -p "$DOCS_DIR/data"
mkdir -p "$DOCS_DIR/assets/css"
mkdir -p "$DOCS_DIR/assets/js"
mkdir -p "$DOCS_DIR/zkvm"

# Copy current data files
cp -r "$DATA_DIR/current" "$DOCS_DIR/data/"
cp -r "$DATA_DIR/history" "$DOCS_DIR/data/" 2>/dev/null || true
cp -r "$DATA_DIR/archives" "$DOCS_DIR/data/" 2>/dev/null || true

# Copy test result reports and style.css
mkdir -p "$DOCS_DIR/reports"

# Copy style.css if it exists in any results directory
for zkvm in sp1 openvm jolt; do
    if [ -f "results/$zkvm/style.css" ]; then
        cp "results/$zkvm/style.css" "$DOCS_DIR/reports/style.css"
        echo "  Copied style.css"
        break
    fi
done

# Copy individual reports
for zkvm in sp1 openvm jolt; do
    if [ -f "results/$zkvm/report.html" ]; then
        echo "  Copying report for $zkvm"
        cp "results/$zkvm/report.html" "$DOCS_DIR/reports/${zkvm}-report.html"
    else
        # Create a placeholder report if no actual report exists
        echo "  No RISCOF report found for $zkvm, creating placeholder"
        cat > "$DOCS_DIR/reports/${zkvm}-report.html" <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>No Report Available - ${zkvm}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        .no-report { color: #666; text-align: center; padding: 50px; }
        .instructions { background: #f0f0f0; padding: 20px; border-radius: 5px; margin-top: 20px; }
        code { background: #e0e0e0; padding: 2px 5px; border-radius: 3px; }
    </style>
</head>
<body>
    <div class="no-report">
        <h1>No RISCOF Report Available for ${zkvm^^}</h1>
        <p>The RISCOF compliance test report has not been generated yet.</p>
        <div class="instructions">
            <h3>To generate this report:</h3>
            <ol>
                <li>Build the ${zkvm} binary: <code>./dashboard.sh build ${zkvm}</code></li>
                <li>Run the tests: <code>./dashboard.sh test ${zkvm}</code></li>
            </ol>
        </div>
    </div>
</body>
</html>
EOF
    fi
done

# Generate timestamp
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Read current status
if [ -f "$DATA_DIR/current/status.json" ]; then
    STATUS=$(cat "$DATA_DIR/current/status.json")
else
    STATUS='{"zkvms": {}, "last_updated": null}'
fi

# Generate ZKVM pages
echo "$STATUS" | jq -r '.zkvms | keys[]' | while read -r ZKVM; do
    echo "Generating page for $ZKVM..."
    
    # Get ZKVM data
    ZKVM_DATA=$(echo "$STATUS" | jq -r ".zkvms.\"$ZKVM\"")
    
    # Create ZKVM detail page
    cat > "$DOCS_DIR/zkvm/${ZKVM}.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${ZKVM} - ZKVM Compliance Dashboard</title>
    <link rel="stylesheet" href="../assets/css/dashboard.css">
</head>
<body>
    <div class="container">
        <header>
            <h1>${ZKVM^^} Details</h1>
            <a href="../index.html" class="back-link">← Back to Dashboard</a>
        </header>
        
        <div class="history-section">
            <h2>Test History</h2>
            <table class="history-table">
                <thead>
                    <tr>
                        <th>Date</th>
                        <th>Commit</th>
                        <th>Results</th>
                        <th>Pass Rate</th>
                    </tr>
                </thead>
                <tbody id="history-tbody-${ZKVM}">
                    <!-- Will be populated by JavaScript -->
                </tbody>
            </table>
        </div>
    </div>
    
    <script src="../assets/js/zkvm-detail.js"></script>
    <script>
        window.zkvmName = '${ZKVM}';
        window.zkvmData = ${ZKVM_DATA};
    </script>
</body>
</html>
EOF
done

echo "Dashboard generation complete"
echo "Files generated in $DOCS_DIR"
echo "Last updated: $TIMESTAMP"