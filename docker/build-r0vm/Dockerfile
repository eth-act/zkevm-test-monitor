FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl \
    build-essential \
    git \
    git-lfs \
    ca-certificates \
    pkg-config \
    libssl-dev \
    clang \
    libclang-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /workspace

RUN git config --global --add safe.directory '*'

ENV RUST_BACKTRACE=1
ENV CARGO_NET_GIT_FETCH_WITH_CLI=true
ENV RUST_LOG=info
ENV CARGO_INCREMENTAL=1

# Clone from our fork which has --test-elf and --execute-only built in.
ARG REPO_URL=https://github.com/codygunton/risc0
ARG COMMIT_HASH=act4
ADD https://api.github.com/repos/codygunton/risc0/git/refs/heads/act4 /tmp/version.json
RUN git lfs install && \
    git clone "$REPO_URL" r0vm && \
    cd r0vm && \
    git checkout "$COMMIT_HASH" && \
    git lfs pull && \
    git rev-parse HEAD > /workspace/commit.txt

WORKDIR /workspace/r0vm
RUN --mount=type=cache,id=r0vm-rustup,target=/root/.rustup \
    rustup show

WORKDIR /workspace/r0vm
RUN --mount=type=cache,id=r0vm-cargo-registry,target=/root/.cargo/registry \
    --mount=type=cache,id=r0vm-cargo-git,target=/root/.cargo/git \
    --mount=type=cache,id=r0vm-rustup,target=/root/.rustup \
    --mount=type=cache,id=r0vm-target,target=/workspace/r0vm/target \
    cargo build --release -p risc0-r0vm --bin r0vm && \
    cp target/release/r0vm /tmp/r0vm-binary

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    libssl3 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/r0vm-binary /usr/local/bin/r0vm-binary
COPY --from=builder /workspace/commit.txt /commit.txt

ENTRYPOINT ["sh", "-c", "cp /usr/local/bin/r0vm-binary /output/r0vm-binary"]
