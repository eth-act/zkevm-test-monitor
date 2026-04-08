# Jolt Fork Analysis

_2026-04-08_

## Fork Details

- **Fork**: `codygunton/jolt` (branch: `main`)
- **Upstream**: `a16z/jolt` (branch: `main`)
- **Merge base**: `2e05fe88`
- **Fork-only commits** (2 total):
  - `56c21558` feat: add jolt-prover CLI and act4-test example guest
  - `3adde10f` feat: add trace subcommand to jolt-prover

## What the Fork Adds

The fork adds `tools/jolt-prover/`, a CLI that wraps Jolt's library API to prove/verify arbitrary ELFs:

```bash
jolt-prover trace <elf>                    # execute (exit 0 = pass)
jolt-prover prove <elf> -o <dir>           # generate proof
jolt-prover prove <elf> --verify           # verify proof
```

Under the hood it calls:
- `Program::new(&elf_contents, &memory_config)` to load the ELF
- `RV64IMACProver::gen_from_elf()` + `.prove()` to generate proofs
- `RV64IMACVerifier::new()` + `.verify()` to verify

**Upstream does NOT have a CLI for proving arbitrary ELFs.** Their workflow is SDK-based: write Rust code with `#[jolt::provable]`, which auto-generates host-side `prove_*()` / `verify_*()` functions.

## Termination Semantics: No Fork Needed

Upstream Jolt uses **PC stall detection** (`prev_pc == pc`) as its canonical termination mechanism. From `jolt-platform/src/exit.rs`:

```rust
pub extern "C" fn platform_exit(_code: i32) -> ! {
    unsafe { core::arch::asm!("j .", options(noreturn)); }
}
```

Upstream's emulator (`tracer/src/emulator/mod.rs` `run_test()`) detects both:
1. **PC stall** — `j .` infinite loop (the Jolt way)
2. **tohost** — reads `tohost` symbol from ELF symbol table, checks HTIF write

Our ACT4 halt macro (`act4-configs/jolt/*/rvmodel_macros.h`) does both:
```asm
sw x1, 0(t0)    ; write to tohost
sw x0, 4(t0)
j .              ; infinite loop
```

So termination works with upstream out of the box.

## Jolt Proving Architecture

Jolt uses a **host/guest split**:
- **Guest**: compiles to a plain RISC-V ELF (RV64IMAC). Does not produce proofs.
- **Host**: a separate Rust program loads the ELF and calls Jolt's proving API.

Standard SDK flow:
1. Guest function marked `#[jolt::provable]` compiles to ELF
2. Macro generates host functions: `compile_*()`, `preprocess_*()`, `build_prover_*()`, `build_verifier_*()`
3. Host calls `prove_fn(inputs)` which traces the ELF and returns `(output, RV64IMACProof, JoltDevice)`
4. Host calls `verify_fn(inputs, output, proof)` which returns `bool`

## Boot Code Requirement for Proving

Jolt's prover circuit expects ZeroOS boot code (~294 cycles of heap init, CSR setup) to have executed first. Plain ELFs without boot code fail at Stage 4 Sumcheck verification.

Our Docker ELF generation pipeline handles this:
1. `patch_elfs.py` — replaces data words in `.text` with NOPs (jolt panics on non-instruction bytes)
2. `wrap_boot.py` — injects `boot.bin` (ZeroOS boot blob) at `0x80100000`, patches entry point to go through boot trampoline, then jumps to `rvtest_entry_point`

This wrapping happens in the Docker image during ELF generation, not in the fork.

## Options for Eliminating the Fork

1. **Execution-only (no fork needed)**: Use upstream's `jolt-emu` (`cargo build -p tracer --bin jolt-emu`). Handles both PC stall and tohost termination. Full ISA and standard ISA tests work.

2. **Add Jolt as a library dep to act4-runner**: Call `RV64IMACProver::gen_from_elf()` directly. Eliminates fork CLI but adds a heavyweight dependency and version coupling.

3. **Upstream the CLI**: PR `tools/jolt-prover/` to `a16z/jolt`. Small, useful tool.

For immediate CI (execution-only), option 1 has zero fork dependencies. Proving can be added later via option 2 or 3.
