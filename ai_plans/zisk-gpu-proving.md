# Zisk GPU Proving Implementation Plan

## Executive Summary

The zkevm-test-monitor already has all the plumbing for GPU-accelerated Zisk proving — `test.sh` selects GPU binaries, `act4-runner` passes `--preallocate`, `build.sh` passes `GPU=1` to Docker. The only blocker is that the build Dockerfile uses `ubuntu:24.04` which has no CUDA toolkit, so `.cu` files from `pil2-proofman` fail to compile.

**Fix**: Switch the Dockerfile builder stage to `nvidia/cuda:12.6.0-devel-ubuntu24.04` and the final stage to the runtime variant. Bundle CUDA runtime libs alongside the existing libsodium/libomp. Everything else already works.

The test pipeline already supports independent modes: `ZISK_MODE=execute` (CPU emulation only) and `ZISK_MODE=prove`/`full` (proving, optionally with GPU). No changes needed to the test runner.

## Goals & Objectives

### Primary Goals
- GPU-compiled `cargo-zisk-cuda` binary produced by `ZISK_GPU=1 ./run build zisk`
- `ZISK_GPU=1 ./run test zisk` runs proving on GPU via `--preallocate`
- CPU-only execution tests remain unchanged (`ZISK_MODE=execute ./run test zisk`)

### Secondary Objectives
- Proving keys auto-installed (already implemented in build.sh)
- No host CUDA installation required — everything built inside Docker

## Solution Overview

### Approach
Single Dockerfile change: swap base images to NVIDIA CUDA variants. The multi-stage build already separates builder from runtime. GPU build is already behind `ARG GPU=0` conditional.

### Key Components
1. **`docker/build-zisk/Dockerfile`**: Change base images, add CUDA lib bundling
2. **Everything else**: Already done — no changes needed

### Architecture
```
ZISK_GPU=1 ./run build zisk
  └─ build.sh passes --build-arg GPU=1
     └─ Dockerfile
        ├─ Stage 1: nvidia/cuda:12.6.0-devel-ubuntu24.04
        │   ├─ cargo build --release --bin ziskemu --bin cargo-zisk
        │   ├─ cargo build --release -p zisk-witness
        │   └─ [GPU=1] cargo build --release --features gpu → cargo-zisk-cuda
        └─ Stage 2: nvidia/cuda:12.6.0-runtime-ubuntu24.04
            └─ COPY binaries + bundled libs → /output/

ZISK_GPU=1 ./run test zisk
  └─ test.sh selects cargo-zisk-cuda binary
     └─ act4-runner --zkvm zisk-prove --gpu
        ├─ ziskemu --elf <path>           (CPU execution)
        └─ cargo-zisk-cuda prove --preallocate  (GPU proving)
```

### Expected Outcomes
- `binaries/cargo-zisk-cuda` exists after GPU build
- GPU proving produces same pass/fail results as CPU proving, faster
- `ZISK_MODE=execute` unaffected by GPU changes

## Implementation Tasks

### Visual Dependency Tree

```
docker/build-zisk/
└── Dockerfile (Task #0: Switch base images to CUDA, bundle CUDA libs)

src/
├── build.sh   (already done — passes GPU=1, extracts binaries)
└── test.sh    (already done — selects GPU binary, passes --gpu)

act4-runner/src/
├── backends.rs (already done — passes --preallocate when gpu=true)
└── main.rs     (already done — --witness-lib and --gpu CLI args)
```

### Execution Plan

#### Group A: Dockerfile (Single Task)

- [ ] **Task #0**: Switch Dockerfile to CUDA base images and bundle CUDA runtime libs
  - File: `docker/build-zisk/Dockerfile`
  - Changes:
    1. **Line 1**: Change `FROM ubuntu:24.04 AS builder` → `FROM nvidia/cuda:12.6.0-devel-ubuntu24.04 AS builder`
    2. **Line 100**: Change `FROM ubuntu:24.04` → `FROM nvidia/cuda:12.6.0-runtime-ubuntu24.04`
    3. **Remove runtime apt block** (lines 103-109): The CUDA runtime image already includes `libstdc++6` and `libgomp1`. Only need to add `libgmp10` and `libomp5`:
       ```dockerfile
       RUN apt-get update && apt-get install -y \
           libgmp10 \
           libomp5 \
           && rm -rf /var/lib/apt/lists/*
       ```
    4. **Add CUDA runtime lib bundling** to the library copy loop (after existing libsodium/libomp bundling):
       ```dockerfile
       # Bundle CUDA runtime libs for GPU variant (only if GPU build succeeded)
       if [ "$GPU" = "1" ] && [ -f /workspace/output/cargo-zisk-cuda ]; then \
         for lib in libcudart libcublasLt libcublas; do \
           path=$(ldd /workspace/output/cargo-zisk-cuda | grep "$lib" | grep -oP '/\S+\.so\S*'); \
           [ -n "$path" ] && cp -n "$path" /workspace/output/lib/; \
         done; \
       fi
       ```
       Note: Use `ldd` on the actual GPU binary to discover exactly which CUDA libs it needs, rather than guessing. This is the same pattern already used for libsodium/libomp.
  - Verification: `FORCE=1 ZISK_GPU=1 ./run build zisk` should succeed and produce `binaries/cargo-zisk-cuda`
  - Rollback: If CUDA 12.6 doesn't work with proofman v0.15.0, try 12.8.0 or 12.4.0

#### Group B: Verification (After Group A)

- [ ] **Task #1**: Verify GPU build produces expected artifacts
  - Run: `FORCE=1 ZISK_GPU=1 ./run build zisk`
  - Check: `ls -la binaries/cargo-zisk-cuda binaries/libzisk_witness.so binaries/zisk-lib/`
  - Check: `ldd binaries/cargo-zisk-cuda` — all libs should resolve via `binaries/zisk-lib/`

- [ ] **Task #2**: Verify CPU execution tests still work
  - Run: `ZISK_MODE=execute ./run test zisk`
  - Check: Same pass/fail counts as before

- [ ] **Task #3**: Verify GPU proving works
  - Run: `ACT4_JOBS=1 ZISK_GPU=1 ./run test zisk`
  - Check: `prove_status` and `verify_status` populated in results JSON
  - Check: `nvidia-smi` shows GPU utilization during proving

---

## Status (2026-03-12)

**Infrastructure: Complete.** All build/test/runner plumbing works:
- `ZISK_GPU=1 ./run build zisk` produces `cargo-zisk-cuda` with CUDA 13.1
- GPU constant trees generated via `cargo-zisk-cuda check-setup -a`
- `ZISK_GPU=1 ./run test zisk` selects GPU binary and runs proving

**GPU Proving: Crashes upstream.** `cargo-zisk-cuda prove` aborts during NTT operations
with `CUDA context is destroyed (709)` errors. This appears to be a proofman v0.15.0
compatibility issue with Blackwell (sm_120) / CUDA 13.1. 32GB VRAM on RTX 5090 is
allocated but the computation crashes. `--minimal-memory` doesn't help.

**Next steps**: Try with proofman v0.16.0 when available, or test on Ampere/Hopper GPU.

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Execute & Update**: For each task, mark `[ ]` → `[x]` when completing
3. **Verify**: Run verification tasks after implementation

### Critical Rules
- This plan file is the source of truth for progress
- Only Task #0 requires code changes — everything else is verification
- If CUDA version doesn't work, iterate on the version number only
