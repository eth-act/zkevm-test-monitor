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

# Clone riscv-arch-test at the act4 branch
# The ARCH_TEST_COMMIT build arg pins to a specific commit for reproducibility.
# Update it when the act4 branch advances.
ARG ARCH_TEST_COMMIT=act4
WORKDIR /act4
RUN git clone --branch act4 --single-branch \
        https://github.com/riscv-non-isa/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt

# Initialize the UDB submodule (required for config schema validation during make elfs)
RUN git submodule update --init external/riscv-unified-db

# Patch test_setup.h: remove .option rvc (sets EF_RISCV_RVC, causes SP1/Pico/OpenVM
# to mishandle ELFs so tests cannot fail). Fix from codygunton/riscv-arch-test@fb327b09.
RUN python3 -c "s=open('tests/env/test_setup.h').read();n=s.replace('  .option rvc\n  .align UNROLLSZ\n  .option norvc','  .option norvc\n  .align UNROLLSZ');assert n!=s,'patch did not match';open('tests/env/test_setup.h','w').write(n);print('Patched test_setup.h')"


# Pre-generate assembly test sources for I, M, and Misalign extensions.
# This is the slow deterministic step; baking it in avoids re-running it on every test run.
# Misalign is needed for the RV64IM_Zicclsm target profile.
RUN uv run make tests EXTENSIONS=I,M,Zaamo,Zalrsc,Zca,Misalign

# Create mount points for DUT binary and results
RUN mkdir -p /dut /results

# Jolt ZeroOS boot code for proving-compatible ELFs.
# boot.bin is the raw .text from a minimal jolt guest (built on host).
# wrap_boot.py appends it to ELFs as a new LOAD segment and sets the entry point.
COPY docker/jolt/boot.bin /act4/boot.bin
COPY docker/jolt/wrap_boot.py /act4/wrap_boot.py

COPY docker/shared/patch_elfs.py /act4/patch_elfs.py
COPY docker/jolt/entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/patch_elfs.py /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
