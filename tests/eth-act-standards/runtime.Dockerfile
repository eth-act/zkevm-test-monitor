# Image for the runtime guests of the eth-act standards tests
# (tests/eth-act-standards/build-runtime-guests.sh).
#
# The runtime guests are plain C and C++ programs, not ACT4 tests. They link
# only the vendor's static library, with the vendor's linker script unchanged,
# once with GNU ld and once with LLD: the static library and linker script
# standard requires a script that both linkers accept.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libmpc3 \
    lld \
    python3 \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The RISC-V GNU toolchain of the ACT4 images (zkvms/<zkvm>/act4.Dockerfile):
# GCC 15.1 with g++, and binutils 2.45.
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && \
    mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"

# Check that the C and C++ compilers run and that both linkers are present.
RUN echo 'int main(void) { return 0; }' | riscv64-unknown-elf-gcc -x c -c -o /dev/null - && \
    echo 'struct S { S(); }; S::S() {}' | riscv64-unknown-elf-g++ -x c++ -c -o /dev/null - && \
    riscv64-unknown-elf-ld --version && ld.lld --version
