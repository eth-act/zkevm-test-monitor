# Jolt Proving Debug Notes (2026-03-18)

## Problem
Jolt prover generates proofs for ACT4 ELFs but verification fails at Stage 4 (RAM value checking) with `SumcheckVerificationError`. This happens for ALL non-jolt-sdk ELFs, including a 1-instruction `j .` bare-metal program.

## Infrastructure (WORKING)
- Split pipeline: Docker ELF gen → host execution + proving via act4-runner
- `jolt-prover` CLI at `jolt/tools/jolt-prover/` wraps jolt-core prove/verify API
- `patch_elfs.py` replaces data-in-text words with NOPs (required to prevent INLINE opcode panic)
- `rvmodel_macros.h` changed from `j write_tohost_pass` (3-instr loop) to `j .` (1-instr self-loop) so tracer terminates via PC stall
- Auto-detect trace length: traces ELF first, sets max_trace_length to next power of 2
- Execution results: 116/119 native (was 108 after j . change — 8 Zaamo.d regressions need investigation), 64/72 target

## Key Files Modified
- `jolt/tools/jolt-prover/Cargo.toml` + `src/main.rs` — new prover CLI binary
- `jolt/Cargo.toml` — added `tools/jolt-prover` to workspace
- `act4-runner/src/backends.rs` — `Jolt` and `JoltProve` backends
- `act4-runner/src/main.rs` — `--jolt-prover` arg, `jolt`/`jolt-prove` match arms
- `act4-runner/src/runner.rs` — `jolt-prove` job tuning (~16GB/instance)
- `docker/build-jolt/Dockerfile` — builds both jolt-emu and jolt-prover
- `docker/jolt/Dockerfile` — COPY patch_elfs.py into image
- `docker/jolt/entrypoint.sh` — ELF-only mode (/elfs mount), removed stale `make` step, added patch step, `cp -rL` for dereferencing symlinks
- `src/build.sh` — jolt special-case extraction (both binaries), container cleanup
- `src/test.sh` — `run_jolt_split_pipeline()`, auto-detect jolt-prover
- `act4-configs/jolt/*/link.ld` — moved `.tohost` after `.text` for contiguous code sections
- `act4-configs/jolt/*/rvmodel_macros.h` — `j .` halt instead of 3-instr tohost loop

## What We've Verified (ALL PASS)
1. **RAM trace consistency** — every read/write pre_value matches expected from init state + prior writes (0 errors across 4352 cycles)
2. **Initial RAM state match** — prover and verifier compute identical initial states (0 mismatches across 16384 entries)
3. **eval_initial_ram_mle correctness** — sparse block evaluation matches dense polynomial evaluation at random points
4. **Fiat-Shamir transcript** — `#[cfg(test)]` compare_to shows prover/verifier use identical randomness
5. **Opening accumulator** — `#[cfg(test)]` compare_to shows consistent polynomial claims
6. **Prover internal sumcheck** — `#[cfg(test)]` H(0)+H(1)==claim assertion passes at every round for I-add-00 (4352 cycles). Note: FAILS for minimal 1-instr ELF at Stage 6 round 4.

## Failure Details
- **Stage 4** has 2 instances: `RegistersReadWriteCheckingVerifier` + `RamValCheckSumcheckVerifier`
- `output_claim != expected_output_claim` at `sumcheck.rs:474`
- For I-add-00: prover's internal sumcheck passes (no #[cfg(test)] assertion fires), but verifier rejects
- For minimal.elf: prover's own sumcheck fails at Stage 6 (BytecodeReadRaf) round 4

## Where to Investigate Next
The **OutputSumcheckProver/Verifier** in Stage 2 establishes `val_final_claim` which Stage 4's RamValCheck references. The output check (`ram/output_check.rs:225-226`) computes `io_start` and `io_end` from the memory layout and masks the I/O region of the final state. If our program writes to addresses within this mask unexpectedly, the output claim will be wrong, causing Stage 4 to fail.

Specifically:
- `io_start = remap_address(memory_layout.input_start, memory_layout)`
- `io_end = remap_address(RAM_START_ADDRESS, memory_layout)`
- The mask covers `io_start..io_end` in the final state
- For our config: io_start corresponds to 0x7FFF8000, io_end to 0x80000000

Our ACT4 ELF writes to `.tohost` at 0x80008000 which is ABOVE io_end. So it should be outside the mask. But verify this.

