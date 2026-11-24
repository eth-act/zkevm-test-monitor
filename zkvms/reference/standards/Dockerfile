# Builds the zkVM reference platform for the eth-act standards tests: the Lean
# reference `zkvm-run` from eth-act/zkevm-standards (reference/, at the commit
# config.json pins), a stub static library with every symbol of the reference's
# zkvm_library, and the reference linker script.
#
# The reference performs a library function when the PC reaches its symbol, so
# the stub library only defines the symbols (one `ebreak` each, never executed),
# as reference/tests/run.py does.
#
# Debian trixie: its riscv64-unknown-elf-gcc (14) knows Zicclsm; Ubuntu 24.04's
# (13.2) does not.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    binutils-riscv64-unknown-elf \
    build-essential \
    ca-certificates \
    curl \
    gcc-riscv64-unknown-elf \
    git \
    python3 \
    rsync \
    z3 \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | \
    sh -s -- -y --default-toolchain none
ENV PATH="/root/.elan/bin:${PATH}"

# COMMIT_HASH is the run script's generic argument; the reference is pinned by
# STANDARDS_COMMIT (config.json .zkevm_standards_commit).
ARG STANDARDS_COMMIT
RUN test -n "$STANDARDS_COMMIT" && \
    git clone https://github.com/eth-act/zkevm-standards /src && \
    git -C /src checkout "$STANDARDS_COMMIT" && \
    git -C /src submodule update --init reference/sail-riscv && \
    git -C /src rev-parse HEAD > /reference-commit.txt

RUN /src/reference/scripts/build-lean.sh

# The stub library and the linker script, as reference/tests/run.py builds them
# for the reference-rx profile (text flags 5 = R+X).
RUN mkdir -p /out && cd /out && \
    cp /src/reference/lean/.lake/build/bin/zkvm-run /out/zkvm-run && \
    { printf '  .section .text\n  .balign 4\n'; \
      for s in $(/out/zkvm-run --list-symbols); do printf '\n  .globl %s\n%s:\n  ebreak\n' "$s" "$s"; done; } > stubs.S && \
    riscv64-unknown-elf-gcc -march=rv64im_zicclsm -mabi=lp64 -c stubs.S -o stubs.o && \
    riscv64-unknown-elf-ar rcs libzkvm_reference.a stubs.o && \
    sed -e 's/@TEXT_FLAGS@/5/' -e 's/@RAM_BASE@/0x80000000/' -e 's/@RAM_END@/0x88000000/' \
      /src/reference/tests/stublib/link.ld.in > /out/link.ld && \
    cp /src/reference/memory-profiles/reference-rx.json /out/profile.json
