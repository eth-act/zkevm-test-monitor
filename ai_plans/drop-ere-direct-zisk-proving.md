# Drop ere, Call Zisk CLI Tools Directly — Implementation Plan

## Executive Summary

> **Problem**: act4-runner depends on `ere-zisk` as a Rust library for Zisk proving. But ere just
> shells out to `ziskemu`, `cargo-zisk`, and `cargo-zisk prove-client` — CLI tools that ere
> doesn't build or ship. This creates:
> - `libiomp5` linking issues requiring shims
> - A local `ere/` checkout as a path dependency
> - No support for arbitrary zisk commits (ere's installer hardcodes v0.15.0)
> - No self-contained build — `./run build zisk && ./run test zisk` doesn't work end-to-end
>
> **Solution**: Remove ere. Expand `docker/build-zisk/` to build all three Zisk tools
> (`ziskemu`, `cargo-zisk`, `libzisk_witness.so`). Implement the cargo-zisk server lifecycle
> directly in act4-runner's `backends.rs` (~80 lines, inspired by ere's `sdk.rs` and `server.rs`).
>
> **Expected Outcomes**:
> - `./run build zisk` produces all proving tools from any commit/fork
> - `./run test zisk` runs execute + prove + verify with no ere dependency
> - `ZISK_GPU=1 ./run test zisk` works for GPU proving
> - No libiomp5 shims, no path dependencies, no ere checkout needed

## Goals & Objectives

### Primary Goals
- `./run build zisk` builds `ziskemu`, `cargo-zisk`, and `libzisk_witness.so` from arbitrary commits
- `./run test zisk` runs full execute → prove → verify pipeline using those tools directly
- Zero external dependencies beyond Docker and Rust

### Secondary Objectives
- GPU proving via `ZISK_GPU=1` (builds cuda variants with `--features gpu`)
- Clean `./run build zisk && ./run test zisk` workflow matching other ZKVMs

## Solution Overview

### Approach
Replace the ere Rust library with direct CLI invocations of the same tools ere calls.
Expand the existing Docker build to produce all three artifacts.

### Data Flow

```
./run build zisk
  └─ docker/build-zisk/Dockerfile
       ├─ cargo build --release --bin ziskemu --bin cargo-zisk -p zisk-witness
       └─ Outputs: binaries/{zisk-binary, cargo-zisk, libzisk_witness.so}

./run test zisk
  └─ src/test.sh → run_zisk_split_pipeline()
       ├─ Docker: generate ELFs (Sail + GCC)  [unchanged]
       └─ act4-runner --zkvm zisk-prove
            ├─ Execute: ziskemu --elf <path> --inputs <tmp> --output <tmp>
            ├─ Prove:
            │    ├─ cargo-zisk check-setup --aggregation
            │    ├─ cargo-zisk rom-setup --elf <path>
            │    ├─ cargo-zisk server --elf <path> --witness-lib <lib> --aggregation
            │    ├─ poll: cargo-zisk prove-client status  (1s interval, 120s timeout)
            │    ├─ cargo-zisk prove-client prove --input <f> --output_dir <d> -p act4 --aggregation --verify_proofs
            │    ├─ poll: cargo-zisk prove-client status  (1s interval, 3600s timeout)
            │    └─ cargo-zisk prove-client shutdown
            └─ Verify: handled by --verify_proofs flag above
```

### Expected Outcomes
- `./run build zisk` produces 3 binaries from any zisk commit or fork
- `ZISK_MODE=execute ./run test zisk` runs emulation only (237/239 native, 72/72 target)
- `./run test zisk` (default mode=full) runs execute + prove + verify
- `ZISK_GPU=1 ./run build zisk` builds GPU variants; `ZISK_GPU=1 ./run test zisk` uses them
- No ere checkout, no libiomp5 shims, no path dependencies

## Implementation Tasks

### Visual Dependency Tree

