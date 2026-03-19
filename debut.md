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

**zisk — zero VM changes.** ([upstream](https://github.com/0xPolygonHermez/zisk) @ `b3ca745b`)
Runs tests purely with the upstream `ziskemu` binary. All that was needed was a DUT config (linker script, halt macros, Sail reference config) and a Docker entrypoint.

**openvm — zero VM changes.** ([upstream](https://github.com/openvm-org/openvm) @ `bf11b4a5`)
Upstream OpenVM SDK already exposes `CpuSdk::riscv32()` (rv32i + rv32m + io — the exact config we need) and accepts raw ELF bytes via `sdk.execute(elf_bytes, StdIn::default())`, returning `Err` on a non-zero guest exit code. A 10-line standalone Rust binary wraps this API and produces an executable that takes an ELF path and exits 0/1. No fork needed.

**jolt — fork, ~two new crates.** ([codygunton/jolt](https://github.com/codygunton/jolt) @ `3adde10f`)
The upstream `jolt-emu` binary is used for test execution with zero changes to VM emulation logic. The fork adds a `jolt-prover` CLI tool for standalone ELF proving (used for proving integration, not for the compliance results reported here).

**sp1 — fork, ~7 lines changed.** ([codygunton/sp1](https://github.com/codygunton/sp1) @ `213fc1ab`)
The upstream `sp1-perf-executor` already accepts `--program`, `--stdin`, and `--executor-mode simple`. Two changes were needed: (1) `sp1-perf-executor` was silently discarding execution errors in simple mode — the `Result` from `run_fast()` was swallowed, making every test appear to pass. Fixed by propagating the error and calling `exit(1)`. (2) The `sp1-perf` crate lists `test-artifacts` as a dependency requiring SP1's custom `succinct` Rust toolchain; commented out since `sp1-perf-executor` doesn't use it.

**pico — fork, ~16 lines changed.** ([codygunton/pico](https://github.com/codygunton/pico) @ `e4d8f22d`)
The upstream `cargo-pico test-emulator` had the same issue as SP1: `test_emulator()` always returned `Ok(())` regardless of whether the guest halted with a non-zero exit code. Changed the return type to propagate the exit code and call `std::process::exit(code)`.

**r0vm (risc0) — fork, ~15 lines.** ([codygunton/risc0](https://github.com/codygunton/risc0), branch `act4` @ `6bc23889`)
Added `--execute-only` (skips ZK proving, exits with the guest's `ExitCode`) and `--test-elf` (accepts raw ELF format instead of `ProgramBinary`). No VM emulation logic modified.

**airbender — fork, one new command.** ([codygunton/zksync-airbender](https://github.com/codygunton/zksync-airbender), branch `riscof-dev` @ `6353d63d`)
Added `run-with-transpiler`: loads a flat binary at a given entry point, runs it through the prover execution path (`preprocess_bytecode` + `VM::run_basic_unrolled`), polls the HTIF tohost address, and exits 0/1/2. Also changed the instruction decoder to emit `Illegal` markers instead of panicking when it sees non-instruction words (data sections appear in the flat binary since objcopy concatenates everything). The `Illegal` instruction panics only if the PC actually reaches it at runtime.

---

## Current results

### Native ISA suite (tests the VM's declared ISA)

Test counts vary by declared ISA: 47 for RV32IM, 64 for RV64IM, 119 for RV64IMAC, 239 for RV64IMFDAC.

| VM        | ISA        | Passed | Total | Failures |
|-----------|------------|--------|-------|----------|
| openvm    | RV32IM     | 47     | 47    | — |
| airbender | RV32IM     | 42     | 47    | fence; div, rem, mulh, mulhsu |
| pico      | RV32IM     | 45     | 47    | fence, jalr |
| sp1       | RV64IM     | 62     | 64    | fence, jalr |
| jolt      | RV64IMAC   | 108    | 119   | 8 AMO double-word; sc.d, sc.w; c.slli |
| r0vm      | RV32IM     | 46     | 47    | fence |
| zisk      | RV64IMFDAC | 235    | 239   | c.jalr, c.jr, c.fldsp, c.fsdsp |

### Standard ISA suite (RV64IM_Zicclsm, 72 tests — the Ethereum target profile)

| VM        | Passed | Total | Notes |
|-----------|--------|-------|-------|
| sp1       | 62     | 72    | fence, jalr, 8 misaligned-access failures |
| jolt      | 64     | 72    | 8 misaligned-access failures |
| zisk      | 71     | 72    | fence |
| openvm    | 0      | 72    | RV32 only — expected |
| pico      | 0      | 72    | RV32 only — expected |
| r0vm      | 0      | 72    | RV32 only — expected |
| airbender | 0      | 72    | RV32 only — expected |

---

## Notable failures worth digging into

**fence — widespread**
The FENCE instruction fails on airbender, pico, sp1, r0vm, and zisk (standard suite only). Most ZK-VMs treat FENCE as a no-op since they execute single-threaded, but the ACT4 test may be checking that the instruction at least decodes and completes without error rather than testing memory ordering semantics.

**SP1 / Pico — jalr**
JALR (jump-and-link-register) fails on both SP1 and Pico. This is a core RV32I instruction, so the failure likely reflects an edge case in the test (e.g. specific immediate encoding or link register behaviour) rather than a fundamentally broken instruction — these VMs wouldn't boot at all without basic JALR support.

**Jolt — AMO double-word (amoadd.d, amoand.d, amomax.d, amomin.d, amominu.d, amoor.d, amoswap.d, amoxor.d)**
All 8 Zaamo double-word atomic operations fail. The 32-bit AMO variants (amoadd.w, etc.) pass, suggesting the 64-bit atomics path is unimplemented or broken. These are new failures compared to our earlier run — likely due to test suite updates.

**Jolt — sc.d / sc.w (store-conditional)**
LR (load-reserved) passes but SC (store-conditional) fails. This suggests the reservation mechanism isn't implemented correctly — LR sets a reservation but SC doesn't honour it.

These are genuinely new findings: the RISCOF arch test suite (v3.9.1, July 2024) covered the A extension only with AMO instructions — it had no LR/SC tests at all. Zalrsc test generation was added to ACT4 in December 2025 (formatter commit `4ffe77c3`, coverpoints in `89928a9d`), making this suite the first to exercise these instructions against Jolt.

**Jolt — c.slli**
Compressed shift-left-logical-immediate fails. Either the compressed instruction decoder or the shift itself has a bug.

**Jolt — all 8 Misalign tests (standard suite)**
The standard target profile (RV64IM_Zicclsm) requires `Zicclsm` — support for misaligned loads/stores in hardware. Jolt appears to trap or panic on unaligned accesses rather than handling them transparently.

**Zisk — c.jalr / c.jr**
These were previously fixed in v0.16.0-pre but the current test runs against v0.15.0 (b3ca745b). Both fail on this version.

**Zisk — c.fldsp / c.fsdsp (exit 101, crash)**
These are compressed double-precision float stack-pointer-relative load/store instructions. The crash (exit 101 = Rust panic) indicates the instructions are not implemented.

These are also genuinely new findings: the RISCOF v3.9.1 C-extension tests covered only the integer compressed subset — no Zcd tests existed. Zcd test generation was added to ACT4 in December 2025 (formatter commit `cedefca0`), making this the first test suite to exercise these instructions against Zisk. Zisk's ISA config declared full `RV64IMAFDCZ...` support, so RISCOF would have tested Zcd had the tests existed — the gap was in the test suite, not the config.

**Zisk — fence (standard suite only)**
Fence fails in the standard suite but not the native suite. This may indicate a difference in how the test is compiled for the RV64IM_Zicclsm target profile vs the native RV64IMFDAC profile.

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



## Disclosure letters

Individual letters to each ZKVM team are in the [`letters/`](letters/) directory.
