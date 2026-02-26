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

# Pre-generate assembly test sources for all extensions Zisk supports.
# Matches RISCOF ISA declaration: RV64IMAFDCZicsr.
# ACT4 uses fine-grained extension names: Zaamo/Zalrsc (A), Zca/Zcf/Zcd (C).
# Misalign is needed for the RV64IM_Zicclsm target profile.
# MisalignF/MisalignD/MisalignZca are needed for the RVI20-scoped run.
RUN uv run make tests EXTENSIONS=I,M,F,D,Zca,Zcf,Zcd,Zaamo,Zalrsc,Misalign,MisalignF,MisalignD,MisalignZca

# Create mount points for DUT binary and results
RUN mkdir -p /dut /results

COPY docker/shared/patch_elfs.py /act4/patch_elfs.py
COPY docker/act4-zisk/entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
