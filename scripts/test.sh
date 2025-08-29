#!/bin/bash
set -e

TARGETS="${@:-all}"

# Load config
if [ ! -f config.json ]; then
    echo "❌ config.json not found"
    exit 1
fi

# Setup RISCOF repository
RISCOF_URL=$(jq -r '.riscof.repo_url' config.json)
RISCOF_COMMIT=$(jq -r '.riscof.commit' config.json)

if [ ! -d "riscof" ]; then
    echo "📦 Cloning RISCOF repository..."
    git clone "$RISCOF_URL" riscof || {
        echo "❌ Failed to clone RISCOF repository"
        exit 1
    }
fi

# Update to specified commit
echo "📦 Updating RISCOF to commit $RISCOF_COMMIT..."
cd riscof
git fetch origin
git checkout "$RISCOF_COMMIT" || {
    echo "❌ Failed to checkout RISCOF commit $RISCOF_COMMIT"
    cd ..
    exit 1
}

# Build RISCOF Docker image
echo "🔨 Building RISCOF Docker image..."
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
    chmod +x "binaries/${ZKVM}-binary" 2>/dev/null || true
    
    # Run RISCOF tests (allow non-zero exit for test failures)
    mkdir -p test-results/${ZKVM}
    docker run --rm \
        -v "$PWD/binaries/${ZKVM}-binary:/dut/bin/dut-exe" \
        -v "$PWD/riscof/plugins/${ZKVM}:/dut/plugin" \
        -v "$PWD/test-results/${ZKVM}:/riscof/riscof_work" \
        riscof:latest || true
    
    # Parse test results from HTML report
    if [ -f "test-results/${ZKVM}/report.html" ]; then
        # Extract pass/fail counts from the HTML report
        PASSED=$(grep -oE '<span class="passed">[0-9]+Passed</span>' "test-results/${ZKVM}/report.html" | grep -oE '[0-9]+' | head -1 || echo "0")
        FAILED=$(grep -oE '<span class="failed">[0-9]+Failed</span>' "test-results/${ZKVM}/report.html" | grep -oE '[0-9]+' | head -1 || echo "0")
        
        # If that didn't work, count the actual result rows
        if [ "$PASSED" = "0" ] && [ "$FAILED" = "0" ]; then
            PASSED=$(grep -c '<td class="col-result">Passed</td>' "test-results/${ZKVM}/report.html" 2>/dev/null || echo "0")
            FAILED=$(grep -c '<td class="col-result">Failed</td>' "test-results/${ZKVM}/report.html" 2>/dev/null || echo "0")
        fi
        
        TOTAL=$((PASSED + FAILED))
        
        # Create summary.json for update script
        cat > "test-results/${ZKVM}/summary.json" <<EOF
{
  "zkvm": "${ZKVM}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "passed": $PASSED,
  "failed": $FAILED,
  "total": $TOTAL
}
EOF
        
        echo "  ✅ Tested ${ZKVM}: ${PASSED}/${TOTAL} passed"
    else
        echo "  ⚠️  Tests ran but no report generated"
    fi
done