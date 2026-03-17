# ACT4-to-Ere Transition Implementation Plan

## Executive Summary

The ACT4 RISC-V architectural compliance test pipeline uses per-ZKVM shell wrapper scripts
inside Docker containers. Each wrapper invokes a ZKVM CLI binary with different conventions.
We want to replace these with Ere's unified execution interface for {zisk, airbender, openvm}.

**After deeper analysis, the blockers are small and patchable:**

1. **Program struct fields are `pub(crate)`** — trivial fix: add `from_elf()` constructors (one-liner per struct, no invariants to protect)
2. **Airbender CLI mismatch** (`run` vs `run-with-transpiler`) — both subcommands exist in the same CLI binary (v0.5.2). Ere's SDK just needs to switch to `run-with-transpiler` for ACT4-compatible execution
3. **Non-zero exit = Err** — need to add `exit_code: Option<i32>` to `ProgramExecutionReport` and not error on non-zero exit when running compliance tests
4. **OpenVM is in-process** — `sdk.execute()` returns `SdkError` on failure, no raw exit codes; but OpenVM's halt opcode (0x0b) exits with imm as the exit code, so the SDK probably already surfaces this as an error code

**Approach:** Patch Ere with minimal upstream-friendly changes, then build a thin `act4-runner` CLI that uses Ere's `zkVM::execute()` trait to run pre-built ACT4 ELFs.

## Goals & Objectives

### Primary Goals
- Enable Ere to accept pre-built (non-Rust) ELFs via `from_elf()` constructors
- Enable Ere to capture guest exit codes (not just treat non-zero as error)
- Build `act4-runner` CLI that uses Ere to run ACT4 compliance tests
- Produce identical JSON output format for dashboard compatibility

### Secondary Objectives
- Upstream-friendly patches (small, well-motivated PRs to Ere)
- Eliminate `run_tests.py` (Python) dependency for test orchestration
- Position Ere as the standard execution layer for all ZKVM testing

## Solution Overview

### Approach

Two layers of work:

1. **Ere patches** (3 small changes to ere/):
   - Add `from_elf()` constructors to Program structs
   - Add `exit_code` field to `ProgramExecutionReport`
   - Change Airbender SDK to use `run-with-transpiler` (or add it as an option)

2. **`act4-runner` crate** (new, uses patched Ere):
   - CLI that discovers ELFs, runs them through `zkVM::execute()`, collects results
   - Handles ELF patching (calls `patch_elfs.py` or ports to Rust)
   - Airbender-specific: objcopy + entry point/tohost extraction before constructing program

### Architecture

```
                           ┌─────────────────────────┐
                           │   act4-runner CLI        │
                           │  (discovers ELFs,        │
                           │   parallel dispatch,     │
                           │   JSON results)          │
                           └────────┬────────────────┘
                                    │ uses
              ┌─────────────────────┼──────────────────────┐
              │                     │                      │
    ┌─────────▼──────┐   ┌─────────▼──────┐   ┌──────────▼──────┐
    │ EreAirbender   │   │  EreOpenVM     │   │   EreZisk       │
    │ (patched)      │   │  (patched)     │   │   (patched)     │
    │                │   │                │   │                 │
    │ from_elf() ◄───┤   │ from_elf() ◄──┤   │ from_elf() ◄───┤
    │ exit_code  ◄───┤   │ exit_code ◄───┤   │ exit_code  ◄───┤
    └────────────────┘   └────────────────┘   └─────────────────┘
              │                     │                      │
    ┌─────────▼──────┐   ┌─────────▼──────┐   ┌──────────▼──────┐
    │ airbender-cli  │   │ OpenVM SDK     │   │ ziskemu CLI     │
    │ run-with-      │   │ (in-process)   │   │ --elf <path>    │
    │ transpiler     │   │                │   │                 │
    └────────────────┘   └────────────────┘   └─────────────────┘
```

### Key Differences from Previous Plan
- **NOT standalone** — act4-runner depends on Ere crates directly
- **Patches Ere** — small upstream-friendly changes, not a fork
- **Uses `zkVM::execute()` trait** — unified interface, not per-ZKVM CLI wrappers

