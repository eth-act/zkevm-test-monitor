FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies
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

# Install uv (Python package manager used by riscv-arch-test)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Install RISC-V GCC toolchain (same version as other act4 containers)
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && \
    mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"

# Install Sail RISC-V simulator (reference model for generating expected values)
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.10/sail-riscv-Linux-x86_64.tar.gz | \
    tar -xz -C /opt/ && \
    mv /opt/sail-riscv-Linux-x86_64 /opt/sail-riscv
ENV PATH="/opt/sail-riscv/bin:${PATH}"

# Clone riscv-arch-test at the act4 branch
ARG ARCH_TEST_COMMIT=act4
WORKDIR /act4
RUN git clone --branch act4 --single-branch \
        https://github.com/riscv-non-isa/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt

# Initialize the UDB submodule (required for config schema validation during make elfs)
RUN git submodule update --init external/riscv-unified-db

# Pre-generate assembly test sources for I, M, and Misalign extensions.
# Misalign is needed for the RV64IM_Zicclsm target profile.
RUN uv run make tests EXTENSIONS=I,M,Misalign

# Create mount points for DUT binary and results
RUN mkdir -p /dut /results

COPY docker/act4-r0vm/entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
