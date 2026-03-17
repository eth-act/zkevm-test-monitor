# Execution → Proving Migration Notes

Extracted from the aborted airbender experiment (2026-03-10).
Goal: accelerate a similar effort for **zisk** using the **ere stack** and unmodified zisk.

## What Changed (Summary)

The migration converted the test pipeline from "run ELF in emulator, check exit code" to
"generate proof of execution, extract pass/fail from proof artifacts". Key areas:

### 1. act4-runner: New Rust Test Harness

Replaced the inline bash/Python test execution + result parsing with a standalone Rust binary.

**Architecture:**
- `main.rs` — CLI: `--zkvm`, `--binary`, `--elf-dir`, `--output-dir`, `--suite`, `--label`, `-j`, `--gpu`, `--proof-output-dir`
- `backends.rs` — One function per ZKVM to invoke the binary and determine pass/fail
- `runner.rs` — Discovers ELFs, runs in parallel via rayon
- `results.rs` — Writes `summary-act4-{label}.json` + `results-act4-{label}.json`
- `elf_utils.rs` — objcopy wrappers (flat binary, ROM-only binary)

**Key design decisions:**
- Each backend is a simple function: takes binary path + ELF path → `(passed, exit_code)`
- `RunResult` has optional `prove_duration` and `proof_written` fields for proving backends
- Jobs auto-tuning per ZKVM (memory-based for zisk, GPU=1 for prove, nproc for others)
- Results JSON format matches what `src/test.sh` already expects

**Zisk backend** (`run_zisk`): just `Command::new(binary).arg("-e").arg(elf_path)` — exit code 0 = pass.

### 2. Split Pipeline for Proving (Airbender-Specific)

Airbender needed a 2-phase approach because proving requires GPU on the host:
1. **Docker phase**: Sail + GCC compile ACT4 tests → ELFs mounted to `/elfs`
2. **Host phase**: `act4-runner --zkvm airbender-prove` runs `airbender-cli prove` with `--gpu`

This split is airbender-specific. Zisk proving can likely run inside Docker or host-side
depending on ere stack requirements.

### 3. Linker Script Changes (Airbender-Specific)

Changed to ROM/RAM split layout for airbender's prove mode:
- Code at 0x0 (ROM), data VMA at 0x200000 (RAM) with LMA in ROM
- `RVMODEL_BOOT` copies .data from ROM→RAM at startup (`#ifdef RVTEST_SELFCHECK`)
- New `.exit_seq` and `.exit_data` sections for airbender's exit sequence convention

**For zisk**: Linker script likely stays the same (zisk already has its own memory map with
data in 0xa0000000-0xc0000000 range).

### 4. rvmodel_macros.h Changes (Airbender-Specific)

Replaced HTIF tohost/fromhost with airbender's native EXIT_SEQUENCE pattern:
- 17 `.word` instructions that load registers from memory region pointed to by s10
- Pass/fail signaled via register a0 (x10): 0 = pass, non-zero = fail
- Proof reads `register_final_values[10]` from `recursion_program_proof.json`

**For zisk**: The exit mechanism stays the same (ecall a7=93). The question is how the
ere prover reports pass/fail — need to find the equivalent of reading registers from proof.

### 5. entrypoint.sh Simplification

Removed ~80 lines of bash/Python result parsing per ZKVM. The entrypoint now either:
- (airbender) Just generates ELFs and copies them to mount
- (openvm/zisk) Calls `act4-runner` binary instead of `run_tests.py` + inline Python

### 6. src/test.sh Refactoring

- Extracted `process_results()` function for history JSON updates (shared)
- Airbender gets special `run_airbender_prove()` function with 2-phase pipeline
- Other ZKVMs keep the existing Docker-runs-everything approach but use act4-runner inside
- Auto-builds act4-runner if source is newer than binary

## Key Patterns for Zisk Migration

### What's Reusable As-Is
- `act4-runner` crate structure (already has `run_zisk` backend)
- `results.rs` JSON output format
- `runner.rs` parallel execution
- `process_results()` in test.sh

### What Needs New Work for Zisk+ere
1. **New backend**: `run_zisk_prove` in backends.rs — invoke ere prover with ELF
2. **Pass/fail extraction**: How does ere report execution results? Register dump? Exit code? JSON?
3. **Pipeline decision**: Does ere proving need host GPU (like airbender) or can it run in Docker?
4. **Memory/job tuning**: Zisk already has 8GB-per-instance heuristic; ere proving may differ
5. **entrypoint.sh**: Either call act4-runner inside Docker (if proving in Docker) or split pipeline

### Questions to Answer Before Starting
- What is the ere CLI interface? (binary name, args for proving an ELF)
- How does ere report pass/fail from a proof? (JSON output? exit code? register values?)
- Does ere need GPU? Special hardware?
- Can ere work with standard zisk ELFs or does it need modified linker scripts?
- Does ere need the zisk binary at all, or does it replace it entirely?
