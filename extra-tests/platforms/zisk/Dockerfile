# Builds act-extra guest ELFs for ZisK.
#
# The image compiles the vendor C library (ziskos-staticlib) at the pinned ZisK
# commit for the standard target riscv64im-unknown-none-elf. The container then
# compiles every guest in /extra-tests against it and writes the ELFs to /elfs.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    curl \
    gcc-riscv64-unknown-elf \
    git \
    libclang-dev \
    pkg-config \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# ziskos uses nightly-only features (core_intrinsics) and the target needs build-std.
ARG RUST_TOOLCHAIN=nightly-2026-09-10
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain "$RUST_TOOLCHAIN" --component rust-src
# RUSTUP_TOOLCHAIN overrides the stable pin in ZisK's rust-toolchain.toml.
ENV PATH="/root/.cargo/bin:${PATH}" RUSTUP_TOOLCHAIN=$RUST_TOOLCHAIN

ARG REPO_URL=https://github.com/0xPolygonHermez/zisk.git
ARG COMMIT_HASH=4b9f758f
RUN git clone "$REPO_URL" /zisk && \
    cd /zisk && \
    git checkout "$COMMIT_HASH" && \
    git rev-parse HEAD > /zisk-commit.txt

WORKDIR /zisk
RUN cargo build -p ziskos-staticlib --release \
      --target riscv64im-unknown-none-elf -Zbuild-std=core,alloc && \
    mkdir -p /opt/zisk/lib && \
    cp target/riscv64im-unknown-none-elf/release/libziskos_staticlib.a /opt/zisk/lib/

WORKDIR /
ENTRYPOINT ["/bin/bash", "-c", "/extra-tests/build.sh zisk /elfs && cp /zisk-commit.txt /elfs/vendor-commit.txt"]
