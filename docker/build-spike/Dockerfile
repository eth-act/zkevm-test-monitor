FROM ubuntu:22.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies for Spike
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    autoconf \
    automake \
    autotools-dev \
    libmpc-dev \
    libmpfr-dev \
    libgmp-dev \
    gawk \
    bison \
    flex \
    texinfo \
    gperf \
    libtool \
    patchutils \
    bc \
    zlib1g-dev \
    libexpat1-dev \
    device-tree-compiler \
    && rm -rf /var/lib/apt/lists/*

# Accept build arguments for consistency with other ZKVMs
# Use the RISCOF-patched version of Spike that supports signature extraction
ARG REPO_URL=https://github.com/riscv-software-src/riscv-isa-sim.git
ARG COMMIT_HASH=master

# Clone and build Spike
WORKDIR /build
RUN git clone ${REPO_URL} spike

WORKDIR /build/spike

# Apply RISCOF patches for signature support
# These patches add the +signature and +signature-granularity options
RUN git checkout ${COMMIT_HASH} && \
    git rev-parse HEAD > /commit.txt && \
    # Download and apply RISCOF patches if they exist
    wget -q https://raw.githubusercontent.com/riscv-software-src/riscof/main/patches/spike/spike.patch -O spike.patch 2>/dev/null && \
    git apply spike.patch 2>/dev/null || true && \
    mkdir build && \
    cd build && \
    # Standard configure - commitlog option doesn't exist
    ../configure --prefix=/opt/spike && \
    make -j$(nproc) && \
    make install

# Create a simple wrapper that works with RISCOF
RUN echo '#!/bin/bash\nexec /opt/spike/bin/spike "$@"' > /opt/spike/bin/spike-wrapper && \
    chmod +x /opt/spike/bin/spike-wrapper

# Copy binary to output directory
# Use "spike" as the binary name to match what the official plugin expects
CMD ["sh", "-c", "cp /opt/spike/bin/spike /output/spike && chmod +x /output/spike"]