Also investigate: does the `OutputSumcheckProver` at `output_check.rs:197-249` (prover side) produce the same `val_io` polynomial as what the verifier expects? The prover uses the actual `final_ram_state` while the verifier reconstructs from `eval_io_mle`. Compare these.

## ELF Patching
- `patch_elfs.py` replaces `.word`/`.dword` data in executable sections with NOP (0x00000013)
- Required because: ACT4 SELFCHECK embeds .dword pointers after `jal failedtest_*` calls in .text; data words with opcode 0x2b (0b0101011) decode as INLINE instructions which panic in inline_sequence()
- UNIMPL instructions (from other invalid opcodes) return empty vec from inline_sequence() — safe
- The NOPs are in the bytecode table but never executed — this is fine, jolt handles dead code

## Linker Script
Original: `.text.init` → `.tohost` (gap) → `.text` — non-contiguous code with data in between
Fixed: `.text.init` → `.text` → `.tohost` → `.data` — contiguous code, data after
Both fail verification — the gap wasn't the root cause.

## Halt Mechanism
- jolt-emu uses `run_test()` which checks `tohost` write on every tick
- jolt tracer uses `step_emulator()` which only checks PC stall (`prev_pc == pc`)
- Original ACT4 halt: `sw x1,0(t0); sw x0,4(t0); j write_tohost_pass` — 3-instr loop, never stalls
- Fixed halt: `sw x1,0(t0); sw x0,4(t0); j .` — writes tohost then self-loops for PC stall
- The `j .` fix resolved the infinite trace / OOM issue

## Jolt Debug Infrastructure
- `ProverDebugInfo` (test-only): captures transcript + opening accumulator for comparison
- `#[cfg(test)]` sumcheck assertion: `sumcheck.rs:130-141` checks H(0)+H(1)==claim per round
- `#[cfg(test)]` transcript comparison: `verifier.rs:290-296` via blake2b state_history
- `#[cfg(test)]` opening comparison: `opening_proof.rs:740-742`
- `assert_constraints_first_group/second_group` in `r1cs/evaluation.rs` — row-level R1CS check (test-only)
- `VerifierR1CS::check_satisfaction` in `blindfold/r1cs.rs` — full R1CS satisfaction check (ZK mode only)
- `RUST_LOG=debug` enables tracing spans (45+ in codebase)
- Stage error logging: `verifier.rs:369-390` via `inspect_err`

## Cycle Count Validation
- jolt-emu disassembly: ~4323 instructions for I-add-00
- Tracer auto-detect: 4352 cycles
- Prover internal (gen_from_elf): "4324 raw RISC-V + 28 virtual = 4352 total cycles"
- proof.trace_length: 8192 (padded to next power of 2)
- All consistent — prover IS executing the real program

## Critical Finding (2026-03-18 03:00)
**jolt-prover CLI successfully proves and verifies the fibonacci guest ELF!**
This proves our code path (guest::program::Program, gen_from_elf, JoltVerifierPreprocessing::from) is CORRECT.
The issue is specific to ACT4 ELF content, not our prover setup.

Fib guest: 447 cycles, prove 0.4s, verify 0.1s, EXIT 0.
ACT4 I-add-00: 4352 cycles, prove 0.6s, verify FAILS Stage 4.

Next: bisect what ACT4 ELF feature causes the failure. Candidates:
- Multiple .text sections (.text.init + .text.rvtest) vs single .text
- Data words patched to NOPs in .text
- .tohost section (writable data in program region)
- Larger .data section with signature values
- Different entry point / boot sequence


## Further Finding (2026-03-18 03:05)
- Fib guest ELF proves+verifies through our jolt-prover CLI — code is correct
- Minimal ACT4-like ELF (no data-in-text, contiguous .text, simple program) STILL fails
- NOP patching is NOT the cause
- Linker script gap is NOT the cause
- MemoryConfig is NOT the cause (tried default and zero)
- Fib guest writes to RAM (stack stores via sd) and it works fine
- The difference must be in the ELF compilation target or boot code
- Fib uses riscv64imac-unknown-none-elf target with jolt-platform boot code
- Our ELF uses plain riscv64-unknown-elf-gcc without jolt-platform
- Boot code sets gp, sp, calls init functions, includes CSR setup
- **Hypothesis**: jolt-platform boot code writes to I/O region (termination/panic) or initializes memory in a way the prover circuit expects

