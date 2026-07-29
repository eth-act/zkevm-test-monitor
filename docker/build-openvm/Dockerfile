# OpenVM GPU prover build.
#
# Builds the standalone `openvm-binary` (execute/prove/verify) against the OpenVM SDK
# pinned in openvm-elf-runner/Cargo.toml, with the `cuda` feature always on — so the
# proof/verify path runs on the GPU. The SDK's GPU backend (openvm-cuda-backend)
# compiles .cu kernels with nvcc at build time, so the builder needs the full CUDA
# toolkit. CUDA 12.9 matches OpenVM's documented/tested toolkit.
FROM nvidia/cuda:12.9.1-devel-ubuntu24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies. clang/libclang-dev are needed by CUDA-binding build scripts
# (bindgen); cmake is needed by some transitive C/C++ deps.
RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    ca-certificates \
    pkg-config \
    libssl-dev \
    clang \
    libclang-dev \
    cmake \
    && rm -rf /var/lib/apt/lists/*

# Install Rust. OpenVM pins channel 1.91.1 (rust-toolchain.toml); this standalone
# crate lives outside the openvm repo, so pin the same toolchain explicitly.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain 1.91.1 --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

# Put nvcc / CUDA toolkit on PATH for the cuda-backend build scripts.
ENV CUDA_HOME=/usr/local/cuda
ENV PATH="/usr/local/cuda/bin:${PATH}"

WORKDIR /workspace

# Configure git to trust all directories (needed for cargo git dependencies)
RUN git config --global --add safe.directory '*'

ENV RUST_BACKTRACE=1
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV RUST_LOG=info

# Build args. COMMIT_HASH/REPO_URL are accepted for harness uniformity (the real SDK
# pin lives in Cargo.toml/Cargo.lock). CUDA_ARCH is the comma-separated list of compute
# capabilities to compile GPU kernels for (bare numbers, dot stripped — e.g. 120 for an
# RTX 5090 / Blackwell). The openvm-cuda-builder build script reads it from the env.
ARG REPO_URL=https://github.com/openvm-org/openvm
ARG COMMIT_HASH=538c5488130da56c8442d33445efe3c1fe5ea8b8
ARG CUDA_ARCH=120
ENV CUDA_ARCH=${CUDA_ARCH}

# Copy standalone runner source (Cargo.toml + Cargo.lock pin the SDK + stark-backend).
COPY docker/build-openvm/openvm-elf-runner/ /workspace/openvm-elf-runner/

WORKDIR /workspace/openvm-elf-runner
RUN echo "${COMMIT_HASH}" | head -c 8 > /workspace/commit.txt
# --locked: use the committed Cargo.lock exactly (pins stark-backend to openvm's rev).
RUN cargo build --release --locked

# Stage the binary plus the CUDA shared libs it links, so the host (which may ship a
# different CUDA toolkit) can run it. The host driver's libcuda.so is used at runtime;
# these runtime libs are bundled as a version-matched fallback (see test.sh).
RUN mkdir -p /workspace/output/lib && \
    cp target/release/openvm-binary /workspace/output/ && \
    for lib in libcudart libcublasLt libcublas; do \
      path=$(ldd target/release/openvm-binary | grep "$lib" | grep -oP '/\S+\.so\S*' | head -1); \
      [ -n "$path" ] && cp -n "$path" /workspace/output/lib/ || true; \
    done

# Final stage — runtime image carrying the binary and its bundled CUDA libs.
FROM nvidia/cuda:12.9.1-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /workspace/output/openvm-binary /usr/local/bin/openvm-binary
COPY --from=builder /workspace/output/lib/ /usr/local/bin/lib/
COPY --from=builder /workspace/commit.txt /commit.txt

# Entrypoint copies the binary and bundled libs to the mounted /output directory.
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/openvm-binary /output/openvm-binary && \
  mkdir -p /output/lib && cp -r /usr/local/bin/lib/. /output/lib/ 2>/dev/null || true; true"]
