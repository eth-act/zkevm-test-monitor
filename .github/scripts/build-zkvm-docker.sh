#!/bin/bash
# Build script that uses Docker for consistent builds across environments
set -euo pipefail

ZKVM_NAME="$1"
CONFIG_FILE="configs/zkvm-configs/${ZKVM_NAME}.json"

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Parse configuration using jq
REPO_URL=$(jq -r '.repository' "$CONFIG_FILE")
COMMIT_HASH=$(jq -r '.commit' "$CONFIG_FILE")
DOCKER_BUILD=$(jq -r '.build.docker // false' "$CONFIG_FILE")

if [ "$DOCKER_BUILD" != "true" ]; then
    echo "Docker build not enabled for $ZKVM_NAME"
    echo "Falling back to native build script"
    exec .github/scripts/build-zkvm.sh "$ZKVM_NAME"
fi

echo "========================================="
echo "Building $ZKVM_NAME using Docker"
echo "Repository: $REPO_URL"
echo "Commit: $COMMIT_HASH"
echo "========================================="

# Build Docker image with caching
# The image tag includes the commit hash for proper caching
DOCKER_IMAGE="zkvm-build-${ZKVM_NAME}:${COMMIT_HASH}"
DOCKER_DIR="docker/build-${ZKVM_NAME}"

if [ -d "$DOCKER_DIR" ]; then
    echo "Building Docker image for $ZKVM_NAME at commit $COMMIT_HASH..."
    echo "This will use cached layers if the commit hasn't changed."
    
    # Build with build arguments for repository and commit
    # BuildKit disabled for now - enable with DOCKER_BUILDKIT=1 when buildx is installed
    docker build \
        --build-arg REPO_URL="$REPO_URL" \
        --build-arg COMMIT_HASH="$COMMIT_HASH" \
        -t "$DOCKER_IMAGE" \
        "$DOCKER_DIR"
        
    # Also tag as latest for convenience
    docker tag "$DOCKER_IMAGE" "zkvm-build-${ZKVM_NAME}:latest"
else
    echo "Error: Docker build directory not found: $DOCKER_DIR"
    exit 1
fi

# Create output directory
OUTPUT_DIR="$(pwd)/artifacts/binaries"
mkdir -p "$OUTPUT_DIR"

# Extract binary from Docker image
echo "Extracting binary from Docker image..."
docker run --rm \
    -v "$OUTPUT_DIR:/output" \
    "$DOCKER_IMAGE"

# Determine expected binary name based on ZKVM
case "$ZKVM_NAME" in
    sp1)
        EXPECTED_BINARY="sp1-perf-executor"
        ;;
    openvm)
        EXPECTED_BINARY="cargo-openvm"
        ;;
    jolt)
        EXPECTED_BINARY="jolt-emu"
        ;;
    zisk)
        EXPECTED_BINARY="ziskemu"
        ;;
    risc0)
        EXPECTED_BINARY="risc0-r0vm"
        ;;
    *)
        echo "Error: Unknown ZKVM: $ZKVM_NAME"
        exit 1
        ;;
esac

# Rename output binary (force overwrite for CI)
if [ -f "$OUTPUT_DIR/$EXPECTED_BINARY" ]; then
    mv -f "$OUTPUT_DIR/$EXPECTED_BINARY" "$OUTPUT_DIR/${ZKVM_NAME}-binary"
    echo "Binary saved to $OUTPUT_DIR/${ZKVM_NAME}-binary"
else
    echo "Error: Build output not found: $OUTPUT_DIR/$EXPECTED_BINARY"
    exit 1
fi

echo "Build completed for $ZKVM_NAME"