# Builds the Pico C library for the eth-act standards tests.
#
# The vendor C library is Pico's own static library: `cargo pico lib` builds
# pico-sdk as libpico_zkvm.a (`_start`, the zkvm_io.h and zkvm_accelerators.h
# functions, memcpy/memset and friends) and writes pico.ld, Pico's linker script,
# next to it (docs/guest-runtime.md in brevis-network/pico). The guests
# themselves are built as ACT4 C tests in the Pico ACT4 image (see
# tests/eth-act-standards/build-guests.sh), which links /opt/pico/libpico_zkvm.a
# with /opt/pico/pico.ld.
#
# The image starts from ere's Pico compiler image of the ere revision that
# src/runner/Cargo.toml pins, so cargo-pico and the `pico` guest toolchain are
# the ones ere builds Pico guests with. It pins Pico v3.1.3, the version ere
# pins. Pico runs only through ere, so the image builds no host executor.
#
# PICO_SOURCE builds pico-sdk from the checkout: without it, `cargo pico lib`
# takes pico-sdk from the git tag of cargo-pico's crate version, and the crates
# at tag v3.1.3 are version 3.1.1, so it would build v3.1.1's pico-sdk.
ARG ERE_COMPILER_IMAGE=ghcr.io/eth-act/ere/ere-compiler-pico:de784c6
FROM ${ERE_COMPILER_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

ARG REPO_URL=https://github.com/brevis-network/pico.git
ARG PICO_COMMIT=08b6cdd858dee5da0366202b516d646a158479e0
RUN git init -q /pico && cd /pico && \
    git remote add origin "$REPO_URL" && \
    git fetch -q --depth 1 origin "$PICO_COMMIT" && \
    git checkout -q FETCH_HEAD && \
    git rev-parse HEAD > /pico-commit.txt

RUN PICO_SOURCE=/pico cargo pico lib --output /opt/pico && \
    rm -rf /root/.pico/lib/target

ENTRYPOINT []
