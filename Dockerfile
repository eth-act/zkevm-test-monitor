FROM ubuntu:24.04

# Prevent interactive prompts during apt install
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
  python3 \
  python3-pip \
  python3-venv \
  curl \
  git \
  build-essential \
  zsh \
  vim \
  && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /riscof

# Install Python dependencies globally (since we're in a container)
# Ubuntu 24.04 requires --break-system-packages for global pip installs
RUN pip3 install --break-system-packages riscof==1.25.3

# Create directories for toolchains and emulators
RUN mkdir -p toolchains emulators

# Install generic RISC-V toolchain (riscv32-unknown-elf)
# Using the official RISC-V GNU toolchain releases
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2024.02.02/riscv32-elf-ubuntu-22.04-gcc-nightly-2024.02.02-nightly.tar.gz | tar -xz -C toolchains/ && \
  mv toolchains/riscv toolchains/riscv32

# Install Sail RISC-V simulator (the golden reference model)
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.7/sail_riscv-Linux-x86_64.tar.gz | tar -xz -C emulators/ && \
  mv emulators/sail_riscv-Linux-x86_64 emulators/sail-riscv

# Clone architectural tests
RUN riscof arch-test --clone --get-version 3.9.1

# Fix RISCOF bugs in dbgen.py
RUN sed -i 's/if key not in list:/if key not in flist:/' /usr/local/lib/python3.12/dist-packages/riscof/dbgen.py && \
  sed -i '/def check_commit/,/return str(commit), update/{s/if (str(commit) != old_commit):/update = False\n    if (str(commit) != old_commit):/}' /usr/local/lib/python3.12/dist-packages/riscof/dbgen.py

# Add toolchains and emulators to PATH
ENV PATH="/riscof/toolchains/riscv32/bin:/riscof/emulators/sail-riscv:$PATH"

# Copy the entire project (excluding what's in .dockerignore)
COPY . .

# Create mount points for DUT binary and plugin
RUN mkdir -p /dut/plugin /dut/bin /riscof/riscof_work && touch /dut/plugin/dut-exe

# Default entrypoint will be our dynamic configuration script
ENTRYPOINT ["/riscof/entrypoint.sh"]