### Expected Outcomes
- `act4-runner --zkvm airbender --elf-dir ./elfs` runs tests via Ere
- JSON output identical to current shell-based pipeline
- Ere gains reusable `from_elf()` API for any non-Rust guest program

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. Each Ere patch must be minimal and self-contained (upstream PR quality)
2. `act4-runner` must produce byte-identical JSON to current pipeline
3. Airbender backend must use `run-with-transpiler`, not `run`
4. OpenVM backend must handle in-process execution (no CLI shell-out)

### Visual Dependency Tree

```
ere/
├── crates/zkvm-interface/src/zkvm/
│   └── report.rs                          (Task #1: Add exit_code field)
│
├── crates/zkvm/airbender/src/
│   ├── program.rs                         (Task #0: Add from_elf() constructor)
│   └── zkvm/sdk.rs                        (Task #2: Switch to run-with-transpiler)
│
├── crates/zkvm/openvm/src/
│   └── program.rs                         (Task #0: Add from_elf() constructor)
│
├── crates/zkvm/zisk/src/
│   ├── program.rs                         (Task #0: Add from_elf() constructor)
│   └── zkvm/sdk.rs                        (Task #2: Capture exit code in execute)
│
act4-runner/
├── Cargo.toml                             (Task #3: Create crate depending on ere-*)
├── src/
│   ├── main.rs                            (Task #5: CLI entry point)
│   ├── elf_utils.rs                       (Task #3: ELF parsing for airbender)
│   ├── results.rs                         (Task #3: JSON output format)
│   ├── backends.rs                        (Task #4: Per-ZKVM program construction)
│   └── runner.rs                          (Task #5: Parallel execution orchestrator)
│
docker/{airbender,openvm,zisk}/
├── entrypoint.sh                          (Task #6: Replace run-dut.sh with act4-runner)
└── Dockerfile                             (Task #6: COPY act4-runner binary)
```

### Execution Plan

#### Group A: Ere Patches — Program Constructors (Execute in parallel)

- [ ] **Task #0**: Add `from_elf()` constructors to all three Program types
  - File: `ere/crates/zkvm/airbender/src/program.rs`
    - Add:
      ```rust
      impl AirbenderProgram {
          /// Create from pre-built ELF and flat binary bytes.
          pub fn from_elf(elf: Vec<u8>, bin: Vec<u8>) -> Self {
              Self { elf, bin }
          }
      }
      ```
  - File: `ere/crates/zkvm/openvm/src/program.rs`
    - Add:
      ```rust
      impl OpenVMProgram {
          pub fn from_elf(elf: Vec<u8>) -> Self {
              Self { elf, app_config: None }
          }
      }
      ```
  - File: `ere/crates/zkvm/zisk/src/program.rs`
    - Add:
      ```rust
      impl ZiskProgram {
          pub fn from_elf(elf: Vec<u8>) -> Self {
              Self { elf }
          }
      }
      ```
  - Context: Fields are `pub(crate)`, no invariants enforced — the compiler already constructs these with plain struct literals. These constructors just expose what's already possible within the crate.

- [ ] **Task #1**: Add `exit_code` field to `ProgramExecutionReport`
  - File: `ere/crates/zkvm-interface/src/zkvm/report.rs`
    - Add `pub exit_code: Option<i32>` field to `ProgramExecutionReport`
    - Must remain backward-compatible (Default impl should set to None)
  - Context: Currently non-zero exit from CLI backends → `CommonError::CommandExitNonZero` error. For ACT4, non-zero exit is a valid "test failed" result, not a program crash. This field lets callers distinguish.

#### Group B: Ere Patches — Backend Execution (After Group A)