```
docker/build-zisk/
└── Dockerfile                    (Task #0: Expand to build all 3 tools)

src/
└── build.sh                      (Task #1: Extract 3 artifacts + GPU variants)

act4-runner/
├── Cargo.toml                    (Task #2: Remove ere deps, add tempfile)
├── .cargo/config.toml            (Task #2: Remove libiomp5 shim)
└── src/
    ├── backends.rs               (Task #3: Replace ZiskEre with ZiskProve backend)
    ├── main.rs                   (Task #4: Wire new CLI args + backend)
    └── runner.rs                 (Task #4: Update default_jobs)

src/
└── test.sh                       (Task #5: Simplify pipeline, remove ere hacks)

run                               (Task #5: Update help text)
```

### Execution Plan

#### Group A: Build Infrastructure (Execute in parallel)

- [x] **Task #0**: Expand `docker/build-zisk/Dockerfile` to build all Zisk tools
  - File: `docker/build-zisk/Dockerfile`
  - Currently builds only `--bin ziskemu` (line 69)
  - Changes:
    - Add `ARG GPU=0` build arg
    - Change build command to build all targets:
      ```dockerfile
      RUN cargo build --release --bin ziskemu --bin cargo-zisk -p zisk-witness
      ```
    - For GPU: conditionally add `--features gpu` and rename outputs
      ```dockerfile
      RUN if [ "$GPU" = "1" ]; then \
            cargo build --release --bin cargo-zisk -p zisk-witness --features gpu && \
            cp target/release/cargo-zisk /workspace/cargo-zisk-cuda && \
            cp target/release/libzisk_witness.so /workspace/libzisk_witness_cuda.so; \
          fi
      ```
    - Copy all artifacts in final stage:
      ```dockerfile
      COPY --from=builder /workspace/zisk/target/release/ziskemu /usr/local/bin/ziskemu
      COPY --from=builder /workspace/zisk/target/release/cargo-zisk /usr/local/bin/cargo-zisk
      COPY --from=builder /workspace/zisk/target/release/libzisk_witness.so /usr/local/lib/libzisk_witness.so
      # GPU variants (may not exist)
      COPY --from=builder /workspace/cargo-zisk-cuda /usr/local/bin/cargo-zisk-cuda
      COPY --from=builder /workspace/libzisk_witness_cuda.so /usr/local/lib/libzisk_witness_cuda.so
      ```
      Note: Use a shell-based entrypoint that conditionally copies GPU files only if they exist
    - Update entrypoint to export all binaries:
      ```dockerfile
      ENTRYPOINT ["sh", "-c", "\
        cp /usr/local/bin/ziskemu /output/ziskemu && \
        cp /usr/local/bin/cargo-zisk /output/cargo-zisk && \
        cp /usr/local/lib/libzisk_witness.so /output/libzisk_witness.so && \
        cp /usr/local/bin/cargo-zisk-cuda /output/cargo-zisk-cuda 2>/dev/null; \
        cp /usr/local/lib/libzisk_witness_cuda.so /output/libzisk_witness_cuda.so 2>/dev/null; \
        true"]
      ```
  - Context: This is the foundation — all other tasks depend on these artifacts existing

- [x] **Task #1**: Update `src/build.sh` to extract all Zisk artifacts
  - File: `src/build.sh`
  - Changes to the zisk special-case block (currently lines 83-85):
    - Pass `ZISK_GPU` as Docker build arg:
      ```bash
      # In the docker build command, add:
      if [ "$ZKVM" = "zisk" ]; then
        GPU_ARG=""
        if [ -n "${ZISK_GPU:-}" ]; then
          GPU_ARG="--build-arg GPU=1"
        fi
      fi
      # Then: docker build $GPU_ARG ...
      ```
    - Extract all artifacts from container (replace existing lines 83-85):
      ```bash
      if [ "$ZKVM" = "zisk" ]; then
        # Extract all zisk tools
        docker cp "$CONTAINER_ID:/usr/local/bin/ziskemu" "binaries/zisk-binary"
        docker cp "$CONTAINER_ID:/usr/local/bin/cargo-zisk" "binaries/cargo-zisk"
        docker cp "$CONTAINER_ID:/usr/local/lib/libzisk_witness.so" "binaries/libzisk_witness.so"
        # GPU variants (optional)
        docker cp "$CONTAINER_ID:/usr/local/bin/cargo-zisk-cuda" "binaries/cargo-zisk-cuda" 2>/dev/null || true
        docker cp "$CONTAINER_ID:/usr/local/lib/libzisk_witness_cuda.so" "binaries/libzisk_witness_cuda.so" 2>/dev/null || true
        chmod +x binaries/cargo-zisk binaries/cargo-zisk-cuda 2>/dev/null || true
      fi
      ```
    - Must happen BEFORE the generic `docker cp` on line 68 — restructure the zisk case
      to skip the generic extraction and do its own
  - Integration: `binaries/` dir will now contain up to 5 files for zisk
  - Context: build.sh currently extracts one binary per ZKVM; zisk needs special handling for multiple

