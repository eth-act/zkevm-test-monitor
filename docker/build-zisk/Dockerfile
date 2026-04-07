FROM nvidia/cuda:13.1.1-devel-ubuntu24.04 AS builder

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
    gcc-riscv64-unknown-elf \
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
ARG GPU=0
ARG CUDA_ARCH=sm_89

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" zisk && \
    cd zisk && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Build zisk tools: ziskemu (emulator), cargo-zisk (prover CLI),
# and optionally zisk-witness (witness lib, if it exists at this commit).
WORKDIR /workspace/zisk
RUN cargo build --release --bin ziskemu --bin cargo-zisk

# Build witness lib if the crate exists (added in newer commits)
RUN if cargo metadata --no-deps --format-version 1 2>/dev/null | \
      grep -q '"name":"zisk-witness"'; then \
      cargo build --release -p zisk-witness; \
    fi

# Stage all outputs into /workspace/output/ so the final stage can COPY a single dir.
# Bundle only the specific shared libs that commonly differ between Docker (Ubuntu 24.04)
# and host distros (e.g. Arch). System libs (libc, libm, libstdc++) must match the host.
RUN mkdir -p /workspace/output /workspace/output/lib && \
    cp target/release/ziskemu /workspace/output/ && \
    cp target/release/cargo-zisk /workspace/output/ && \
    if [ -f target/release/libzisk_witness.so ]; then \
      cp target/release/libzisk_witness.so /workspace/output/; \
    else \
      touch /workspace/output/libzisk_witness.none; \
    fi && \
    for lib in libsodium libomp; do \
      for bin in target/release/cargo-zisk target/release/libzisk_witness.so; do \
        [ -f "$bin" ] || continue; \
        path=$(ldd "$bin" | grep "$lib" | grep -oP '/\S+\.so\S*'); \
        [ -n "$path" ] && cp -n "$path" /workspace/output/lib/; \
      done; \
    done

# Build GPU variants if requested (same binaries with --features gpu, renamed).
# Bundle CUDA runtime libs needed by the GPU binary.
# CUDA_ARCH must be set so pil2-proofman's Makefile compiles for the correct GPU.
# The configure.sh script tries to run deviceQuery which requires a GPU in the container;
# setting CUDA_ARCH explicitly bypasses that detection.
RUN if [ "$GPU" = "1" ]; then \
      export CUDA_ARCH="$CUDA_ARCH" && \
      cargo build --release --bin cargo-zisk --features gpu && \
      cp target/release/cargo-zisk /workspace/output/cargo-zisk-cuda && \
      for lib in libcudart libcublasLt libcublas; do \
        path=$(ldd target/release/cargo-zisk | grep "$lib" | grep -oP '/\S+\.so\S*'); \
        [ -n "$path" ] && cp -n "$path" /workspace/output/lib/; \
      done; \
      if [ -f target/release/libzisk_witness.so ]; then \
        cargo build --release -p zisk-witness --features gpu && \
        cp target/release/libzisk_witness.so /workspace/output/libzisk_witness_cuda.so; \
      fi; \
    fi

# Final stage - binaries and libraries
FROM nvidia/cuda:13.1.1-runtime-ubuntu24.04

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libgmp10 \
    libomp5 \
    && rm -rf /var/lib/apt/lists/*

# Copy all built artifacts from staging directory.
# Glob patterns (cargo-zisk*) allow optional GPU variants without failing.
COPY --from=builder /workspace/output/ziskemu /usr/local/bin/
COPY --from=builder /workspace/output/cargo-zisk* /usr/local/bin/
COPY --from=builder /workspace/output/lib/ /usr/local/bin/lib/
# Witness lib is optional (removed in v0.16.0+); placeholder ensures glob never empty.
COPY --from=builder /workspace/output/libzisk_witness* /usr/local/bin/
COPY --from=builder /workspace/commit.txt /commit.txt

# Entrypoint copies all tools to /output/
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/ziskemu /usr/local/bin/cargo-zisk /output/ && \
  cp -r /usr/local/bin/lib /output/lib 2>/dev/null || true && \
  [ -f /usr/local/bin/libzisk_witness.so ] && cp /usr/local/bin/libzisk_witness.so /output/; \
  [ -f /usr/local/bin/cargo-zisk-cuda ] && cp /usr/local/bin/cargo-zisk-cuda /output/; true"]