- [ ] **Task #2**: Update backend `execute()` impls to support exit code capture
  - File: `ere/crates/zkvm/airbender/src/zkvm/sdk.rs`
    - Current: Uses `airbender-cli run` (line 62). Change to `run-with-transpiler` with `--entry-point` and `--tohost-addr` extracted from the ELF
    - OR: Add a separate `execute_with_transpiler()` method that act4-runner can call
    - Capture exit code: Instead of `if !output.status.success() { Err(...) }`, capture `output.status.code()` and populate `exit_code` field in report
    - **Important**: The `run-with-transpiler` subcommand already exists in airbender-cli v0.5.2 (line 161 of `tools/cli/src/main.rs`). Ere just doesn't use it yet.
    - For `run-with-transpiler`, Ere needs to pass entry_point and tohost_addr. These need to come from somewhere — either stored in `AirbenderProgram` or passed as execution parameters.
    - **Design decision**: Add `entry_point: Option<u32>` and `tohost_addr: Option<u32>` to `AirbenderProgram::from_elf()`, or add them to `EreAirbender::new()`. The former is cleaner since they're properties of the program, not the executor.
      ```rust
      impl AirbenderProgram {
          pub fn from_elf_with_config(
              elf: Vec<u8>,
              bin: Vec<u8>,
              entry_point: u32,
              tohost_addr: Option<u32>,
          ) -> Self { ... }
      }
      ```
  - File: `ere/crates/zkvm/zisk/src/zkvm/sdk.rs`
    - Capture exit code: same pattern as airbender — `output.status.code()` → report field
    - Currently shells out to `ziskemu --elf <path> --inputs <file> --output <file> --stats`
    - For ACT4 tests with no stdin, simplify to `ziskemu --elf <path>`
  - File: `ere/crates/zkvm/openvm/src/zkvm.rs` (line 124-147)
    - OpenVM uses in-process `sdk.execute()`. On failure, it returns `SdkError`
    - Need to investigate: does `SdkError` carry the guest exit code from opcode 0x0b?
    - If yes: extract it and put in `exit_code` field
    - If no: the act4-runner may need to call OpenVM's CLI binary directly as a fallback
  - Context: The goal is that `zkVM::execute()` returns `Ok(...)` with `exit_code: Some(1)` for a failing ACT4 test, instead of `Err(CommandExitNonZero)`. This is the core semantic change.

#### Group C: act4-runner Crate (After Group B)

- [ ] **Task #3**: Create `act4-runner` crate with utilities
  - File: `act4-runner/Cargo.toml`
    ```toml
    [package]
    name = "act4-runner"
    version = "0.1.0"
    edition = "2024"

    [dependencies]
    anyhow = "1"
    clap = { version = "4", features = ["derive"] }
    serde = { version = "1", features = ["derive"] }
    serde_json = "1"
    rayon = "1"
    goblin = "0.9"
    chrono = "0.4"
    ere-airbender = { path = "../ere/crates/zkvm/airbender" }
    ere-openvm = { path = "../ere/crates/zkvm/openvm" }
    ere-zisk = { path = "../ere/crates/zkvm/zisk" }
    ere-zkvm-interface = { path = "../ere/crates/zkvm-interface" }
    ```
  - File: `act4-runner/src/elf_utils.rs`
    - `pub fn extract_entry_point(elf_bytes: &[u8]) -> Result<u32>` — via `goblin::elf::Elf::parse()`, return `header.e_entry as u32`
    - `pub fn extract_tohost_address(elf_bytes: &[u8]) -> Result<u32>` — scan symbol table for `"tohost"`, return `st_value as u32`
    - `pub fn elf_to_flat_binary(elf_path: &Path) -> Result<Vec<u8>>` — shell out to `riscv64-unknown-elf-objcopy -O binary` (available in Docker container), or use `goblin` to do it in pure Rust
  - File: `act4-runner/src/results.rs`
    - Structs: `Summary`, `Results`, `TestEntry` — matching existing JSON format exactly
    - `pub fn write_results(dir, label, zkvm, suite, entries) -> Result<()>` — writes both summary and per-test JSON files
    - Extension extraction from filename: `"I-add-01.elf"` → `"I"`, `"M-mul-01.elf"` → `"M"`, `"Zaamo-amoswap_w-01.elf"` → `"Zaamo"`
  - Context: Pure utilities, no ZKVM logic

