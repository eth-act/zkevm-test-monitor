FROM ubuntu:24.04 AS builder

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
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

# Clone the repository first (this will be cached by commit)
ARG REPO_URL=https://github.com/codygunton/risc0
ARG COMMIT_HASH=fork-riscof
# Force Docker to check if the remote has changed
ADD https://api.github.com/repos/codygunton/risc0/git/refs/heads/$COMMIT_HASH /tmp/version.json
RUN git clone "$REPO_URL" risc0 && \
    cd risc0 && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Pre-install the Rust toolchain specified by risc0
# This reads rust-toolchain.toml and installs the exact version needed
WORKDIR /workspace/risc0
RUN --mount=type=cache,target=/root/.rustup \
    rustup show

# Build RISC0 (debug mode for better error messages)
# Use BuildKit cache mounts to preserve ALL cargo caches:
# - /root/.cargo/registry: Package registry index and .crate files
# - /root/.cargo/git: Git dependencies
# - /root/.rustup: Rust toolchains (to avoid re-downloading)
# - target: Build artifacts
# - ccache: Cache C/C++ compilation (for risc0's heavy C++ components)
WORKDIR /workspace/risc0
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/root/.rustup \
    --mount=type=cache,target=/workspace/risc0/target \
    --mount=type=cache,target=/root/.cache/sccache \
    cargo build -p risc0-r0vm && \
    cp target/debug/r0vm /tmp/r0vm-binary

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage (debug build)
COPY --from=builder /tmp/r0vm-binary /usr/local/bin/risc0-r0vm
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/risc0-r0vm /output/risc0-r0vm"]