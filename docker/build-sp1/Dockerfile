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
    protobuf-compiler \
    python3 \
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
# Fork rebases upstream v6.1.0 with:
#   1. Remove test-artifacts dep from sp1-perf Cargo.toml
#   2. Propagate MinimalExecutor exit code as non-zero process exit
# Additional Dockerfile patch: stubs out test-artifacts (replaces build.rs + lib.rs with no-ops)
# since cargo compiles all workspace members and test-artifacts requires the succinct toolchain.
ARG REPO_URL=https://github.com/codygunton/sp1
ARG COMMIT_HASH=1099518175f1eb0af3318c5a9be8865da2fc5bd6

# Clone the fork at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" sp1 && \
    cd sp1 && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD | head -c8 > /workspace/commit.txt

WORKDIR /workspace/sp1

# Stub out test-artifacts so it compiles without the succinct RISC-V toolchain.
# test-artifacts builds guest ELFs that require the succinct toolchain; we don't need
# them for sp1-perf-executor, so we replace the build script and library with no-ops.
RUN python3 - << 'EOF'
# No-op build script: skip all guest program compilation
with open("crates/test-artifacts/build.rs", "w") as f:
    f.write("fn main() {}\n")

# Empty library: remove all include_elf! calls that reference non-existent ELF files
with open("crates/test-artifacts/src/lib.rs", "w") as f:
    f.write("// Stubbed: guest ELFs not compiled (succinct toolchain unavailable)\n")

print("test-artifacts stubbed successfully")
EOF

# Build SP1
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
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/sp1-perf-executor /output/sp1-perf-executor"]
