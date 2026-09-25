# Builds eth-act standards guest ELFs and a host executor for SP1.
#
# The vendor C library is SP1's zkEVM SDK (`zkevm/` in succinctlabs/sp1):
# `make sdk` builds libzkevm.a for riscv64im-succinct-zkvm-elf with the
# succinct Rust toolchain. The image also builds sp1-eth-act-standards-executor
# (./executor), which runs a guest in SP1's executor at the same commit.
# The container compiles every guest in /eth-act-standards-tests against libzkevm.a and
# writes the ELFs to /elfs.
#
# The SDK is not in the monitor's pinned SP1 fork (v6.1.0), so this image
# pins upstream tag v6.6.0 (the version eth-act/ere pins, including its
# `libzkevm`) and ignores the COMMIT_HASH build argument.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    clang \
    curl \
    git \
    libssl-dev \
    lld \
    llvm \
    pkg-config \
    protobuf-compiler \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# RUSTUP_TOOLCHAIN overrides SP1's rust-toolchain.toml, which would also pull
# rustc-dev. sp1-build still selects the succinct toolchain for guest code.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain 1.94.0
ENV PATH="/root/.cargo/bin:${PATH}" RUSTUP_TOOLCHAIN=1.94.0 CARGO_NET_GIT_FETCH_WITH_CLI=true

# The succinct toolchain that this SP1 commit expects
# (LATEST_SUPPORTED_TOOLCHAIN_VERSION_TAG in crates/cli/src/lib.rs). This is
# what `cargo prove install-toolchain` installs.
ARG SUCCINCT_TOOLCHAIN=succinct-1.94.0-64bit
RUN mkdir -p /root/.sp1/toolchains/succinct && \
    curl -sSfL "https://github.com/succinctlabs/rust/releases/download/${SUCCINCT_TOOLCHAIN}/rust-toolchain-x86_64-unknown-linux-gnu.tar.gz" | \
    tar -xz -C /root/.sp1/toolchains/succinct && \
    rustup toolchain link succinct /root/.sp1/toolchains/succinct

ARG REPO_URL=https://github.com/succinctlabs/sp1.git
ARG SP1_COMMIT=f5a5bbf6a1cf6007315b410d88678d96fb399fb5
RUN git init /sp1 && cd /sp1 && \
    git remote add origin "$REPO_URL" && \
    git fetch --depth 1 origin "$SP1_COMMIT" && \
    git checkout FETCH_HEAD && \
    git rev-parse HEAD > /sp1-commit.txt

WORKDIR /sp1/zkevm
RUN make sdk && \
    mkdir -p /opt/sp1 && \
    cp -r sdk/. /opt/sp1/

COPY executor /executor
RUN cargo build --release --locked --manifest-path /executor/Cargo.toml && \
    cp /executor/target/release/sp1-eth-act-standards-executor /usr/local/bin/ && \
    rm -rf /executor/target

WORKDIR /
ENTRYPOINT ["/bin/bash", "-c", "/eth-act-standards-tests/build-guests.sh sp1 /elfs && cp /sp1-commit.txt /elfs/vendor-commit.txt"]
