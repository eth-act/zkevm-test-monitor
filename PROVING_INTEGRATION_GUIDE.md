# Proving Integration Guide

How GPU proving works in the zkevm-test-monitor, using Zisk as the reference
implementation. This guide covers architecture, build pipeline, test execution,
and GPU-specific concerns.

## Architecture Overview

Proving follows a split pipeline: ELF generation runs in Docker (with Sail
reference model and GCC), while test execution and proving run on the host
(where GPU access is available).

```
./run build zisk                           ./run test zisk
        │                                          │
        ▼                                          ▼
docker/build-zisk/Dockerfile               src/test.sh
  ├─ Stage 1: nvidia/cuda:*-devel           ├─ Phase 1: Docker ELF generation
  │   ├─ cargo build ziskemu                │   └─ Sail + GCC → .elf files
  │   ├─ cargo build cargo-zisk             │
  │   ├─ cargo build -p zisk-witness        ├─ Phase 2: Host test execution
  │   └─ [GPU=1] cargo build --features gpu │   └─ act4-runner
  │       └─ cargo-zisk-cuda                │       ├─ Execute: ziskemu --elf
  └─ Stage 2: nvidia/cuda:*-runtime        │       └─ Prove: cargo-zisk prove
      └─ Bundles binaries + shared libs     │
                                            └─ Phase 3: Results processing
```

## Build Pipeline

### Dockerfile (`docker/build-zisk/Dockerfile`)

Two-stage Docker build based on `nvidia/cuda:13.1.1-devel-ubuntu24.04`:

**Stage 1 (builder):**
1. Installs system deps (CUDA toolkit, MPI, C++ toolchain, etc.)
2. Clones zisk at the pinned commit from `config.json`
3. Builds `ziskemu` and `cargo-zisk` via `cargo build --release`
4. Builds `libzisk_witness.so` if the crate exists at this commit
5. Bundles shared libs (`libsodium`, `libomp`) by inspecting `ldd` output
6. If `GPU=1`: builds `cargo-zisk` again with `--features gpu`, renames to
   `cargo-zisk-cuda`, and bundles CUDA runtime libs (`libcudart`, `libcublasLt`,
   `libcublas`)

**Stage 2 (runtime):** Copies all artifacts to a minimal runtime image for
extraction via `docker cp`.

Key Dockerfile details:
- `ARG GPU=0` and `ARG CUDA_ARCH=sm_89` control GPU compilation
- `CUDA_ARCH` is passed to proofman's Makefile for correct GPU code generation
- Libraries are bundled in `/workspace/output/lib/` and extracted to `binaries/zisk-lib/`
  so host binaries work even when host and Docker have different lib versions

### Build Script (`src/build.sh`)

The build script handles:

1. **CUDA arch auto-detection** (lines 46-57): Queries `nvidia-smi
   --query-gpu=compute_cap` and converts to sm notation (e.g. `12.0` → `sm_120`)
2. **Docker build**: Passes `--build-arg GPU=1 --build-arg CUDA_ARCH=sm_120`
3. **Artifact extraction** (lines 86-106): Extracts from the container:
   - `ziskemu` → `binaries/zisk-binary`
   - `cargo-zisk` → `binaries/cargo-zisk`
   - `libzisk_witness.so` → `binaries/libzisk_witness.so`
   - `lib/` → `binaries/zisk-lib/` (bundled shared libs)
   - `cargo-zisk-cuda` → `binaries/cargo-zisk-cuda` (GPU, optional)
4. **Proving key installation** (lines 108-167):
   - Downloads keys from `https://storage.googleapis.com/zisk-setup/`
   - Extracts to `$HOME/.zisk/provingKey/`
   - Runs `cargo-zisk check-setup -a` to generate CPU constant trees
   - Runs `cargo-zisk-cuda check-setup -a` to generate GPU constant trees
   - Tracks versions via marker files to avoid redundant downloads

### Build Commands

```bash
# CPU-only build
./run build zisk

# GPU build (auto-detects CUDA arch)
ZISK_GPU=1 ./run build zisk

# GPU build with explicit CUDA arch
CUDA_ARCH=sm_120 ZISK_GPU=1 ./run build zisk

# Force rebuild
FORCE=1 ZISK_GPU=1 ./run build zisk
```

### Build Artifacts

After a successful GPU build, `binaries/` contains:

```
binaries/
├── zisk-binary              # ziskemu (emulator)
├── cargo-zisk               # CPU prover CLI
├── cargo-zisk-cuda          # GPU prover CLI (only with ZISK_GPU=1)
├── libzisk_witness.so       # Witness library (v0.15.0+)
└── zisk-lib/                # Bundled shared libraries
    ├── libsodium.so.26
    ├── libomp.so.5
    ├── libcudart.so.12       # Only with ZISK_GPU=1
    ├── libcublasLt.so.12     # Only with ZISK_GPU=1
    └── libcublas.so.12       # Only with ZISK_GPU=1
```

## Test Execution Pipeline

### Overview (`src/test.sh`)

The `run_zisk_split_pipeline()` function orchestrates everything:

