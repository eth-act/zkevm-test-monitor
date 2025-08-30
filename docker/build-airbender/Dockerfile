FROM ubuntu:24.04 AS builder

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies including libclang for Airbender's CUDA dependencies
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    clang \
    libclang-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Set working directory
WORKDIR /workspace

# Configure git to trust all directories (needed for cargo git dependencies)
RUN git config --global --add safe.directory '*'

# Set build environment
ENV RUST_BACKTRACE=1
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV RUST_LOG=info
# Enable incremental compilation for faster rebuilds
ENV CARGO_INCREMENTAL=1

# For Airbender, we expect the source to be bind-mounted during build
# The build script will handle this specially
# We'll create a placeholder to be replaced by the bind mount
RUN mkdir -p /workspace/airbender

# Set working directory to airbender
WORKDIR /workspace/airbender

# Capture commit info from the local directory if it's a git repository
# Handle case where it might not be a git repo or might be a symlink
RUN if [ -d .git ]; then \
        git rev-parse HEAD > /workspace/commit.txt 2>/dev/null || echo "local-build-$(date +%Y%m%d-%H%M%S)" > /workspace/commit.txt; \
    else \
        echo "local-build-$(date +%Y%m%d-%H%M%S)" > /workspace/commit.txt; \
    fi

# Build the CLI binary with optimizations but without GPU support for compatibility
# Use the test-release profile for moderate optimization with faster compilation
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/root/.rustup \
    --mount=type=cache,target=/workspace/airbender/target \
    cargo build --profile test-release -p cli && \
    cp target/test-release/cli /tmp/airbender-cli-binary

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /tmp/airbender-cli-binary /usr/local/bin/airbender-binary
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/airbender-binary /output/airbender-binary"]