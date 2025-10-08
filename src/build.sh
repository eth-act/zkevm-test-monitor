#!/bin/bash
set -e

TARGETS="${@:-all}"

# Load config
if [ ! -f config.json ]; then
  echo "❌ config.json not found"
  exit 1
fi

# Determine which ZKVMs to build
if [ "$TARGETS" = "all" ]; then
  ZKVMS=$(jq -r '.zkvms | keys[]' config.json)
else
  ZKVMS="$TARGETS"
fi

# Build each ZKVM
for ZKVM in $ZKVMS; do
  echo "Building $ZKVM..."

  # Check if already built (unless forced)
  if [ -f "binaries/${ZKVM}-binary" ] && [ "$FORCE" != "1" ]; then
    echo "  ✓ Binary exists (set FORCE=1 to rebuild)"
    continue
  fi

  # Check if Dockerfile exists
  if [ ! -f "docker/build-${ZKVM}/Dockerfile" ]; then
    echo "  ❌ No Dockerfile found for $ZKVM at docker/build-${ZKVM}/Dockerfile"
    continue
  fi

  # Get config for build args
  REPO_URL=$(jq -r ".zkvms.${ZKVM}.repo_url" config.json)
  COMMIT=$(jq -r ".zkvms.${ZKVM}.commit" config.json)

  if [ "$REPO_URL" = "null" ]; then
    echo "  ❌ Unknown ZKVM: $ZKVM"
    continue
  fi

  # Docker build using ZKVM-specific Dockerfile
  docker build \
    --build-arg REPO_URL="$REPO_URL" \
    --build-arg COMMIT_HASH="$COMMIT" \
    --cache-from zkvm-${ZKVM}:latest \
    -f docker/build-${ZKVM}/Dockerfile \
    -t zkvm-${ZKVM}:latest \
    . || {
    echo "  ❌ Docker build failed for $ZKVM"
    continue
  }

  # Capture actual commit hash from the built image
  mkdir -p data/commits
  ACTUAL_COMMIT=$(docker run --rm --entrypoint cat zkvm-${ZKVM}:latest /commit.txt 2> /dev/null || echo "$COMMIT")
  echo "$ACTUAL_COMMIT" > "data/commits/${ZKVM}.txt"
  echo "  📝 Built from commit: ${ACTUAL_COMMIT:0:8}"

  # Extract binary using docker cp (works better in CI/act)
  mkdir -p binaries
  BINARY_NAME=$(jq -r ".zkvms.${ZKVM}.binary_name" config.json)

  # Create a temporary container, copy binary, and clean up
  CONTAINER_ID=$(docker create zkvm-${ZKVM}:latest)
  docker cp "$CONTAINER_ID:/usr/local/bin/$BINARY_NAME" "binaries/$BINARY_NAME" || {
    echo "  ❌ Failed to extract binary for $ZKVM"
    docker rm "$CONTAINER_ID" > /dev/null 2>&1
    continue
  }
  docker rm "$CONTAINER_ID" > /dev/null 2>&1
  chmod +x "binaries/$BINARY_NAME"

  # Handle special cases for binary naming
  if [ "$ZKVM" = "sp1" ] && [ -f "binaries/sp1-perf-executor" ]; then
    mv "binaries/sp1-perf-executor" "binaries/sp1-binary"
  fi
  if [ "$ZKVM" = "r0vm" ] && [ -f "binaries/r0vm-r0vm" ]; then
    mv "binaries/r0vm-r0vm" "binaries/r0vm-binary"
  fi
  if [ "$ZKVM" = "zisk" ] && [ -f "binaries/ziskemu" ]; then
    mv "binaries/ziskemu" "binaries/zisk-binary"
  fi
  if [ "$ZKVM" = "openvm" ] && [ -f "binaries/cargo-openvm" ]; then
    mv "binaries/cargo-openvm" "binaries/openvm-binary"
  fi
  if [ "$ZKVM" = "pico" ] && [ -f "binaries/pico-riscof" ]; then
    mv "binaries/pico-riscof" "binaries/pico-binary"
  fi
  if [ "$ZKVM" = "jolt" ] && [ -f "binaries/jolt-emu" ]; then
    mv "binaries/jolt-emu" "binaries/jolt-binary"
  fi

  echo "  ✅ Built ${ZKVM}"
done

