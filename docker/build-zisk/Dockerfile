FROM ubuntu:24.04 AS builder

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies for zisk as per documentation
# Plus additional C++ headers that might be missing
RUN apt-get update && apt-get install -y \
    xz-utils \
    jq \
    curl \
    build-essential \
    qemu-system \
    libomp-dev \
    libgmp-dev \
    nlohmann-json3-dev \
    protobuf-compiler \
    uuid-dev \
    libgrpc++-dev \
    libsecp256k1-dev \
    libsodium-dev \
    libpqxx-dev \
    nasm \
    libopenmpi-dev \
    openmpi-bin \
    openmpi-common \
    libclang-dev \
    clang \
    git \
    ca-certificates \
    pkg-config \
    cmake \
    g++ \
    gcc \
    libstdc++-14-dev \
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
ENV CC=clang
ENV CXX=clang++
ENV CXXFLAGS="-std=c++17"

# Build arguments for repository and commit
ARG REPO_URL=https://github.com/0xPolygonHermez/zisk.git
ARG COMMIT_HASH=b3ca745b

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" zisk && \
    cd zisk && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Build zisk
# This layer will be cached as long as the source code doesn't change
WORKDIR /workspace/zisk
RUN cargo build --release --bin ziskemu

# Final stage - just the binary
FROM ubuntu:24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libgmp10 \
    libgomp1 \
    libomp5 \
    libclang-cpp18 \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# Copy the built binary from builder stage
COPY --from=builder /workspace/zisk/target/release/ziskemu /usr/local/bin/ziskemu
COPY --from=builder /workspace/commit.txt /commit.txt

# Simple entrypoint to copy the binary out
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/ziskemu /output/ziskemu"]