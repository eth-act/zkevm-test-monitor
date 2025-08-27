#!/bin/bash
# Manually set commit info for a ZKVM
# Usage: set-commit.sh <zkvm> <commit-sha>
# Example: set-commit.sh openvm a6f77215

set -euo pipefail

ZKVM="${1:-}"
COMMIT="${2:-}"

if [ -z "$ZKVM" ] || [ -z "$COMMIT" ]; then
    echo "Usage: $0 <zkvm> <commit-sha>"
    echo "Example: $0 openvm a6f77215"
    echo ""
    echo "Or to set from config file:"
    echo "$0 openvm \$(jq -r '.commit' configs/zkvm-configs/openvm.json)"
    exit 1
fi

# Create directory if it doesn't exist
mkdir -p artifacts/commit-info

# Save commit info
cat > "artifacts/commit-info/${ZKVM}.json" <<EOF
{
  "commit": "$COMMIT",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "manual"
}
EOF

echo "Set commit for $ZKVM: $COMMIT"
echo "Saved to artifacts/commit-info/${ZKVM}.json"