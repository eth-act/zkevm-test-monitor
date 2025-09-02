# Pico Builder
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    clang-14 \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Install specific Rust version if needed
RUN rustup toolchain install 1.75.0
RUN rustup default 1.75.0

WORKDIR /workspace

# Clone and checkout specific commit
ARG REPO_URL=https://github.com/codygunton/pico
ARG COMMIT_HASH=571dc543c4a73df2c34e86f8e36b529efb1b84b0
RUN git clone "$REPO_URL" pico && \
    cd pico && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Build the ZKVM
WORKDIR /workspace/pico
RUN cargo build --package pico-vm --release --bin pico-riscof

# Runtime stage
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy binary and commit info
COPY --from=builder /workspace/pico/target/release/pico-riscof /usr/local/bin/pico-binary
COPY --from=builder /workspace/commit.txt /commit.txt

# Entrypoint to extract binary
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/pico-binary /output/pico-binary"]