## Ruled Out (2026-03-18)
- jolt-platform boot code does NOT write to I/O/termination — only `j .` for exit
- Termination bit is set by prover convention (gen_ram_memory_states:736), never by trace — same for jolt-sdk guests and ACT4
- JoltDevice.store() silently drops writes to termination address (line 92)
- No writes below RAM_START_ADDRESS in ACT4 trace (verified: below_ram=0, io_writes=0)
- Write range for I-add-00: only 0x80008000 (tohost)
- ELF headers match (same flags 0x1 RVC soft-float, same entry 0x80000000)
- R1CS constraints pass (#[cfg(test)] assert_constraints didn't fire)
- RAM trace valid (0 errors, pre_values match)
- init states match (0 mismatches)
- eval_initial_ram_mle matches dense evaluation
- Transcripts match, opening accumulators match

## Next Step
Compile a minimal guest using jolt's actual build system (`jolt build` / `#[jolt::provable]`) but with trivial logic (e.g., return constant), then compare its ELF structure with our gcc-compiled mini_act4.elf. The key difference is likely in the compilation target (riscv64imac-unknown-none-elf) or jolt-platform linkage, not the program logic. If a jolt-built trivial guest proves and a gcc-built equivalent doesn't, the issue is in the ELF format/sections/symbols produced by the different toolchains.


## Session 2 Findings (2026-03-18 afternoon)
- Tried building a jolt guest with #[jolt::provable] + inline asm — build system complexity prevented quick test
- jolt guests use ZeroOS boot code, custom linker template with explicit PHDRS/MEMORY
- Our gcc-compiled ELF had LOAD segment starting at 0x7FFFF000 (below RAM) — fixed with explicit PHDRS but STILL FAILS
- The PHDR fix doesn't matter because tracer::decode() uses section addresses, not segment addresses
- jolt linker template: MEMORY { RAM (rwx) : ORIGIN = 0x80000000 }, explicit PHDRS for text/rodata/data/tls
- Our ELF with same PHDRS pattern still fails

## Root Cause Hypothesis
The issue is NOT in:
- Program headers / LOAD segments
- Memory layout / MemoryConfig
- NOP patching
- Linker script gaps
- I/O region writes
- Termination bit
- Initial RAM state
- Fiat-Shamir transcript
- Opening accumulator
- R1CS constraints

The issue IS specific to ELFs not built through jolt's toolchain. The fib guest ELF proves through our exact code path. A gcc-built ELF with identical logic does not.

Remaining suspects:
1. Something in jolt's target spec (riscv64imac-unknown-none-elf) that affects code generation
2. The ZeroOS boot code initializes some state the prover circuit relies on
3. The custom linker script template places sections/symbols in a way the circuit expects
4. The stripped symbols in jolt guests affect how tracer::decode() processes the ELF

## Recommended Next Steps  
1. Get `jolt build` working for our test guest to produce a provable ELF
2. Take that ELF and gradually strip jolt-specific features until it fails — bisect the exact requirement
3. Or: take the fib guest ELF, modify its .text section with our test code, and re-prove

## BREAKTHROUGH (2026-03-18 14:50)
**Jolt boot code is REQUIRED for proving.** Verified by:
1. Working trivial guest ELF (return 0) with boot code: PROVES ✓
2. Same ELF with .text replaced by our code + NOPs: FAILS ✗
3. Same ELF with boot code intact + our code patched at j . termination: PROVES ✓

The boot code runs ~294 cycles (226 raw RISC-V instructions) of ZeroOS initialization
before reaching user code. This init includes:
- Setting gp (global pointer)
- Setting sp (stack pointer)
- Calling __platform_bootstrap (heap init, zeroos::initialize)
- 43 store instructions (heap zeroing)
- CSR setup (if std mode)

**The prover circuit requires the jolt-platform boot sequence.** Without it, Stage 4
(RAM value checking) fails because the circuit expects specific memory initialization
patterns that only the boot code provides.

## Path Forward for ACT4 ELFs
Option A: Compile ACT4 tests as jolt guests using #[jolt::provable] + inline asm
Option B: Prepend jolt boot code stub to ACT4 ELFs before proving
Option C: Figure out exactly what the boot code initializes and replicate it in ACT4 linker/macros
