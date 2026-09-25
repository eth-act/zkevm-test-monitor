# Builds eth-act standards guest ELFs and a host executor for OpenVM.
#
# OpenVM ships no C library for guests (its own C-interface PRs #3075-#3080 were
# closed unmerged). This image therefore uses eth-act/ere's ere-platform-openvm,
# which implements zkvm_accelerators.h on OpenVM's guest libraries, at a fixed
# ere commit. ./vendor wraps it as a static library and adds only the two
# zkvm_io.h functions (see vendor/lib.rs). The library is built the way ere
# compiles OpenVM guests with a stock nightly toolchain
# (crates/compiler/openvm/src/rust_rv64ima.rs): ere's target spec, build-std and
# rustflags, plus one target feature of OpenVM's own target (see below). OpenVM is the version ere pins (tag v2.1.0-preview); the
# COMMIT_HASH build argument is ignored.
#
# The image also builds openvm-eth-act-standards-executor (./executor), which runs a guest
# in OpenVM's SDK executor at the same tag; src/run-eth-act-standards-tests.sh copies it to binaries/.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    cmake \
    curl \
    git \
    libclang-dev \
    libssl-dev \
    lld \
    llvm \
    pkg-config \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Nightly for the guest library (build-std, JSON target spec); OpenVM's pinned
# stable toolchain for the host executor.
ARG GUEST_TOOLCHAIN=nightly-2026-09-10
ARG HOST_TOOLCHAIN=1.91.1
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain "$HOST_TOOLCHAIN" && \
    /root/.cargo/bin/rustup toolchain install "$GUEST_TOOLCHAIN" --profile minimal --component rust-src
ENV PATH="/root/.cargo/bin:${PATH}" CARGO_NET_GIT_FETCH_WITH_CLI=true

ARG ERE_REPO=https://github.com/eth-act/ere.git
ARG ERE_COMMIT=e49696e5e1bfedbfd6a8f4009140b72005ce72e3
RUN git init /ere && cd /ere && \
    git remote add origin "$ERE_REPO" && \
    git fetch --depth 1 origin "$ERE_COMMIT" && \
    git checkout FETCH_HEAD && \
    git rev-parse HEAD > /ere-commit.txt && \
    grep -m1 -o 'openvm\.git?tag=v2\.1\.0-preview#[0-9a-f]*' Cargo.lock | cut -d'#' -f2 > /openvm-commit.txt && \
    test -s /openvm-commit.txt

COPY executor /executor
RUN cargo build --release --locked --manifest-path /executor/Cargo.toml && \
    cp /executor/target/release/openvm-eth-act-standards-executor /usr/local/bin/ && \
    rm -rf /executor/target

# Start from ere's lockfile so the guest crates resolve to the versions ere tests.
# RUSTFLAGS are ere's (rust_rv64ima.rs) plus +unaligned-scalar-mem, which OpenVM's
# own target riscv64im-unknown-openvm-elf enables and openvm-mem relies on: without
# it LLVM lowers openvm-mem's 64-byte block copy to a call to memmove itself, which
# recurses until the stack pointer leaves guest memory.
COPY vendor /vendor
WORKDIR /vendor
RUN cp /ere/Cargo.lock Cargo.lock && \
    RUSTFLAGS='-C passes=lower-atomic -C panic=abort --cfg getrandom_backend="custom" --cfg openvm_intrinsics --check-cfg=cfg(openvm_intrinsics) -C target-feature=+unaligned-scalar-mem' \
    cargo "+$GUEST_TOOLCHAIN" build --release \
      --target /ere/crates/compiler/openvm/src/rust_rv64ima/riscv64ima-unknown-none-elf.json \
      -Zbuild-std=core,alloc,panic_abort -Zbuild-std-features=compiler-builtins-mem -Zjson-target-spec && \
    mkdir -p /opt/openvm/lib && \
    cp target/riscv64ima-unknown-none-elf/release/libere_openvm_c.a /opt/openvm/lib/ && \
    rm -rf target

WORKDIR /
ENTRYPOINT ["/bin/bash", "-c", "/eth-act-standards-tests/build-guests.sh openvm /elfs && cp /ere-commit.txt /elfs/vendor-commit.txt && cp /openvm-commit.txt /elfs/openvm-commit.txt"]
