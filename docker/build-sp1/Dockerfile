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

# Build arguments for repository and commit: upstream SP1, no fork.
# act4-runner reads the guest exit code from sp1-perf-executor's "exit code: N"
# line, because the executor itself always exits 0.
ARG REPO_URL=https://github.com/succinctlabs/sp1
ARG COMMIT_HASH=f5a5bbf6a1cf6007315b410d88678d96fb399fb5

# Clone SP1 at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" sp1 && \
    cd sp1 && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD | head -c8 > /workspace/commit.txt

WORKDIR /workspace/sp1

# Stub out test-artifacts so it compiles without the succinct RISC-V toolchain.
# test-artifacts builds guest ELFs that require the succinct toolchain. sp1-perf
# imports a few of its constants (FIBONACCI_ELF etc.), but the binaries we run
# never use them. So the build script becomes a no-op, and every ELF constant
# becomes an empty static ELF.
RUN python3 - << 'EOF'
import re

with open("crates/test-artifacts/build.rs", "w") as f:
    f.write("fn main() {}\n")

path = "crates/test-artifacts/src/lib.rs"
src = open(path).read()
src, n = re.subn(r'include_elf!\("[^"]*"\)', "Elf::Static(&[])", src)
src = src.replace("use sp1_build::{include_elf, Elf};", "use sp1_build::Elf;")
assert n > 0, "no include_elf! calls found"
open(path, "w").write(src)

print(f"test-artifacts stubbed: {n} ELF constants")
EOF

# Build SP1.
#   sp1-perf-executor — MinimalExecutor (execute-only, native suite).
#   sp1-perf          — execute + GPU prove + verify in one process (`--mode cuda`).
#     Its `cuda` feature is a plain client (no CUDA at build time); at runtime it
#     spawns a host-native sp1-gpu-server. `native-gnark` needs Go + protobuf
#     (installed above). Built in release so proving is not debug-slow.
RUN cargo build --release --bin sp1-perf-executor --bin sp1-perf

# Final stage - just the binaries
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binaries from builder stage
COPY --from=builder /workspace/sp1/target/release/sp1-perf-executor /usr/local/bin/sp1-perf-executor
COPY --from=builder /workspace/sp1/target/release/sp1-perf /usr/local/bin/sp1-perf
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binaries out (build.sh uses docker cp from /usr/local/bin)
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/sp1-perf-executor /usr/local/bin/sp1-perf /output/"]
