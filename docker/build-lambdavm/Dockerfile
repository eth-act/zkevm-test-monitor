FROM ubuntu:24.04 AS builder

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies. build-essential provides the C toolchain that
# the jemalloc-sys build script (a transitive dependency of the cli) needs.
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust. LambdaVM pins its toolchain in rust-toolchain.toml, which
# rustup honours automatically on first build inside the repo.
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

# Build arguments for repository and commit
ARG REPO_URL=https://github.com/yetanotherco/lambda_vm
ARG COMMIT_HASH=main

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" lambda_vm && \
    cd lambda_vm && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD | head -c8 > /commit.txt

# Build the LambdaVM cli (execute / prove / verify).
WORKDIR /workspace/lambda_vm
RUN cargo build --release -p cli

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built cli, renamed to the harness-expected binary name.
COPY --from=builder /workspace/lambda_vm/target/release/cli /usr/local/bin/lambdavm-binary
COPY --from=builder /commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/lambdavm-binary /output/lambdavm-binary"]
