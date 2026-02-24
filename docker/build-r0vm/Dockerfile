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
ARG REPO_URL=https://github.com/risc0/risc0
ARG COMMIT_HASH=main
# Force Docker to check if the remote has changed
ADD https://api.github.com/repos/risc0/risc0/git/refs/heads/$COMMIT_HASH /tmp/version.json
RUN git clone "$REPO_URL" r0vm && \
    cd r0vm && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Pre-install the Rust toolchain specified by r0vm
# This reads rust-toolchain.toml and installs the exact version needed
WORKDIR /workspace/r0vm
RUN --mount=type=cache,target=/root/.rustup \
    rustup show

# Apply --execute-only patch: skip ZK proving and exit with guest exit code.
# This minimal patch is required for ACT4 compliance test integration.
WORKDIR /workspace/r0vm
RUN python3 - << 'EOF'
import re

path = "risc0/r0vm/src/lib.rs"
src = open(path).read()

# 1. Add ExitCode to the risc0_zkvm import
src = src.replace(
    "    ApiServer, ExecutorEnv, ExecutorImpl, ProverOpts, ProverServer, VerifierContext,",
    "    ApiServer, ExecutorEnv, ExecutorImpl, ExitCode, ProverOpts, ProverServer, VerifierContext,"
)

# 2. Add execute_only field to Cli struct (after signatures field)
src = src.replace(
    "    /// Test signatures output file.\n    #[arg(long)]\n    signatures: Option<PathBuf>,\n}",
    "    /// Test signatures output file.\n    #[arg(long)]\n    signatures: Option<PathBuf>,\n\n    /// Execute without proving; exit with guest exit code (0=pass, 1=fail, 2=timeout).\n    /// Intended for compliance test runners that check the process exit code.\n    #[arg(long)]\n    execute_only: bool,\n}"
)

# 3. Insert early exit after session binding
src = src.replace(
    "    };\n\n    let prover = args.get_prover();",
    "    };\n\n    if args.execute_only {\n        let code = match session.exit_code {\n            ExitCode::Halted(code) => code as i32,\n            ExitCode::SessionLimit => 2,\n            _ => 1,\n        };\n        std::process::exit(code);\n    }\n\n    let prover = args.get_prover();"
)

open(path, "w").write(src)
print("Patch applied successfully")
EOF

# Build r0vm in release mode
# Use BuildKit cache mounts to preserve ALL cargo caches:
# - /root/.cargo/registry: Package registry index and .crate files
# - /root/.cargo/git: Git dependencies
# - /root/.rustup: Rust toolchains (to avoid re-downloading)
# - target: Build artifacts
WORKDIR /workspace/r0vm
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/root/.rustup \
    --mount=type=cache,target=/workspace/r0vm/target \
    cargo build --release -p risc0-r0vm --bin r0vm && \
    cp target/release/r0vm /tmp/r0vm-binary

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /tmp/r0vm-binary /usr/local/bin/r0vm-binary
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/r0vm-binary /output/r0vm-binary"]