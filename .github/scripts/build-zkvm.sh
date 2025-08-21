#!/bin/bash
# This is a shell script that runs build commands, not a Rust library
# It simply executes the standard cargo/make commands for each ZKVM
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
BUILD_CMD=$(jq -r '.build.command' "$CONFIG_FILE")
BINARY_PATH=$(jq -r '.build.binary_path' "$CONFIG_FILE")
DEPENDENCIES=$(jq -r '.build.dependencies // ""' "$CONFIG_FILE")

echo "========================================="
echo "Building $ZKVM_NAME"
echo "Repository: $REPO_URL"
echo "Commit: $COMMIT_HASH"
echo "Build Command: $BUILD_CMD"
echo "Binary Path: $BINARY_PATH"
if [ -n "$DEPENDENCIES" ] && [ "$DEPENDENCIES" != "null" ]; then
    echo "Dependencies: $DEPENDENCIES"
fi
echo "========================================="

# Install dependencies if specified and running in CI
if [ -n "$DEPENDENCIES" ] && [ "$DEPENDENCIES" != "null" ]; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "Installing dependencies for $ZKVM_NAME (CI environment)..."
        eval "$DEPENDENCIES"
        echo "Dependencies installed successfully"
    else
        echo "Dependencies required for $ZKVM_NAME:"
        echo "$DEPENDENCIES"
        echo ""
        echo "Note: In local environment, please install dependencies manually or run with sudo"
        echo "Attempting to build without installing dependencies..."
    fi
fi

# Clone or update repository
BUILD_DIR="build-temp-$ZKVM_NAME"
if [ -d "$BUILD_DIR" ]; then
    echo "Repository exists, updating..."
    cd "$BUILD_DIR"
    
    # Check if we're already on the right commit
    CURRENT_COMMIT=$(git rev-parse HEAD)
    if [ "$CURRENT_COMMIT" = "$COMMIT_HASH" ] || [ "${CURRENT_COMMIT:0:8}" = "$COMMIT_HASH" ]; then
        echo "Already on commit $COMMIT_HASH, skipping fetch"
    else
        echo "Fetching updates..."
        git fetch origin
        echo "Checking out commit $COMMIT_HASH..."
        git checkout "$COMMIT_HASH"
    fi
else
    echo "Cloning repository..."
    git clone "$REPO_URL" "$BUILD_DIR"
    cd "$BUILD_DIR"
    echo "Checking out commit $COMMIT_HASH..."
    git checkout "$COMMIT_HASH"
fi

# Check if we need to rebuild
ARTIFACT_BINARY="../artifacts/binaries/${ZKVM_NAME}-binary"
NEEDS_BUILD=true

if [ -f "$ARTIFACT_BINARY" ] && [ -f "$BINARY_PATH" ]; then
    # Check if the artifact is newer than the last git commit
    ARTIFACT_TIME=$(stat -c %Y "$ARTIFACT_BINARY" 2>/dev/null || stat -f %m "$ARTIFACT_BINARY" 2>/dev/null)
    COMMIT_TIME=$(git log -1 --format=%ct)
    
    if [ "$ARTIFACT_TIME" -ge "$COMMIT_TIME" ]; then
        echo "Binary is up-to-date, skipping build"
        NEEDS_BUILD=false
    fi
fi

if [ "$NEEDS_BUILD" = true ]; then
    # Run build command
    echo "Running build command..."
    eval "$BUILD_CMD"
    
    # Verify binary exists
    if [ ! -f "$BINARY_PATH" ]; then
        echo "Error: Binary not found at expected path: $BINARY_PATH"
        exit 1
    fi
    
    echo "Build successful! Binary location: $BINARY_PATH"
    ls -la "$BINARY_PATH"
    
    # Copy binary to artifacts directory
    mkdir -p ../artifacts/binaries
    cp "$BINARY_PATH" "$ARTIFACT_BINARY"
    echo "Binary copied to $ARTIFACT_BINARY"
else
    echo "Using existing binary at $ARTIFACT_BINARY"
fi

cd ..
echo "Build completed for $ZKVM_NAME"