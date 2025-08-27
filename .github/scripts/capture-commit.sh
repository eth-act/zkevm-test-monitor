#!/bin/bash
# Capture the actual commit SHA for a ZKVM during build
# Usage: capture-commit.sh <zkvm-name> <source-dir> <output-file>

set -euo pipefail

ZKVM_NAME="${1:-}"
SOURCE_DIR="${2:-}"
OUTPUT_FILE="${3:-}"

if [ -z "$ZKVM_NAME" ] || [ -z "$SOURCE_DIR" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <zkvm-name> <source-dir> <output-file>"
    exit 1
fi

# Get the actual commit SHA
if [ -d "$SOURCE_DIR/.git" ]; then
    cd "$SOURCE_DIR"
    COMMIT_SHA=$(git rev-parse HEAD | head -c 8)
    BRANCH_NAME=$(git branch --show-current || echo "detached")
    COMMIT_DATE=$(git show -s --format=%ci HEAD)
    
    # Write commit info to file
    cat > "$OUTPUT_FILE" <<EOF
{
  "zkvm": "$ZKVM_NAME",
  "commit": "$COMMIT_SHA",
  "branch": "$BRANCH_NAME",
  "commit_date": "$COMMIT_DATE"
}
EOF
    
    echo "Captured commit info for $ZKVM_NAME: $COMMIT_SHA ($BRANCH_NAME)"
else
    echo "Warning: $SOURCE_DIR is not a git repository"
    echo "{\"zkvm\": \"$ZKVM_NAME\", \"commit\": \"unknown\"}" > "$OUTPUT_FILE"
fi