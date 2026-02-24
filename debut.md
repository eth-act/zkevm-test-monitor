# ACT4 Test Suite — Debut Notes

## Background: what changed from RISCOF

The old test suite used **RISCOF**, which works by:
1. Compiling a test to a RISC-V binary
2. Running it on the VM and extracting a *memory signature* (a dump of a specific memory region written by the test)
3. Running the same test on a reference model (Sail) and comparing signatures

This required each VM to implement signature extraction — a custom `--signatures` flag, ELF symbol parsing for `begin_signature`/`end_signature`, and precise memory readback. It also imposed a specific memory layout on the VM (where the signature region lives). Writing a RISCOF plugin was non-trivial.

**ACT4** replaces this with *self-checking ELFs*. The key insight is that Sail is run at *compile time*, not test time. When the test suite is built, each test is first run through the Sail RISC-V reference model to compute what the correct output values should be. Those expected values are then compiled directly into the ELF as constant data. At runtime, the ELF runs on the VM under test, computes its own outputs, compares them against the embedded expected values, and calls the pass or fail halt macro itself. The test runner just runs the ELF and checks the exit code: 0 (pass) or 1 (fail). No signature extraction, no reference model at test time, no special memory layout required from the VM.

---

## Minimum required infrastructure per VM to just check the emulators

To integrate a VM with ACT4 you need exactly one thing:

> **A way to execute a RISC-V ELF without ZK proving and exit with the guest's exit code.**

That's it. No signature logic, no custom linker script constraints, no memory region requirements.

In practice this usually means adding a flag like `--execute-only` / `--executor-mode simple` / `run --exe <elf>` that skips proof generation and exits with the guest's return code. Every VM we looked at already had an execution-without-proving path — it just needed to be exposed and wired to the process exit code.

Bonus: it'll be easier to upgrade these test to do proving and verification. Maybe I should do that actually before upstreaming.

---

## What we actually had to change, per VM

**jolt, zisk, pico — zero VM changes.**
These three run tests purely with upstream binaries. All that was needed was a DUT config (linker script, halt macros, Sail reference config) and a Docker entrypoint.

**r0vm (risc0) — ~15 lines.**
Added a single `--execute-only` flag to `r0vm/src/lib.rs`. Without it, r0vm always attempted ZK proving after execution. The flag reads the guest's `ExitCode` and calls `std::process::exit(code)`.

**sp1 — 1 small fix.**
The `sp1-perf-executor` binary has a dependency on SP1's custom Rust toolchain; commented that out so it builds with standard Rust. That's the entire diff.

Earlier there was also a change to the ELF loader to strip trailing zero words. This turned out to be unnecessary: the test framework's `patch_elfs.py` preprocessing step (called before any VM execution) already replaces zero words in executable sections with NOPs — `objdump -d` renders them as `.word 0x0`, which `patch_elfs.py` catches. The ELF loader change was reverted.

**openvm — one functional change.**
The only real change was wiring `cargo-openvm run --exe <elf>` to load a RISC-V ELF and return the guest exit code, using a minimal RV32IM config (rv32i + rv32m + io). An earlier version of the fork also included a Zicsr transpiler and RV32F crates from exploratory float extension work. These were removed: all CSR instructions in ACT4 test preambles are gated behind `#ifdef rvtest_mtrap_routine`, which we don't set, so no CSR instructions appear in RV32IM test ELFs.

**airbender — one new command.**
Added `run-with-transpiler`: loads a flat binary at a given entry point, runs it through the prover execution path (`preprocess_bytecode` + `VM::run_basic_unrolled`), polls the HTIF tohost address, and exits 0/1/2. Also changed the instruction decoder to emit `Illegal` markers instead of panicking when it sees non-instruction words (data sections appear in the flat binary since objcopy concatenates everything). The `Illegal` instruction panics only if the PC actually reaches it at runtime.

---

## Current results

### Native ISA suite (RV32IM, 47 tests for RV32 VMs; RV64IM + extensions, 119 tests for RV64 VMs)

| VM        | Passed | Total | Failures |
|-----------|--------|-------|----------|
| sp1       | 47     | 47    | — |
| pico      | 47     | 47    | — |
| r0vm      | 47     | 47    | — |
| openvm    | 47     | 47    | — |
| jolt      | 116    | 119   | sc.d, sc.w (store-conditional); c.slli |
| zisk      | 235    | 239   | c.jalr, c.jr (wrong result); c.fldsp, c.fsdsp (crash) |
| airbender | 42     | 47    | fence; div, rem, mulh, mulhsu |

### ETH-ACT target suite (RV64IM_Zicclsm, 72 tests — the Ethereum target profile)

| VM        | Passed | Total | Notes |
|-----------|--------|-------|-------|
| zisk      | 72     | 72    | ✓ |
| jolt      | 64     | 72    | All 8 misaligned-access tests fail |
| sp1       | 0      | 72    | RV32 only — expected |
| pico      | 0      | 72    | RV32 only — expected |
| r0vm      | 0      | 72    | RV32 only — expected |
| openvm    | 0      | 72    | RV32 only — expected |
| airbender | 0      | 72    | RV32 only — expected |

### Zisk RVI20 profile (259 tests)

| VM   | Passed | Total | Failures |
|------|--------|-------|----------|
| zisk | 255    | 259   | same 4 as native: c.jalr, c.jr, c.fldsp, c.fsdsp |

---

## Notable failures worth digging into

**Jolt — sc.d / sc.w (store-conditional)**
LR (load-reserved) passes but SC (store-conditional) fails. This suggests the reservation mechanism isn't implemented correctly — LR sets a reservation but SC doesn't honour it.

**Jolt — c.slli**
Compressed shift-left-logical-immediate fails. Either the compressed instruction decoder or the shift itself has a bug.

**Jolt — all 8 Misalign tests**
The ETH-ACT target profile (RV64IM_Zicclsm) requires `Zicclsm` — support for misaligned loads/stores in hardware. Jolt appears to trap or panic on unaligned accesses rather than handling them transparently.

**Zisk — c.jalr / c.jr (exit 1, wrong result)**
These are compressed indirect-jump instructions. The VM runs and exits cleanly but produces a wrong result, suggesting a bug in the C-extension jump decoding or PC update.

**Zisk — c.fldsp / c.fsdsp (exit 101, crash)**
These are compressed double-precision float stack-pointer-relative load/store instructions. The crash (exit 101 = Rust panic) suggests these aren't implemented at all.

**Airbender — fence**
FENCE instruction not implemented. Probably a single-line fix.

**Airbender — div, rem, mulh, mulhsu**
These four M-extension instructions are unimplemented. The basic multiply (mul, mulw) passes; only the high-word and division variants are missing.

---

## Why this is easier than RISCOF for new integrations

With RISCOF, integrating a new VM required:
- Writing a Python plugin class with `runTests()` and `build()` methods
- Implementing signature extraction in the VM (or wrapping it)
- Getting the memory layout right (entry point, signature region address, tohost)
- Debugging signature format mismatches

With ACT4, integrating a new VM requires:
- A shell one-liner that runs the ELF and exits with the guest code
- A YAML config declaring the ISA profile
- A linker script and `rvmodel_macros.h` defining the halt convention

The halt convention is the only VM-specific piece. For most VMs it's a single ecall (`ecall` with a7=93, or a custom opcode, or whatever the VM uses to terminate). Once that's right, every test in the suite just works.
