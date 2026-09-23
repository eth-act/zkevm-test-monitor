# Builds act-extra guest ELFs and a host executor for ZisK.
#
# The image compiles the vendor C library (ziskos-staticlib) for the standard
# target riscv64im-unknown-none-elf, and ziskemu (execute only: no float
# feature, no GPU, no proving keys) at the same commit. The container then
# compiles every guest in /extra-tests against the library and writes the ELFs
# to /elfs.
#
# The image pins v1.3.0-alpha, the ZisK version that eth-act/ere pins
# (`ziskos = "1.3.0-alpha"`), and ignores the COMMIT_HASH build argument (the
# monitor's ISA pin). The crates.io ziskos 1.3.0-alpha was published from
# a07f4464, an ancestor of the tag that differs from it only in CI files and
# zisk-contracts.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    gcc-riscv64-unknown-elf \
    git \
    libclang-dev \
    libgmp-dev \
    libomp-dev \
    libopenmpi-dev \
    libsodium-dev \
    libssl-dev \
    libstdc++-14-dev \
    nasm \
    nlohmann-json3-dev \
    pkg-config \
    protobuf-compiler \
    python3 \
    uuid-dev \
    && rm -rf /var/lib/apt/lists/*

# ziskos uses nightly-only features (core_intrinsics) and the target needs
# build-std. ziskemu builds with stable, as ZisK's rust-toolchain.toml pins.
ARG RUST_TOOLCHAIN=nightly-2026-09-10
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN" --component rust-src && \
    /root/.cargo/bin/rustup toolchain install stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}" CARGO_NET_GIT_FETCH_WITH_CLI=true

ARG REPO_URL=https://github.com/0xPolygonHermez/zisk.git
ARG ZISK_COMMIT=02d2ae7b711454ce4574d852f8bfbddbfcbb1d67
RUN git init /zisk && cd /zisk && \
    git remote add origin "$REPO_URL" && \
    git fetch --depth 1 origin "$ZISK_COMMIT" && \
    git checkout FETCH_HEAD && \
    git rev-parse HEAD > /zisk-commit.txt

WORKDIR /zisk
# RUSTUP_TOOLCHAIN overrides the stable pin in ZisK's rust-toolchain.toml.
RUN RUSTUP_TOOLCHAIN="$RUST_TOOLCHAIN" cargo build -p ziskos-staticlib --release \
      --target riscv64im-unknown-none-elf -Zbuild-std=core,alloc && \
    mkdir -p /opt/zisk/lib && \
    cp target/riscv64im-unknown-none-elf/release/libziskos_staticlib.a /opt/zisk/lib/

# Stage ziskemu with the shared libraries that differ between Ubuntu and the
# host distribution, like docker/build-zisk does.
RUN CC=clang CXX=clang++ cargo build --release -p ziskemu --bin ziskemu && \
    cp target/release/ziskemu /usr/local/bin/ && \
    mkdir -p /usr/local/lib/ziskemu && \
    for lib in libsodium libomp; do \
      path=$(ldd target/release/ziskemu | grep "$lib" | grep -oP '/\S+\.so\S*' || true); \
      if [ -n "$path" ]; then cp "$path" /usr/local/lib/ziskemu/; fi; \
    done && \
    rm -rf target

WORKDIR /
ENTRYPOINT ["/bin/bash", "-c", "/extra-tests/build.sh zisk /elfs && cp /zisk-commit.txt /elfs/vendor-commit.txt"]
