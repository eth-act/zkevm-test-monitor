#!/bin/bash
# Drop the most recent run entry from both history files for a ZKVM.
# Usage: ZKVM=zisk ./drop-last-run.sh
set -eu

ZKVM="${ZKVM:?Set ZKVM=<name> (e.g. zisk, sp1, jolt, ...)}"

for SUITE in full standard; do
  FILE="data/history/${ZKVM}-act4-${SUITE}.json"
  if [ ! -f "$FILE" ]; then
    echo "skip: $FILE not found"
    continue
  fi
  N=$(jq '.runs | length' "$FILE")
  if [ "$N" -eq 0 ]; then
    echo "skip: $FILE has no runs"
    continue
  fi
  LAST=$(jq -r '.runs[-1].date' "$FILE")
  jq '.runs |= .[:-1]' "$FILE" | sponge "$FILE"
  echo "dropped run $N (date: $LAST) from $FILE — $(jq '.runs | length' "$FILE") remaining"
done