#### Group B: act4-runner Core (Execute in parallel, independent of Group A)

- [x] **Task #2**: Remove ere dependencies from act4-runner
  - Files: `act4-runner/Cargo.toml`, `act4-runner/.cargo/config.toml`
  - Changes to `Cargo.toml`:
    - Remove:
      ```toml
      ere-zisk = { path = "../ere/crates/zkvm/zisk", default-features = false, features = ["zkvm"] }
      ere-zkvm-interface = { path = "../ere/crates/zkvm-interface" }
      ```
    - Add:
      ```toml
      tempfile = "3"
      ```
  - Changes to `.cargo/config.toml`:
    - Delete this file entirely (libiomp5 shim no longer needed)
  - Context: Unlocks act4-runner to compile without ere checkout or libiomp5

- [x] **Task #3**: Implement `ZiskProve` backend in `backends.rs`
  - File: `act4-runner/src/backends.rs`
  - **Remove**:
    - `Backend::ZiskEre { gpu: bool }` variant
    - `run_zisk_ere()` function (lines 84-173)
    - All `use` statements for `ere_zisk::*` and `ere_zkvm_interface::*`
  - **Add** new variant:
    ```rust
    Backend::ZiskProve {
        ziskemu: PathBuf,        // path to ziskemu binary
        cargo_zisk: PathBuf,     // path to cargo-zisk (or cargo-zisk-cuda)
        witness_lib: PathBuf,    // path to libzisk_witness.so
        gpu: bool,
    }
    ```
  - **Add** `run_zisk_prove()` function implementing the full lifecycle.
    Imports needed:
    ```rust
    use std::io::{BufRead, BufReader};
    use std::thread;
    use std::time::Duration;
    ```
  - **Implementation of `run_zisk_prove()`** (~80 lines):
    ```rust
    fn run_zisk_prove(
        ziskemu: &Path,
        cargo_zisk: &Path,
        witness_lib: &Path,
        elf_path: &Path,
        mode: Mode,
        gpu: bool,
        start: Instant,
    ) -> RunResult {
        // 1. Execute: ziskemu --elf <path> --inputs <tmp_in> --output <tmp_out>
        //    - Create temp dir via tempfile::tempdir()
        //    - Write empty input file
        //    - Run ziskemu, check exit code
        //    - passed = exit code 0
        //    - If mode == Execute or !passed, return early

        // 2. Check setup: cargo-zisk check-setup --aggregation
        //    - Run once (use std::sync::Once or just run every time — it's idempotent)
        //    - Always uses cargo-zisk (not cuda variant) per ere's behavior
        //    NOTE: check-setup and rom-setup always use non-cuda cargo-zisk.
        //    Only the server uses the cuda variant.

        // 3. ROM setup: cargo-zisk rom-setup --elf <path>
        //    - Parse "Root hash: [u64, u64, u64, u64]" from stdout (optional, for future use)

        // 4. Start server:
        //    cargo_zisk server \
        //      --elf <path> \
        //      --witness-lib <witness_lib_path> \
        //      --aggregation
        //    - Spawn as child process (Command::new().spawn())
        //    - Poll status until "idle" (see poll_until_idle below)
        //    - Timeout: 120 seconds, retry up to 3 times

        // 5. Prove:
        //    cargo_zisk prove-client prove \
        //      --input <input_file> \
        //      --output_dir <temp_dir> \
        //      -p act4 \
        //      --aggregation \
        //      --verify_proofs
        //    - Wait for command to complete
        //    - Poll status until "idle" again (timeout: 3600s)
        //    - Proof at: <temp_dir>/act4-vadcop_final_proof.bin

        // 6. Shutdown:
        //    cargo_zisk prove-client shutdown
        //    - Kill child if shutdown times out (30s)
        //    - Clean up /dev/shm/ZISK* and /dev/shm/sem* files

        // 7. Return RunResult with prove_status, verify_status (from --verify_proofs)
    }
    ```
  - **Add** helper `poll_until_idle()`:
    ```rust
    /// Poll `cargo-zisk prove-client status` until output contains "idle".
    /// Returns Ok(()) on idle, Err on timeout or unknown status.
    fn poll_until_idle(cargo_zisk: &Path, timeout: Duration) -> anyhow::Result<()> {
        let deadline = Instant::now() + timeout;
        loop {
            if Instant::now() > deadline {
                anyhow::bail!("timeout waiting for server");
            }
            let output = Command::new(cargo_zisk)
                .args(["prove-client", "status"])
                .output()?;
            let stdout = String::from_utf8_lossy(&output.stdout);
            if stdout.contains("idle") {
                return Ok(());
            }
            if !stdout.contains("working") && output.status.success() {
                // Server not ready yet, keep polling
            }
            thread::sleep(Duration::from_secs(1));
        }
    }
    ```
  - **Add** helper `cleanup_shared_memory()`:
    ```rust
    /// Clean up Zisk shared memory files from /dev/shm/
    fn cleanup_shared_memory() {
        // glob /dev/shm/ZISK* and /dev/shm/sem* and remove
        if let Ok(entries) = std::fs::read_dir("/dev/shm") {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with("ZISK") || name.starts_with("sem") {
                    let _ = std::fs::remove_file(entry.path());
                }
            }
        }
    }
    ```
  - **Update** `run_elf()` dispatch to route `ZiskProve` to `run_zisk_prove()`
  - Context: This is the core replacement for ere. The cargo-zisk server lifecycle
    is copied from ere's `server.rs` behavior but implemented as direct CLI calls.