1. Validates required binaries exist
2. Selects GPU binary if `ZISK_GPU` is set
3. Generates ELFs via Docker (or reuses cached ones)
4. Builds `act4-runner` (Rust binary) if needed
5. Sets `LD_LIBRARY_PATH` for bundled libs
6. Runs native suite (always execute-only)
7. Runs target suite (respects `ZISK_MODE`)
8. Updates history JSON

### LD_LIBRARY_PATH

Critical for GPU proving: host CUDA libs must come first in the path, because
Docker-bundled `libcudart` may not match the host's NVIDIA driver version.

```bash
# What test.sh does:
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$PWD/binaries/zisk-lib"
```

### Test Modes

Controlled by `ZISK_MODE` environment variable:

| Mode      | Execute | Prove | Verify | Use Case |
|-----------|---------|-------|--------|----------|
| `execute` | Yes     | No    | No     | Fast emulation-only testing |
| `prove`   | Yes     | Yes   | No     | Proof generation without verification |
| `full`    | Yes     | Yes   | Yes    | Full pipeline (default) |

The native suite (full ISA, ~239 tests) always runs in `execute` mode. Only
the target suite (standard ISA, ~72 tests) uses the requested mode.

### Test Commands

```bash
# Execute only (fastest)
ZISK_MODE=execute ./run test zisk

# Full pipeline with GPU proving
ZISK_GPU=1 ./run test zisk

# GPU proving without verification
ZISK_MODE=prove ZISK_GPU=1 ./run test zisk

# Limit parallelism
ACT4_JOBS=1 ZISK_GPU=1 ./run test zisk
```

## act4-runner: The Test Harness

A Rust binary (`act4-runner/`) that discovers ELFs, runs them through a ZKVM
backend in parallel, and writes JSON results.

### CLI Interface (`main.rs`)

```
act4-runner
  --zkvm <backend>          # airbender, openvm, zisk, zisk-prove
  --binary <path>           # Path to emulator binary
  --elf-dir <dir>           # Directory with .elf test files
  --output-dir <dir>        # Where to write JSON results
  --suite <name>            # "act4" or "act4-target"
  --label <name>            # "full-isa" or "standard-isa"
  --mode <mode>             # execute|prove|full (default: execute)
  --cargo-zisk <path>       # Path to cargo-zisk (zisk-prove only)
  --witness-lib <path>      # Path to libzisk_witness.so (zisk-prove only)
  --gpu                     # Enable GPU acceleration
  -j, --jobs <n>            # Parallel jobs (default: auto)
```

### Backend Selection

- `--zkvm zisk`: Execute-only via `ziskemu -e <elf>`
- `--zkvm zisk-prove`: Execute + prove via `ziskemu` then `cargo-zisk prove`

### Proving Lifecycle (`backends.rs`, `run_zisk_prove`)

When mode is `prove` or `full`:

```
1. Execute:  ziskemu --elf <path> --inputs /dev/null
             → exit code 0 + no "finished with error" in stderr = pass

2. Skip if:  mode == Execute OR execution failed

3. Prove:    cargo-zisk prove --elf <path> --emulator -o <tmpdir>
             [--witness-lib <path>]    # v0.15.0
             [--verify-proofs]         # mode == Full

4. Cleanup:  If GPU binary crashed, kill zombies + wait for GPU free
```

The proving command runs in an isolated process group with core dumps disabled:

```rust
// Isolated process group (MPI signal isolation)
cmd.process_group(0);

// Disable core dumps (7+ GB process would hang writing core)
unsafe {
    cmd.pre_exec(|| {
        let zero = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        libc::setrlimit(libc::RLIMIT_CORE, &zero);
        Ok(())
    });
}
```

### Job Auto-Tuning (`runner.rs`)

| Backend | Strategy |
|---------|----------|
| `zisk`, `zisk-prove` | Memory-based: 80% of available RAM / 8 GB per instance, clamped 1-24 |
| `airbender-prove` | Always 1 (GPU serialization) |
| Others | `available_parallelism()` (CPU cores) |

For proving modes (`prove`/`full`), `main.rs` overrides to 1 job regardless of
backend, since proving is resource-intensive.

### Results Output (`results.rs`)

Two JSON files per suite:

**`summary-act4-{label}.json`:**
```json
{
  "zkvm": "zisk",
  "suite": "act4-target",
  "passed": 50,
  "failed": 1,
  "total": 51
}
```

**`results-act4-{label}.json`:**
```json
{
  "zkvm": "zisk",
  "suite": "act4-target",
  "tests": [
    {
      "name": "I-add-01",
      "extension": "I",
      "passed": true,
      "prove_duration_secs": 2.1,
      "proof_written": true,
      "prove_status": "success",
      "verify_status": "success"
    }
  ]
}
```

## GPU-Specific Concerns

### Zombie Process Handling

`cargo-zisk-cuda` uses OpenMPI internally. On crash (SIGABRT, OOM), child
processes can remain holding GPU memory. The runner handles this:

