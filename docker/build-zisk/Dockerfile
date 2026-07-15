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
ARG COMMIT_HASH=4b9f758f
ARG GPU=0
ARG CUDA_ARCH=sm_89

# Clone the repository at the specific commit
# This layer will be cached until COMMIT_HASH changes
RUN git clone "$REPO_URL" zisk && \
    cd zisk && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /workspace/commit.txt

# Build zisk tools: ziskemu (emulator), cargo-zisk (user prover CLI), and
# cargo-zisk-dev (dev CLI). The v1.0.0 CLI split moved `check-setup` (and the
# per-program `setup`) onto the new cargo-zisk-dev binary, so both are needed.
# In v0.17.0+ cargo-zisk is GPU-capable by default (CUDA libs always required at
# runtime) with a `cpu-only` opt-out feature. Older versions used the inverse:
# CPU by default, opt-in `gpu` feature. The zisk-witness crate is also gone in
# v0.17.0 (folded into the main build).
WORKDIR /workspace/zisk
# --features zisk-core/float: v1.0.0 moved RV64 F/D (float) support behind the
# `float` cargo feature on zisk-core (was always-on in v0.18.0's RV64IMFDAC).
# Both the emulator and the prover convert ELF→ZisK ROM via zisk-core's
# riscv2zisk, which panics on any word decoding to an F/D instruction when the
# feature is off — and it decodes data words too, so even I/M-only ELFs trip it.
# zisk-core is a workspace member, so the member/feature form works from the root.
# lib-float's build.rs rebuilds its committed RISC-V float lib (libziskfloat.a /
# ziskfloat.elf) via a *nested* `docker build` whenever a C source looks newer
# than the artifact — which always happens after `git clone` equalizes mtimes,
# and there is no docker daemon inside this build. The committed artifacts are the
# reproducible source of truth (ziskfloat.elf's bytes fix the program vk), so we
# `touch` them newer than the sources to make build.rs skip the rebuild and link
# the committed library directly.
RUN if [ "$GPU" = "1" ]; then export CUDA_ARCH="$CUDA_ARCH"; fi && \
    touch lib-float/c/lib/libziskfloat.a lib-float/c/lib/ziskfloat.elf && \
    cargo build --release --bin ziskemu --bin cargo-zisk --bin cargo-zisk-dev \
      --features zisk-core/float

# Build witness lib if the crate still exists (pre-v0.17.0).
RUN if cargo metadata --no-deps --format-version 1 2>/dev/null | \
      grep -q '"name":"zisk-witness"'; then \
      cargo build --release -p zisk-witness; \
    fi

# Stage all outputs into /workspace/output/ so the final stage can COPY a single dir.
# Bundle the shared libs that differ between Docker (Ubuntu 24.04) and host distros
# (e.g. Arch). cargo-zisk in v0.17.0 always links libcudart/libcublas, so include
# CUDA libs unconditionally — older builds simply won't have them in `ldd` output.
RUN mkdir -p /workspace/output /workspace/output/lib && \
    cp target/release/ziskemu /workspace/output/ && \
    cp target/release/cargo-zisk /workspace/output/ && \
    cp target/release/cargo-zisk-dev /workspace/output/ && \
    if [ -f target/release/libzisk_witness.so ]; then \
      cp target/release/libzisk_witness.so /workspace/output/; \
    else \
      touch /workspace/output/libzisk_witness.none; \
    fi && \
    for lib in libsodium libomp libcudart libcublasLt libcublas; do \
      for bin in target/release/ziskemu target/release/cargo-zisk target/release/cargo-zisk-dev target/release/libzisk_witness.so; do \
        [ -f "$bin" ] || continue; \
        path=$(ldd "$bin" | grep "$lib" | grep -oP '/\S+\.so\S*'); \
        [ -n "$path" ] && cp -n "$path" /workspace/output/lib/; \
      done; \
    done

# GPU variant: in v0.17.0+ cargo-zisk is already GPU-capable, so cargo-zisk-cuda
# is just an alias copy. For older versions we still need the `--features gpu` rebuild.
RUN if [ "$GPU" = "1" ]; then \
      if cargo build --release --bin cargo-zisk --features gpu 2>/dev/null; then \
        cp target/release/cargo-zisk /workspace/output/cargo-zisk-cuda; \
        if [ -f target/release/libzisk_witness.so ]; then \
          cargo build --release -p zisk-witness --features gpu && \
          cp target/release/libzisk_witness.so /workspace/output/libzisk_witness_cuda.so; \
        fi; \
      else \
        cp /workspace/output/cargo-zisk /workspace/output/cargo-zisk-cuda; \
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
ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/ziskemu /usr/local/bin/cargo-zisk /usr/local/bin/cargo-zisk-dev /output/ && \
  cp -r /usr/local/bin/lib /output/lib 2>/dev/null || true && \
  [ -f /usr/local/bin/libzisk_witness.so ] && cp /usr/local/bin/libzisk_witness.so /output/; \
  [ -f /usr/local/bin/cargo-zisk-cuda ] && cp /usr/local/bin/cargo-zisk-cuda /output/; true"]
