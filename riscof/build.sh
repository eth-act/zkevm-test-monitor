#!/bin/bash
# Build RISCOF container with git commit tracking

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get the current git commit hash of the riscof directory
RISCOF_COMMIT=$(cd "$SCRIPT_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo "Building RISCOF container..."
echo "Git commit: ${RISCOF_COMMIT}"
echo "Build directory: ${SCRIPT_DIR}"

# Build with commit hash as build argument
docker build \
  --build-arg RISCOF_COMMIT="${RISCOF_COMMIT}" \
  -t "riscof:${RISCOF_COMMIT}" \
  -t "riscof:latest" \
  "$SCRIPT_DIR"

echo "Successfully built and tagged:"
echo "  - riscof:${RISCOF_COMMIT}"
echo "  - riscof:latest"
echo ""
echo "Query version at runtime with:"
echo "  docker run --rm riscof:latest sh -c 'echo \$RISCOF_COMMIT'"
echo "  docker run --rm riscof:latest cat /riscof/VERSION.json"