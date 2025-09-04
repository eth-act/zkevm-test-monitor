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
  xz-utils \
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

ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
  tar -xJ -C /riscof/toolchains/

# Rename to expected directory name
RUN mv /riscof/toolchains/riscv /riscof/toolchains/riscv64

# Install Sail RISC-V simulator (the golden reference model)
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.7/sail_riscv-Linux-x86_64.tar.gz | tar -xz -C emulators/ && \
  mv emulators/sail_riscv-Linux-x86_64 emulators/sail-riscv

# Clone architectural tests
RUN riscof arch-test --clone --get-version 3.9.1

# Fix RISCOF bugs in dbgen.py
# Note: Python path changes with Ubuntu 22.04 (Python 3.10)
RUN PYTHON_SITE_PACKAGES=$(python3 -c "import site; print(site.getsitepackages()[0])") && \
  sed -i 's/if key not in list:/if key not in flist:/' "$PYTHON_SITE_PACKAGES/riscof/dbgen.py" && \
  sed -i '/def check_commit/,/return str(commit), update/{s/if (str(commit) != old_commit):/update = False\n    if (str(commit) != old_commit):/}' "$PYTHON_SITE_PACKAGES/riscof/dbgen.py"

# Add toolchains and emulators to PATH
ENV PATH="/riscof/toolchains/riscv64/bin:/riscof/emulators/sail-riscv:$PATH"

# Copy the entire project (excluding what's in .dockerignore)
COPY . .

# Create mount points for DUT binary and plugin
RUN mkdir -p /dut/plugin /dut/bin /riscof/riscof_work && touch /dut/plugin/dut-exe

# Accept git commit hash as build argument (passed during docker build)
ARG RISCOF_COMMIT=unknown

# Store commit hash as environment variable for runtime access
ENV RISCOF_COMMIT=${RISCOF_COMMIT}

# Create a VERSION file with all version information
RUN echo "{" > /riscof/VERSION.json && \
    echo "  \"riscof_commit\": \"${RISCOF_COMMIT}\"," >> /riscof/VERSION.json && \
    echo "  \"riscof_version\": \"1.25.3\"," >> /riscof/VERSION.json && \
    echo "  \"toolchain_version\": \"${RISCV_TOOLCHAIN_VERSION}\"," >> /riscof/VERSION.json && \
    echo "  \"toolchain_type\": \"riscv64-elf-ubuntu-24.04\"," >> /riscof/VERSION.json && \
    echo "  \"base_image\": \"ubuntu:24.04\"" >> /riscof/VERSION.json && \
    echo "}" >> /riscof/VERSION.json

# Default entrypoint will be our dynamic configuration script
ENTRYPOINT ["/riscof/entrypoint.sh"]
