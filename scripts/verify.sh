#!/bin/bash
# Automated regression tests

set -e

echo "🧪 Running verification tests..."

# Test 1: Check config.json validity
echo -n "  Checking config.json validity... "
if [ -f "config.json" ] && python3 -c "import json; json.load(open('config.json'))" 2>/dev/null; then
    echo "✅"
else
    echo "❌ Invalid or missing config.json"
    exit 1
fi

# Test 2: Check data/results.json validity
echo -n "  Checking data/results.json validity... "
if [ -f "data/results.json" ]; then
    if python3 -c "import json; json.load(open('data/results.json'))" 2>/dev/null; then
        echo "✅"
    else
        echo "❌ Invalid JSON in data/results.json"
        exit 1
    fi
else
    echo "⚠️  (not created yet)"
fi

# Test 3: Check HTML generation
echo -n "  Checking HTML files... "
if [ -f "index.html" ] && [ -f "docs/index.html" ]; then
    # Check for critical elements
    if grep -q "ZKVM Compliance Test Monitor" index.html && \
       grep -q "<table>" index.html && \
       grep -q "</table>" index.html; then
        echo "✅"
    else
        echo "❌ HTML missing expected content"
        exit 1
    fi
else
    echo "⚠️  (not generated yet)"
fi

# Test 4: Check if all configured ZKVMs are in results (if results exist)
echo -n "  Checking ZKVM coverage... "
if [ -f "data/results.json" ] && [ -f "config.json" ]; then
    EXPECTED_ZKVMS=$(jq -r '.zkvms | keys[]' config.json | sort)
    ACTUAL_ZKVMS=$(jq -r '.zkvms | keys[]' data/results.json 2>/dev/null | sort)
    
    if [ "$EXPECTED_ZKVMS" = "$ACTUAL_ZKVMS" ]; then
        echo "✅"
    else
        echo "⚠️  Some ZKVMs missing in results"
        echo "    Expected: $(echo $EXPECTED_ZKVMS | tr '\n' ' ')"
        echo "    Got: $(echo $ACTUAL_ZKVMS | tr '\n' ' ')"
    fi
else
    echo "⚠️  (no data yet)"
fi

# Test 5: Check state consistency
echo -n "  Checking state consistency... "
INCONSISTENT=""
if [ -f "data/results.json" ]; then
    for ZKVM in $(jq -r '.zkvms | keys[]' data/results.json 2>/dev/null); do
        BUILD_STATUS=$(jq -r ".zkvms.${ZKVM}.build_status" data/results.json 2>/dev/null)
        HAS_BINARY=$(jq -r ".zkvms.${ZKVM}.has_binary" data/results.json 2>/dev/null)
        
        # Check: if build_status is success, binary should exist
        if [ "$BUILD_STATUS" = "success" ] && [ "$HAS_BINARY" = "true" ]; then
            if [ ! -f "binaries/${ZKVM}-binary" ]; then
                INCONSISTENT="$INCONSISTENT ${ZKVM}(no-binary)"
            fi
        fi
        
        # Check: if has_report is true, report should exist
        HAS_REPORT=$(jq -r ".zkvms.${ZKVM}.has_report" data/results.json 2>/dev/null)
        if [ "$HAS_REPORT" = "true" ]; then
            if [ ! -f "docs/reports/${ZKVM}.html" ]; then
                INCONSISTENT="$INCONSISTENT ${ZKVM}(no-report)"
            fi
        fi
    done
fi

if [ -z "$INCONSISTENT" ]; then
    echo "✅"
else
    echo "⚠️  Inconsistent state:$INCONSISTENT"
fi

# Test 6: Check required directories exist
echo -n "  Checking directory structure... "
MISSING_DIRS=""
for DIR in scripts plugins; do
    if [ ! -d "$DIR" ]; then
        MISSING_DIRS="$MISSING_DIRS $DIR"
    fi
done

if [ -z "$MISSING_DIRS" ]; then
    echo "✅"
else
    echo "❌ Missing directories:$MISSING_DIRS"
    exit 1
fi

# Test 7: Check required scripts are executable
echo -n "  Checking script permissions... "
NON_EXEC=""
for SCRIPT in run scripts/build.sh scripts/test.sh scripts/update.py scripts/verify.sh; do
    if [ -f "$SCRIPT" ]; then
        if [ ! -x "$SCRIPT" ]; then
            NON_EXEC="$NON_EXEC $SCRIPT"
        fi
    fi
done

if [ -z "$NON_EXEC" ]; then
    echo "✅"
else
    echo "❌ Non-executable scripts:$NON_EXEC"
    exit 1
fi

echo ""
echo "✅ All verification tests passed!"