- [ ] **Task #4**: Implement per-ZKVM program construction in `backends.rs`
  - File: `act4-runner/src/backends.rs`
  - Implements:
    ```rust
    pub enum ZkvmKind { Airbender, OpenVM, Zisk }

    pub fn create_and_execute(kind: ZkvmKind, elf_path: &Path) -> Result<(bool, Option<i32>)>
    ```
  - **Airbender path**:
    1. Read ELF bytes from file
    2. Extract entry_point and tohost_addr via `elf_utils`
    3. Convert to flat binary via `elf_utils::elf_to_flat_binary()`
    4. Construct: `AirbenderProgram::from_elf_with_config(elf, bin, entry_point, Some(tohost_addr))`
    5. Create: `EreAirbender::new(program, ProverResource::Cpu)`
    6. Execute: `zkvm.execute(&Input::new())`
    7. Return: `(report.exit_code == Some(0), report.exit_code)`
  - **OpenVM path**:
    1. Read ELF bytes
    2. Construct: `OpenVMProgram::from_elf(elf)`
    3. Create: `EreOpenVM::new(program, ProverResource::Cpu)`
    4. Execute: `zkvm.execute(&Input::new())`
    5. Return: `(report.exit_code == Some(0), report.exit_code)`
  - **Zisk path**:
    1. Read ELF bytes
    2. Construct: `ZiskProgram::from_elf(elf)`
    3. Create: `EreZisk::new(program, ProverResource::Cpu)`
    4. Execute: `zkvm.execute(&Input::new())`
    5. Return: `(report.exit_code == Some(0), report.exit_code)`
  - Context: This is where Ere's `zkVM` trait unifies the three backends

#### Group D: CLI & Orchestration (After Group C)

- [ ] **Task #5**: Implement `runner.rs` and `main.rs`
  - File: `act4-runner/src/runner.rs`
    - `pub fn run_tests(kind: ZkvmKind, elf_dir: &Path, jobs: usize) -> Vec<TestResult>`
    - Discover `*.elf` files, sort alphabetically
    - Rayon thread pool with `jobs` threads
    - RAM-aware default for Zisk: `(avail_mb * 80 / 100) / 8192`, clamped 1..24
  - File: `act4-runner/src/main.rs`
    - CLI:
      ```
      act4-runner --zkvm <airbender|openvm|zisk>
                  --elf-dir <path>
                  --output-dir <path>
                  --suite <name>
                  --label <label>
                  [-j <jobs>]
      ```
    - Wire: parse args → `run_tests()` → `write_results()`
    - Print: `✅ 42/47 passed` or `❌ 35/47 passed`

#### Group E: Docker Integration (After Group D)

- [ ] **Task #6**: Integrate act4-runner into Docker test images
  - Build: `cargo build --release -p act4-runner`
  - Dockerfiles (`docker/{airbender,openvm,zisk}/Dockerfile`):
    ```dockerfile
    COPY act4-runner /act4/act4-runner
    ```
  - Entrypoints (`docker/{airbender,openvm,zisk}/entrypoint.sh`):
    Replace `run-dut.sh` creation + `run_tests.py` invocation with:
    ```bash
    /act4/act4-runner \
        --zkvm ${ZKVM} \
        --elf-dir "$ELF_DIR" \
        --output-dir /results \
        --suite "act4${SUFFIX}" \
        --label "$FILE_LABEL" \
        -j "$JOBS"
    ```
    Keep ACT4 config generation, make compile, and patch_elfs.py unchanged.

## Open Questions

1. **Airbender `run` vs `run-with-transpiler`**: Should Ere's SDK permanently switch to `run-with-transpiler`, or support both via a config flag? The transpiler path is what ACT4 needs and what production uses. `run` may be a legacy/debug path.

2. **OpenVM exit code extraction**: Does `SdkError` from `sdk.execute()` carry the guest exit code from the custom halt opcode (0x0b with imm=0/1)? Needs investigation. If not, act4-runner may need to bypass Ere and call the OpenVM binary directly for this backend.

3. **Ere dependency weight**: Depending on `ere-airbender`, `ere-openvm`, `ere-zisk` pulls in heavy SDK dependencies. Consider: should act4-runner use Ere only for airbender/zisk (which shell out anyway) and call OpenVM's binary directly? Or accept the compile time?

4. **ELF patching**: Currently done by `patch_elfs.py` before execution. Should this remain a separate step, or should act4-runner incorporate patching? Recommendation: keep separate — patching is a build-time concern, not an execution concern.

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
- Tasks should be run in parallel, unless there are dependencies, using subtasks

### Verification

1. **Ere patches compile**: `cargo build -p ere-airbender -p ere-openvm -p ere-zisk`
2. **act4-runner compiles**: `cargo build -p act4-runner`
3. **Bit-for-bit result comparison**: Run old pipeline and new act4-runner on same pre-patched ELFs, diff JSON
4. **Per-ZKVM smoke test**: One known-pass and one known-fail ELF per backend
5. **Parallelism**: `-j 1` vs `-j N` produce identical results

### Progress Tracking
The checkboxes above represent the authoritative status of each task.
