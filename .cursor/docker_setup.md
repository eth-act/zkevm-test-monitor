# Docker Setup and Configuration

## Overview

The ZKEVM Test Monitor is packaged as a Docker container for consistent, reproducible testing across different environments. The container includes all necessary dependencies, toolchains, and the RISCOF framework.

## Dockerfile Analysis

### Base Image
- **OS**: Ubuntu 24.04 LTS
- **Rationale**: Stable base with modern package versions
- **Architecture**: x86_64 (amd64)

### System Dependencies
```dockerfile
RUN apt-get update && apt-get install -y \
  python3 \           # Runtime for RISCOF framework
  python3-pip \       # Package manager for Python dependencies
  python3-venv \      # Virtual environment support
  curl \              # Download toolchains and binaries
  git \               # Version control for test suite
  build-essential \   # Compilation tools (gcc, make, etc.)
  zsh \               # Alternative shell
  vim \               # Text editor
  && rm -rf /var/lib/apt/lists/*
```

## Toolchain Installation

### RISC-V Cross-Compilation Toolchain
- **Version**: 2024.02.02 nightly
- **Target**: riscv32-unknown-elf
- **Source**: Official RISC-V GNU toolchain releases
- **Location**: `/riscof/toolchains/riscv32/`

```dockerfile
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2024.02.02/riscv32-elf-ubuntu-22.04-gcc-nightly-2024.02.02-nightly.tar.gz | tar -xz -C toolchains/ && \
  mv toolchains/riscv toolchains/riscv32
```

### Reference Model Installation
- **Simulator**: Sail RISC-V formal specification model
- **Version**: 0.7
- **Purpose**: Golden reference for differential testing
- **Location**: `/riscof/emulators/sail-riscv/`

```dockerfile
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.7/sail_riscv-Linux-x86_64.tar.gz | tar -xz -C emulators/ && \
  mv emulators/sail_riscv-Linux-x86_64 emulators/sail-riscv
```

## RISCOF Framework Setup

### Installation
- **Framework**: RISCOF 1.25.3
- **Installation Method**: pip3 with `--break-system-packages`
- **Rationale**: Ubuntu 24.04 requires explicit override for global installs

```dockerfile
RUN pip3 install --break-system-packages riscof==1.25.3
```

### Test Suite Integration
- **Test Suite**: RISC-V Architectural Tests
- **Version**: 3.9.1
- **Command**: `riscof arch-test --clone --get-version 3.9.1`

### Bug Fixes
The Dockerfile includes fixes for known RISCOF issues:
```dockerfile
RUN sed -i 's/if key not in list:/if key not in flist:/' /usr/local/lib/python3.12/dist-packages/riscof/dbgen.py && \
  sed -i '/def check_commit/,/return str(commit), update/{s/if (str(commit) != old_commit):/update = False\n    if (str(commit) != old_commit):/}' /usr/local/lib/python3.12/dist-packages/riscof/dbgen.py
```

## Container Structure

### Working Directory
- **Path**: `/riscof`
- **Purpose**: Central location for all framework components

### Directory Layout
```
/riscof/
├── toolchains/         # Cross-compilation toolchains
│   └── riscv32/       # RISC-V 32-bit toolchain
├── emulators/         # Reference model binaries
│   └── sail-riscv/    # Sail RISC-V simulator
├── riscv-arch-test/   # Official test suite
├── plugins/           # ZKVM plugin implementations
└── riscof_work/       # Test execution workspace
```

### Mount Points
```dockerfile
RUN mkdir -p /dut/plugin /dut/bin /riscof/riscof_work
```

- **`/dut/bin`**: ZKVM executable mount point
- **`/dut/plugin`**: Plugin configuration mount point
- **`/riscof/riscof_work`**: Test results output mount point

## Environment Configuration

### PATH Setup
```dockerfile
ENV PATH="/riscof/toolchains/riscv32/bin:/riscof/emulators/sail-riscv:$PATH"
```

Ensures toolchain and reference model binaries are available system-wide.

### Python Environment
- **Interpreter**: Python 3.12 (Ubuntu 24.04 default)
- **Packages**: Global installation due to container isolation
- **Dependencies**: RISCOF and its requirements

## Build Process

### Build Command
```bash
docker build -t riscof:latest .
```

### Build Context
- **Source**: Current directory (project root)
- **Exclusions**: Defined in `.dockerignore` (if present)
- **Layer Optimization**: Commands grouped for efficient caching

## Runtime Configuration

### Volume Mounts
Required volume mounts for operation:
```bash
docker run --rm \
    -v "$PWD/plugins/<emulator-name>:/dut/plugin" \
    -v "<path-to-emulator-binary>:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest
```

### Entry Point
- **Script**: `/riscof/entrypoint.sh`
- **Purpose**: Dynamic configuration and test execution
- **Behavior**: Auto-detects ZKVM type and configures environment

## Container Security

### Isolation Features
- **Network**: No external network access required during testing
- **Filesystem**: Read-only access to system files
- **User**: Runs as root within container (isolated from host)

### Resource Management
- **Memory**: No explicit limits (configurable at runtime)
- **CPU**: Utilizes available cores via job parallelization
- **Storage**: Temporary files in container, results via volume mounts

## Development and Debugging

### Interactive Mode
```bash
docker run -it --rm \
    -v "$PWD/plugins/<emulator-name>:/dut/plugin" \
    -v "<path-to-emulator-binary>:/dut/bin" \
    -v "$PWD/results:/riscof/riscof_work" \
    riscof:latest /bin/bash
```

### Debugging Tools
- **Shell**: zsh and bash available
- **Editor**: vim installed for file editing
- **Build Tools**: Full build-essential package

### Log Access
- **Container Logs**: Standard Docker logging
- **Test Logs**: Available in mounted results directory
- **Debug Output**: Captured in individual test directories

## Optimization Considerations

### Image Size
- **Base**: Ubuntu 24.04 (~70MB)
- **Dependencies**: Additional ~500MB for toolchains
- **Total**: Approximately 600-700MB final image

### Build Performance
- **Layer Caching**: Optimized layer ordering for cache efficiency
- **Parallel Downloads**: curl and tar operations
- **Cleanup**: Package cache removal to reduce size

### Runtime Performance
- **Parallel Execution**: Make-based job parallelization
- **Resource Utilization**: Efficient CPU and memory usage
- **I/O Optimization**: Minimal file system operations during testing