```rust
if cargo_zisk.to_string_lossy().contains("cuda") {
    if !prove_output.status.success() {
        // Kill lingering cargo-zisk processes
        let _ = Command::new("pkill").args(["-9", "cargo-zisk"]).status();
        std::thread::sleep(Duration::from_secs(3));
    }
    wait_for_gpu_free(Duration::from_secs(30));
}
```

### GPU Memory Polling

Between GPU proves, `wait_for_gpu_free()` polls `nvidia-smi` to ensure no
compute processes are using the GPU before starting the next proof:

```rust
fn wait_for_gpu_free(timeout: Duration) {
    loop {
        let output = Command::new("nvidia-smi")
            .args(["--query-compute-apps=pid", "--format=csv,noheader"])
            .output();
        // If stdout is empty, GPU is free → return
        // If timeout exceeded, warn and proceed anyway
        // Otherwise sleep 500ms and retry
    }
}
```

### CUDA Arch Detection

During build, `build.sh` auto-detects the GPU compute capability:

```bash
CAP=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
CUDA_ARCH="sm_${CAP}"  # e.g. sm_120 for RTX 5090 (Blackwell)
```

This value is passed as `--build-arg CUDA_ARCH` to the Docker build, where
proofman's Makefile uses it to compile CUDA kernels for the correct architecture.

### Library Path Ordering

Host CUDA libraries must precede Docker-bundled ones in `LD_LIBRARY_PATH`:

```
/usr/local/cuda/lib64         ← Host CUDA (matches driver)
$PWD/binaries/zisk-lib        ← Docker-bundled (libsodium, libomp, fallback CUDA)
```

If the Docker-bundled `libcudart` loads instead of the host's, version mismatch
with the NVIDIA driver causes silent failures or crashes.

## Proving Keys

Proving keys are version-specific and auto-managed by `build.sh`:

- **Download**: `https://storage.googleapis.com/zisk-setup/zisk-provingkey-pre-{major}.{minor}.0.tar.gz`
- **Install location**: `$HOME/.zisk/provingKey/`
- **Constant trees**: Generated by `cargo-zisk check-setup -a` (CPU) and
  `cargo-zisk-cuda check-setup -a` (GPU), stored in `$HOME/.zisk/cache/`
- **Version tracking**: Marker files `$HOME/.zisk/.zisk-setup-version` and
  `$HOME/.zisk/.zisk-setup-gpu` prevent redundant reinstalls

When a GPU binary is added after initial setup, `build.sh` detects the missing
GPU marker and runs GPU constant tree generation automatically.

## Adding Proving for a New ZKVM

To add proving support for another ZKVM, follow this pattern:

1. **Build Dockerfile** (`docker/build-<name>/Dockerfile`):
   - Use `nvidia/cuda:*-devel` as base if GPU proving is needed
   - Build all required binaries (emulator, prover, witness lib)
   - Bundle shared libs via `ldd` inspection
   - Add `ARG GPU=0` and conditional GPU build

2. **Build script** (`src/build.sh`):
   - Add ZKVM-specific extraction block (multiple artifacts)
   - Add GPU auto-detection if applicable
   - Add proving key installation if the ZKVM requires it

3. **act4-runner backend** (`act4-runner/src/backends.rs`):
   - Add a new `Backend` enum variant with required paths
   - Implement the proving lifecycle function
   - Handle GPU cleanup (zombie processes, memory polling)
   - Isolate in process group + disable core dumps for large processes

4. **CLI wiring** (`act4-runner/src/main.rs`):
   - Add match arm for the new `--zkvm` value
   - Add any new CLI args (prover binary path, etc.)

5. **Test script** (`src/test.sh`):
   - Add a split pipeline function
   - Handle `LD_LIBRARY_PATH` for bundled libs
   - Wire GPU binary selection
   - Separate native (execute-only) from target (proving) suites

6. **Job tuning** (`act4-runner/src/runner.rs`):
   - Add memory/GPU constraints to `default_jobs()`

## Design Decisions

**Why split pipeline?** GPU access requires running on the host, not inside
Docker. ELF generation (Sail + GCC) has no GPU dependency, so it runs in Docker
for reproducibility. Test execution runs on the host where the GPU is available.

**Why bundle shared libs?** The Docker build environment (Ubuntu 24.04) may have
different library versions than the host (e.g. Arch Linux). Bundling `libsodium`
and `libomp` ensures the binaries work regardless of host distro.

**Why process groups?** `cargo-zisk` uses OpenMPI internally. If the prover
crashes, MPI propagates signals (SIGABRT) to all processes in the session. An
isolated process group prevents the runner itself from being killed.

**Why disable core dumps?** A crashing 7+ GB proving process would trigger
`systemd-coredump`, hanging for minutes writing a core file. Disabling core
dumps via `setrlimit(RLIMIT_CORE, 0)` prevents this.

**Why `--emulator` flag?** `cargo-zisk prove` can use either a server-based or
emulator-based witness generation mode. The `--emulator` flag uses the simpler
single-command mode, avoiding the complexity of managing a `cargo-zisk server`
lifecycle (start, poll status, prove-client, shutdown).
