FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies (build-essential also builds the native UDB gems, e.g. z3)
RUN apt-get update && apt-get install -y \
    curl \
    git \
    make \
    build-essential \
    ca-certificates \
    xz-utils \
    python3 \
    python3-pip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install RISC-V GCC toolchain (GCC 15.1 / binutils 2.45; ACT4 4.1.0 needs
# GCC >= 15 and binutils >= 2.44)
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && \
    mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"

# Install Sail RISC-V simulator (reference model for generating expected values).
# ACT4 4.1.0 requires exactly Sail 0.13.1.
ENV SAIL_VERSION=0.13.1
RUN mkdir -p /opt/sail-riscv && \
    curl -L https://github.com/riscv/sail-riscv/releases/download/${SAIL_VERSION}/sail-riscv-Linux-x86_64.tar.gz | \
    tar -xz -C /opt/sail-riscv --strip-components=1
ENV PATH="/opt/sail-riscv/bin:${PATH}"

# Install mise, which installs the uv, Ruby and Bundler versions pinned in
# riscv-arch-test's .mise.toml (below).
ENV MISE_YES=1
RUN curl -fsSL https://mise.jdx.dev/install.sh | sh
ENV PATH="/root/.local/share/mise/shims:/root/.local/bin:${PATH}"

# Clone riscv-arch-test at the pinned release tag (config.json .act4_version).
# The ARCH_TEST_COMMIT build arg pins to the exact release commit for reproducibility.
ARG ARCH_TEST_VERSION=4.1.0
ARG ARCH_TEST_COMMIT=6e8a45123f14cebfb3df151a0e7b849b4389b33b
WORKDIR /act4
RUN git clone --branch ${ARCH_TEST_VERSION} --single-branch \
        https://github.com/riscv/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt

# ACT4 always runs UDB validation (udb, udb-gen Ruby gems). Install the gems and the
# Python dependencies at image build time, so ELF generation needs no network.
RUN mise install ruby gem:bundler uv && \
    BUNDLE_GEMFILE=/act4/framework/src/act/data/Gemfile bundle install && \
    uv sync

COPY src/shared/patch_elfs.py /act4/patch_elfs.py
COPY zkvms/zisk/isa-tests-entrypoint.sh /act4/isa-tests-entrypoint.sh
RUN chmod +x /act4/isa-tests-entrypoint.sh

ENTRYPOINT ["/act4/isa-tests-entrypoint.sh"]
