#!/bin/bash
set -e

ZKVM="${1:-}"

if [ -z "$ZKVM" ]; then
  echo "Usage: $0 <zkvm-name>"
  echo "Example: $0 spike"
  exit 1
fi

echo "Cleaning test results for $ZKVM..."

# Remove test results
if [ -d "test-results/${ZKVM}" ]; then
  echo "  Removing test-results/${ZKVM}/"
  sudo rm -rf "test-results/${ZKVM}"
fi

# Remove history
if [ -f "data/history/${ZKVM}.json" ]; then
  echo "  Removing data/history/${ZKVM}.json"
  rm -f "data/history/${ZKVM}.json"
fi

# Remove suite-specific histories
rm -f data/history/${ZKVM}-*.json

echo "✅ Cleaned test results for $ZKVM"