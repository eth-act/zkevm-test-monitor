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

# Build arguments for repository and commit
ARG REPO_URL=https://github.com/codygunton/zksync-airbender
ARG COMMIT_HASH=riscof-dev

# Clone the repository at the specific commit
RUN git clone "$REPO_URL" airbender && \
    cd airbender && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD | head -c8 > /workspace/commit.txt

# Set working directory to airbender
WORKDIR /workspace/airbender

# Build the CLI binary with optimizations but without GPU support for compatibility
# Use the test-release profile for moderate optimization with faster compilation
# RUST_MIN_STACK is needed to avoid stack overflow during compilation on nightly
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/root/.rustup \
    --mount=type=cache,target=/workspace/airbender/target \
    RUST_MIN_STACK=33554432 cargo build --profile test-release -p cli --no-default-features && \
    cp target/test-release/cli /tmp/airbender-cli-binary

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /tmp/airbender-cli-binary /usr/local/bin/cli
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/cli /output/cli"]