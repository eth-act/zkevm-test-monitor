FROM ubuntu:24.04 AS builder

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies including Go and libclang
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    golang-go \
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

# Build arguments for repository and commit
ARG REPO_URL=https://github.com/codygunton/sp1
ARG COMMIT_HASH=fc98075a

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" sp1 && \
    cd sp1 && \
    git checkout "$COMMIT_HASH"

# Build SP1
# This layer will be cached as long as the source code doesn't change
WORKDIR /workspace/sp1
RUN cargo build --bin sp1-perf-executor

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /workspace/sp1/target/debug/sp1-perf-executor /usr/local/bin/sp1-perf-executor

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/sp1-perf-executor /output/sp1-perf-executor"]