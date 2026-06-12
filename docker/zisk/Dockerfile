FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies + Zisk runtime libraries
# The zisk-binary (ziskemu) links against libsodium, libgmp, libomp, libopenmpi.
# These must be present at runtime for the mounted binary to execute.
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
    libsodium23 \
    libgmp10 \
    libomp5 \
    libopenmpi3 \
    && rm -rf /var/lib/apt/lists/*

# Install uv (Python package manager used by riscv-arch-test)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Install RISC-V GCC toolchain (same version as riscof container)
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && \
    mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"

# Install Sail RISC-V simulator (reference model for generating expected values)
# Version 0.10+ provides sail_riscv_sim binary expected by ACT4 framework
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.10/sail-riscv-Linux-x86_64.tar.gz | \
    tar -xz -C /opt/ && \
    mv /opt/sail-riscv-Linux-x86_64 /opt/sail-riscv
ENV PATH="/opt/sail-riscv/bin:${PATH}"

# Clone riscv-arch-test at the 4.0.0 release tag.
# The ARCH_TEST_COMMIT build arg pins to the exact release commit for reproducibility.
ARG ARCH_TEST_COMMIT=a7c99303516f4e668f7488f172043392e23b9dfd
WORKDIR /act4
RUN git clone --branch 4.0.0 --single-branch \
        https://github.com/riscv/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt

# Patch rvtest_setup.h (renamed from test_setup.h in 4.0.0): remove .option rvc.
RUN python3 -c "s=open('tests/env/rvtest_setup.h').read();n=s.replace('  .option rvc\n  .align UNROLLSZ\n  .option norvc','  .option norvc\n  .align UNROLLSZ');assert n!=s,'patch did not match';open('tests/env/rvtest_setup.h','w').write(n);print('Patched rvtest_setup.h')"

# 4.0.0: test sources are pre-generated and checked in — no make tests step needed.
# UDB submodule removed in 4.0.0 — no submodule init needed.

# Create mount points for DUT binary and results
RUN mkdir -p /dut /results

COPY docker/shared/patch_elfs.py /act4/patch_elfs.py
COPY docker/zisk/entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
