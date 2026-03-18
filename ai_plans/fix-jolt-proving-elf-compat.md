# Fix Jolt Proving ELF Compatibility Implementation Plan

## Executive Summary

> **Problem**: Jolt's prover crashes during preprocessing when proving ACT4 self-checking ELFs. The root cause is that ACT4's SELFCHECK mechanism embeds `.dword` pointer values (string pointers for diagnostic output) directly in `.text` sections after `jal failedtest_*` calls. Jolt's static decoder (`tracer::decode()`) pre-scans ALL bytes in `.text` linearly, treating every 2-byte boundary as a potential instruction. These pointer values aren't valid RISC-V instructions, causing decode failures that cascade into a panic during `Program::decode()` → prover preprocessing.
>
> **Solution**: Apply the existing `patch_elfs.py` tool (already used for SP1/Pico/OpenVM) to jolt's ELFs inside the Docker container after generation. This replaces data words in executable sections with NOPs (`addi x0, x0, 0`). The data words are unreachable during execution (they follow unconditional `jal` instructions), so replacing them with NOPs is semantically safe.
>
> **Technical approach**: Add a `COPY` of `patch_elfs.py` into the jolt Docker image and invoke it in `entrypoint.sh` after ELF generation but before copying to `/elfs/`. This is identical to the proven pattern used by SP1, Pico, and OpenVM Docker images.
>
> **Expected outcome**: Jolt proving succeeds for all passing ACT4 tests. The dashboard's Prove and Verify columns populate for jolt.

## Goals & Objectives

### Primary Goals
- Jolt proving works for all ACT4 tests that pass execution (currently 64/72 target, 116/119 native)
- Dashboard at localhost:8000 shows Prove and Verify results for jolt

### Secondary Objectives
- Consistent with existing patch approach used by SP1/Pico/OpenVM
- No changes to jolt's codebase — all fixes in the test infrastructure

## Solution Overview

### Approach

The fix adds one step to the jolt Docker entrypoint: after generating ELFs and before copying them to `/elfs/`, run `patch_elfs.py` to replace data-words-in-text with NOPs. This is the exact same approach used for SP1/Pico/OpenVM.

### Key Components

1. **`docker/jolt/Dockerfile`**: Copy `patch_elfs.py` into the image
2. **`docker/jolt/entrypoint.sh`**: Run `patch_elfs.py` after ELF generation

### Data Flow

```
ACT4 framework (uv run act)
    ↓
Raw ELFs with .dword pointers in .text
    ↓
patch_elfs.py (replaces data words with NOPs)
    ↓
Clean ELFs (all words in .text are valid instructions)
    ↓
cp -rL to /elfs/{native,target}
    ↓
Host: act4-runner → jolt-emu (execute) → jolt-prover (prove/verify)
```

### Expected Outcomes
- `jolt-prover prove <elf>` succeeds for ACT4 ELFs that pass execution
- `jolt-prover prove <elf> --verify` produces and verifies proofs
- Dashboard shows prove/verify counts for jolt's target suite
- No regressions in execution results (116/119 native, 64/72 target)

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. **NO PLACEHOLDER CODE**: Every implementation must be production-ready.
2. **CROSS-DIRECTORY TASKS**: Related Docker + entrypoint changes stay together.
3. **COMPLETE IMPLEMENTATIONS**: Each task must fully implement its feature.

### Visual Dependency Tree

```
docker/jolt/
├── Dockerfile          (Task #0: Add COPY for patch_elfs.py)
├── entrypoint.sh       (Task #0: Add patch step after ELF generation)
│
docker/shared/
└── patch_elfs.py       (No changes — already works for this use case)
```

### Execution Plan

#### Group A: Docker + Entrypoint Fix (Single Task)

- [x] **Task #0**: Add ELF patching to jolt Docker pipeline
  - **Folder**: `docker/jolt/`
  - **Files**: `Dockerfile`, `entrypoint.sh`
  - **What to do in `Dockerfile`**:
    - Add `COPY docker/shared/patch_elfs.py /act4/patch_elfs.py` after the existing `COPY docker/jolt/entrypoint.sh` line
    - Add `RUN chmod +x /act4/patch_elfs.py` (same pattern as entrypoint.sh)
  - **What to do in `entrypoint.sh`**:
    - In the `generate_elfs()` function, after the `uv run act` call and the ELF count check, add:
      ```bash
      echo "=== Patching ELFs for $CONFIG_NAME (replacing data words with NOPs) ==="
      python3 /act4/patch_elfs.py "$ELF_DIR"
      ```
    - This must go BEFORE the ELF-only mode copy (`cp -rL`) and BEFORE the legacy mode test execution
    - Place it right after the `echo "=== Generated $ELF_COUNT ELFs for $CONFIG_NAME ==="` line
  - **Context**: `patch_elfs.py` uses `riscv64-unknown-elf-readelf` and `riscv64-unknown-elf-objdump` (both already installed in the image at `/opt/riscv64/bin/`) to find `.word` directives in executable sections and replace them with NOP (`0x00000013`). The data words are `.dword` pointers placed by ACT4's SELFCHECK macro after `jal failedtest_*` calls — they're unreachable during execution.
  - **Verification**: Rebuild image, regenerate ELFs, run `./run test jolt` — execution results should be unchanged (116/119, 64/72). Then prove one ELF manually: `binaries/jolt-prover prove test-results/jolt/elfs/target/rv64i/I/I-add-00.elf --verify`

#### Group B: Integration Test (After Group A)

- [ ] **Task #1**: Full integration test with proving
  - **Steps**:
    1. Rebuild Docker image: `docker build -t jolt:latest -f docker/jolt/Dockerfile .`
    2. Regenerate ELFs: `FORCE=1 ./run test jolt` (with `jolt-prover` in `binaries/`)
    3. Verify execution results unchanged: 116/119 native, 64/72 target
    4. Verify proving results appear in `test-results/jolt/summary-act4-standard-isa.json` (should have `proved`, `prove_failed`, `verified`, `verify_failed` fields)
    5. Verify dashboard at localhost:8000 shows Prove and Verify columns for jolt
  - **Context**: The act4-runner auto-detects `binaries/jolt-prover` and enables proving for the target suite. Native suite always runs execute-only.
  - **Expected timing**: Each proof takes ~2-60s depending on test complexity. 64 passing target tests × average ~10s = ~10 minutes total.

---

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Sync Tasks**: Create TodoWrite tasks matching the checkboxes below
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

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.