- [x] **Task #4**: Update `main.rs` and `runner.rs` for new backend
  - Files: `act4-runner/src/main.rs`, `act4-runner/src/runner.rs`
  - Changes to `main.rs`:
    - Add CLI args:
      ```rust
      /// Path to cargo-zisk binary (for zisk-prove backend).
      #[arg(long)]
      cargo_zisk: Option<PathBuf>,

      /// Path to witness library (for zisk-prove backend).
      #[arg(long)]
      witness_lib: Option<PathBuf>,
      ```
    - Replace `"zisk-ere"` match arm with `"zisk-prove"`:
      ```rust
      "zisk-prove" => Backend::ZiskProve {
          ziskemu: require_binary(&cli),
          cargo_zisk: cli.cargo_zisk.clone().unwrap_or_else(|| {
              eprintln!("error: --cargo-zisk is required for zkvm 'zisk-prove'");
              process::exit(2);
          }),
          witness_lib: cli.witness_lib.clone().unwrap_or_else(|| {
              eprintln!("error: --witness-lib is required for zkvm 'zisk-prove'");
              process::exit(2);
          }),
          gpu: cli.gpu,
      },
      ```
    - Update error message to list `zisk-prove` instead of `zisk-ere`
    - Keep `"zisk"` backend for execute-only (backward compat)
  - Changes to `runner.rs`:
    - Replace `"zisk-ere"` with `"zisk-prove"` in `default_jobs()` match (line 58)
  - Context: CLI interface change from `--zkvm zisk-ere` to `--zkvm zisk-prove`

#### Group C: Shell Script Integration (After Groups A and B)

