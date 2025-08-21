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
ARG REPO_URL=https://github.com/codygunton/jolt
ARG COMMIT_HASH=c4b9b060

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" jolt && \
    cd jolt && \
    git checkout "$COMMIT_HASH"

# Build Jolt
# This layer will be cached as long as the source code doesn't change
WORKDIR /workspace/jolt
RUN cargo build --release -p tracer --bin jolt-emu

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /workspace/jolt/target/release/jolt-emu /usr/local/bin/jolt-emu

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/jolt-emu /output/jolt-emu"]