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

  # Extra build args (e.g. GPU=1 for zisk, NO_CACHE=1 to force full rebuild)
  EXTRA_BUILD_ARGS=""
  if [ "${NO_CACHE:-}" = "1" ]; then
    EXTRA_BUILD_ARGS="--no-cache"
  fi
  if [ "$ZKVM" = "zisk" ] && [ -n "${GPU:-}" ]; then
    # Auto-detect GPU compute capability for CUDA arch (e.g. 12.0 → sm_120)
    CUDA_ARCH="${CUDA_ARCH:-}"
    if [ -z "$CUDA_ARCH" ] && command -v nvidia-smi &>/dev/null; then
      CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
      [ -n "$CAP" ] && CUDA_ARCH="sm_${CAP}"
    fi
    EXTRA_BUILD_ARGS="--build-arg GPU=1"
    if [ -n "$CUDA_ARCH" ]; then
      EXTRA_BUILD_ARGS="$EXTRA_BUILD_ARGS --build-arg CUDA_ARCH=$CUDA_ARCH"
      echo "  GPU build targeting $CUDA_ARCH"
    fi
  fi

  # Docker build using ZKVM-specific Dockerfile
  docker build \
    --build-arg REPO_URL="$REPO_URL" \
    --build-arg COMMIT_HASH="$COMMIT" \
    $EXTRA_BUILD_ARGS \
    --cache-from zkvm-${ZKVM}:latest \
    -f docker/build-${ZKVM}/Dockerfile \
    -t zkvm-${ZKVM}:latest \
    . || {
    echo "  ❌ Docker build failed for $ZKVM"
    continue
  }

  ACTUAL_COMMIT=$(docker run --rm --entrypoint cat zkvm-${ZKVM}:latest /commit.txt 2>/dev/null || echo "$COMMIT")
  echo "  Built from commit: ${ACTUAL_COMMIT:0:8}"

  mkdir -p data/commits
  echo "${ACTUAL_COMMIT:0:8}" > "data/commits/${ZKVM}.txt"

  # Extract binary using docker cp (needed to test CI using act)
  mkdir -p binaries
  BINARY_NAME=$(jq -r ".zkvms.${ZKVM}.binary_name" config.json)

  # Create a temporary container, copy binaries, and clean up
  docker rm -f zkvm-${ZKVM}-build 2>/dev/null || true
  CONTAINER_ID=$(docker create --name zkvm-${ZKVM}-build zkvm-${ZKVM}:latest)

  if [ "$ZKVM" = "jolt" ]; then
    # Jolt produces both jolt-emu (emulator) and jolt-prover (proving CLI)
    docker cp "$CONTAINER_ID:/usr/local/bin/jolt-emu" "binaries/jolt-binary" || {
      echo "  ❌ Failed to extract jolt-emu for $ZKVM"
      docker rm "$CONTAINER_ID" > /dev/null 2>&1
      continue
    }
    docker cp "$CONTAINER_ID:/usr/local/bin/jolt-prover" "binaries/jolt-prover" 2>/dev/null || \
      echo "  Warning: jolt-prover not found (proving will not work)"
    chmod +x binaries/jolt-binary binaries/jolt-prover 2>/dev/null || true
  elif [ "$ZKVM" = "zisk" ]; then
    # Zisk produces multiple artifacts via /output/ entrypoint
    docker cp "$CONTAINER_ID:/usr/local/bin/ziskemu" "binaries/zisk-binary" || {
      echo "  ❌ Failed to extract ziskemu for $ZKVM"
      docker rm "$CONTAINER_ID" > /dev/null 2>&1
      continue
    }
    docker cp "$CONTAINER_ID:/usr/local/bin/cargo-zisk" "binaries/cargo-zisk" || {
      echo "  ❌ Failed to extract cargo-zisk for $ZKVM"
      docker rm "$CONTAINER_ID" > /dev/null 2>&1
      continue
    }
    # Extract witness lib (required for v0.15.0 proving)
    docker cp "$CONTAINER_ID:/usr/local/bin/libzisk_witness.so" "binaries/libzisk_witness.so" 2>/dev/null || true
    # Extract bundled shared libraries for cargo-zisk (libsodium, libomp)
    rm -rf binaries/zisk-lib && mkdir -p binaries/zisk-lib
    docker cp "$CONTAINER_ID:/usr/local/bin/lib/." "binaries/zisk-lib/" 2>/dev/null || true
    # GPU variants (optional — only present if GPU=1 was set during build)
    docker cp "$CONTAINER_ID:/usr/local/bin/cargo-zisk-cuda" "binaries/cargo-zisk-cuda" 2>/dev/null || true
    chmod +x binaries/zisk-binary binaries/cargo-zisk 2>/dev/null || true
    chmod +x binaries/cargo-zisk-cuda 2>/dev/null || true

    # Auto-install proving keys if version changed
    if [ -f "binaries/cargo-zisk" ]; then
      ZISK_VERSION=$(LD_LIBRARY_PATH="$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
        binaries/cargo-zisk --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true)
      if [ -n "$ZISK_VERSION" ]; then
        ZISK_MAJOR_MINOR=$(echo "$ZISK_VERSION" | grep -oP '^\d+\.\d+')
        SETUP_KEY_FILE="zisk-provingkey-${ZISK_MAJOR_MINOR}.0.tar.gz"
        SETUP_URL="https://storage.googleapis.com/zisk-setup/${SETUP_KEY_FILE}"
        MARKER_FILE="$HOME/.zisk/.zisk-setup-version"
        CURRENT_MARKER=$(cat "$MARKER_FILE" 2>/dev/null || true)

        # Track GPU state separately so switching triggers re-setup
        GPU_MARKER_FILE="$HOME/.zisk/.zisk-setup-gpu"
        CURRENT_GPU_MARKER=$(cat "$GPU_MARKER_FILE" 2>/dev/null || true)
        WANT_GPU="${GPU:-0}"

        if [ "$CURRENT_MARKER" != "$ZISK_VERSION" ]; then
          echo "  Installing proving keys for Zisk v${ZISK_VERSION}..."
          echo "  Downloading $SETUP_URL"
          curl -fSL "$SETUP_URL" -o "/tmp/${SETUP_KEY_FILE}" || {
            echo "  Warning: Failed to download proving keys from $SETUP_URL"
            echo "  Proving will not work until keys are installed"
          }
          if [ -f "/tmp/${SETUP_KEY_FILE}" ]; then
            rm -rf "$HOME/.zisk/provingKey" "$HOME/.zisk/cache"
            mkdir -p "$HOME/.zisk"
            tar -xzf "/tmp/${SETUP_KEY_FILE}" -C "$HOME/.zisk/"
            rm -f "/tmp/${SETUP_KEY_FILE}"
            echo "  Running check-setup to generate CPU constant trees..."
            LD_LIBRARY_PATH="$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
              binaries/cargo-zisk check-setup -a || {
              echo "  Warning: check-setup failed — proving may not work"
            }
            # Generate GPU constant trees if GPU binary exists
            if [ -f "binaries/cargo-zisk-cuda" ]; then
              echo "  Running check-setup to generate GPU constant trees..."
              LD_LIBRARY_PATH="$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
                binaries/cargo-zisk-cuda check-setup -a || {
                echo "  Warning: GPU check-setup failed — GPU proving may not work"
              }
              echo "1" > "$GPU_MARKER_FILE"
            else
              echo "0" > "$GPU_MARKER_FILE"
            fi
            echo "$ZISK_VERSION" > "$MARKER_FILE"
            echo "  Proving keys installed for Zisk v${ZISK_VERSION}"
          fi
        # Re-run GPU check-setup if GPU binary was added after initial setup
        elif [ -f "binaries/cargo-zisk-cuda" ] && [ "$CURRENT_GPU_MARKER" != "1" ]; then
          echo "  Generating GPU constant trees for Zisk v${ZISK_VERSION}..."
          LD_LIBRARY_PATH="$PWD/binaries/zisk-lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            binaries/cargo-zisk-cuda check-setup -a || {
            echo "  Warning: GPU check-setup failed — GPU proving may not work"
          }
          echo "1" > "$GPU_MARKER_FILE"
        else
          echo "  Proving keys already installed for Zisk v${ZISK_VERSION}"
        fi
      fi
    fi
  else
    docker cp "$CONTAINER_ID:/usr/local/bin/$BINARY_NAME" "binaries/$BINARY_NAME" || {
      echo "  ❌ Failed to extract binary for $ZKVM"
      docker rm "$CONTAINER_ID" > /dev/null 2>&1
      continue
    }
    chmod +x "binaries/$BINARY_NAME"

    # Handle special cases for binary naming
    if [ "$ZKVM" = "sp1" ] && [ -f "binaries/sp1-perf-executor" ]; then
      mv "binaries/sp1-perf-executor" "binaries/sp1-binary"
    fi
    if [ "$ZKVM" = "r0vm" ] && [ -f "binaries/r0vm-r0vm" ]; then
      mv "binaries/r0vm-r0vm" "binaries/r0vm-binary"
    fi
    if [ "$ZKVM" = "pico" ] && [ -f "binaries/cargo-pico" ]; then
      mv "binaries/cargo-pico" "binaries/pico-binary"
    fi
  fi

  docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
  echo "  ✅ Built ${ZKVM}"
done