- [x] **Task #5**: Simplify `src/test.sh` and update `run` script
  - Files: `src/test.sh`, `run`
  - Changes to `run_zisk_split_pipeline()` in `src/test.sh`:
    - **Remove** libiomp5 shim creation (lines 173-176)
    - **Remove** `LIBRARY_PATH` hack for act4-runner build (lines 177-178)
    - **Remove** ziskemu PATH shim logic (lines 186-197)
    - **Remove** `LD_LIBRARY_PATH` manipulation (lines 200-202)
    - **Add** binary existence checks:
      ```bash
      for bin in binaries/zisk-binary binaries/cargo-zisk binaries/libzisk_witness.so; do
        if [ ! -f "$bin" ]; then
          echo "  Error: $bin not found. Run './run build zisk' first."
          return 1
        fi
      done
      ```
    - **Determine** cargo-zisk binary (GPU selection):
      ```bash
      local CARGO_ZISK="binaries/cargo-zisk"
      local WITNESS_LIB="binaries/libzisk_witness.so"
      if [ -n "${ZISK_GPU:-}" ]; then
        if [ -f "binaries/cargo-zisk-cuda" ]; then
          CARGO_ZISK="binaries/cargo-zisk-cuda"
          WITNESS_LIB="binaries/libzisk_witness_cuda.so"
        else
          echo "  Warning: GPU requested but cargo-zisk-cuda not found, using CPU"
        fi
      fi
      ```
    - **Update** runner invocations:
      ```bash
      "$RUNNER" \
        --zkvm zisk-prove \
        --binary binaries/zisk-binary \
        --cargo-zisk "$CARGO_ZISK" \
        --witness-lib "$WITNESS_LIB" \
        --elf-dir "$ELF_DIR/native" \
        --output-dir "test-results/${ZKVM}" \
        --suite act4 --label full-isa \
        --mode "$MODE" $RUNNER_JOBS || true
      ```
      (Same pattern for target suite)
    - **Simplify** act4-runner build step — just `cargo build --release`, no shims:
      ```bash
      if [ ! -x "$RUNNER" ]; then
        echo "  Building act4-runner..."
        cargo build --release --manifest-path act4-runner/Cargo.toml 2>&1 || {
          echo "  Failed to build act4-runner"
          return 1
        }
      fi
      ```
  - Changes to `run`:
    - Update help text: remove `ZISK_GPU=1` from test example, add to build example
    - Add example: `ZISK_GPU=1 ./run build zisk    # build with GPU support`
  - Context: This makes the split pipeline self-contained with no runtime hacks

#### Group D: Cleanup (After Group C verified working)

- [x] **Task #6**: Remove ere artifacts and update documentation
  - **Delete**: `act4-runner/lib-shims/` directory (if it exists)
  - **Delete**: `act4-runner/.cargo/config.toml` (done in Task #2, verify)
  - **Update** `config.json`: no changes needed (already has correct zisk config)
  - **Update** `run` help text: ensure `ZISK_GPU` is documented for both build and test
  - **Do NOT delete** the `ere/` directory — it's a separate checkout, not our code
  - Context: Final cleanup after everything is verified working

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Sync Tasks**: Create TodoWrite tasks matching the checkboxes above
3. **Execute & Update**: For each task:
   - Mark TodoWrite as `in_progress` when starting
   - Update checkbox `[ ]` to `[x]` when completing
   - Mark TodoWrite as `completed` when done
4. **Maintain Sync**: Keep this file and TodoWrite synchronized throughout

### Critical Rules
- This plan file is the source of truth for progress
- Update checkboxes in real-time as work progresses
- Never lose synchronization between plan file and TodoWrite
- Mark tasks complete only when fully implemented (no placeholders)
- Tasks should be run in parallel, unless there are dependencies, using subtasks, to avoid context bloat.

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.

## Verification

1. `./run build zisk` — produces `binaries/{zisk-binary, cargo-zisk, libzisk_witness.so}`
2. `act4-runner` compiles with `cargo build --release --manifest-path act4-runner/Cargo.toml` (no ere, no shims)
3. `ZISK_MODE=execute ./run test zisk` — 237/239 native, 72/72 target (matches current)
4. `./run test zisk` (default mode=full) — proves + verifies via cargo-zisk server lifecycle
5. `ZISK_GPU=1 ./run build zisk && ZISK_GPU=1 ./run test zisk` — GPU proving
