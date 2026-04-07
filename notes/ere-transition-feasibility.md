# Feasibility Study: Transitioning ACT4 Arch Test Infrastructure to Ere

## Executive Summary

The current ACT4 test pipeline is a **Docker-based, shell-orchestrated system** that compiles self-checking RISC-V ELFs and runs them against per-ZKVM binaries. Ere is a **Rust-based, trait-unified SDK** that abstracts compilation, execution, proving, and verification across 10 zkVMs. Transitioning means replacing the Docker+shell test runner with Ere's unified execution interface.

**Verdict: Feasible with significant caveats.** Ere can replace the "execute ELF on ZKVM" step, but the bulk of ACT4 complexity lives *before* that step (ELF compilation, Sail reference generation, self-checking assembly, ELF patching). Ere doesn't address those phases today.

---

## 1. What the Current Pipeline Does (and Ere's Coverage)

| Pipeline Phase | Current Implementation | Ere Coverage |
|---|---|---|
| **1. ZKVM binary build** | `docker/build-*/Dockerfile` | Ere compiles *guest programs* from Rust source, not pre-built binaries. N/A for arch tests. |
| **2. ACT4 test generation** | `uv run act <config>` → compiles .S tests with Sail reference values baked in | **None.** Ere has no concept of ACT4 configs, Sail, or self-checking ELF generation. |
| **3. ELF patching** | `patch_elfs.py` (NOP replacement for OpenVM, JAL rewrite for Zisk) | **None.** Ere's compilers produce from Rust source; they don't post-process arbitrary ELFs. |
| **4. ELF execution** | Per-ZKVM wrapper scripts invoking binaries with correct flags | **Strong match.** `zkvm.execute()` is exactly this. |
| **5. Result collection** | Shell scripts parsing stdout, writing JSON summaries | **Partial.** Ere returns exit status and cycle counts but doesn't parse ACT4-format results. |
| **6. Dashboard/history** | `src/update.py`, `data/history/` JSON files | **None.** Out of scope for Ere. |

**Key insight:** Ere replaces only phase 4 (and partially phase 5). Phases 2-3 are the hard parts and remain untouched.

---

## 2. Per-ZKVM Analysis

### 2.1 Airbender

**Current flow:**
```
ELF → objcopy → flat .bin → airbender-binary run-with-transpiler \
  --bin X --entry-point 0x1000000 --tohost-addr 0x1010000 --cycles 10000000
```

**Ere equivalent:**
Ere's `ere-airbender` does exactly this: converts ELF → binary via `rust-objcopy`, then calls `airbender-cli run-with-transpiler`. However, Ere expects a *Rust guest program* compiled through its own pipeline, not a pre-built ACT4 ELF.

**Gap:** Ere's `EreAirbender::new(program)` takes an ELF that was compiled from Rust via `Compiler::compile()`. ACT4 ELFs are compiled from assembly by `riscv64-unknown-elf-gcc` with a custom linker script. Ere would need a way to accept **pre-built ELFs** as input — bypassing the compilation step.

**Feasibility:** High. The underlying execution is identical. You'd need to either:
- Use `AirbenderSdk` directly (bypassing `Compiler` trait), or
- Implement a "passthrough compiler" that wraps pre-built ELFs

**No ELF patching needed** for Airbender — simplest case.

### 2.2 OpenVM

**Current flow:**
```
ELF → patch_elfs.py (NOP data words) → openvm-binary <elf>
```

**Ere equivalent:**
`ere-openvm` uses `CpuSdk::new()` with a transpiler, decodes ELF to `VmExe`, and calls `sdk.execute()`. It handles ELF → OpenVM format conversion internally.

**Gaps:**
1. **ELF patching still required.** OpenVM pre-processes all words as instructions. ACT4 ELFs embed `.word <ptr>` data in `.text` sections. Ere doesn't address this — it expects well-formed guest programs.
2. **Memory layout mismatch.** ACT4 uses `link.ld` with entry at `0x00000000`. Ere's OpenVM backend expects programs compiled for `riscv32im-risc0-zkvm-elf` target with the standard OpenVM memory map.
3. **Halt mechanism.** ACT4 uses custom opcode `0x0b`. Ere's OpenVM backend uses the standard OpenVM halt. The ACT4 ELFs already encode this, so if Ere can load them, it should work.

**Feasibility:** Medium. The transpiler step adds complexity — ACT4 ELFs aren't compiled for OpenVM's expected target, so the ELF→VmExe conversion might reject them or produce wrong results. Would require testing to see if `CpuSdk` can handle arbitrary ELFs with OpenVM's custom linker layout.

### 2.3 Zisk

**Current flow:**
```
ELF → patch_elfs.py --zisk (JAL rewrite) → zisk-binary -e <elf>
```

**Ere equivalent:**
`ere-zisk` uses `ZiskSdk` which calls `ziskemu` CLI. The execute path writes the ELF to a cache dir and spawns `ziskemu`.

**Gaps:**
1. **ELF patching still required.** Zisk maps `.text.init` execute-only; the failure handler reads instruction bytes. The `--zisk` patch (rewriting `failedtest_saveresults` entry to jump to `failedtest_terminate`) is still necessary.
2. **ISA mismatch.** Zisk is RV64IMA. Ere's Zisk compiler targets `riscv64ima-zisk-zkvm-elf`. ACT4 tests are compiled with `riscv64-unknown-elf-gcc` and a custom linker script placing data at `0xa0010000`. Ere expects a different ABI/memory layout.
3. **Server overhead.** Ere's Zisk backend starts a gRPC server for proving. For execution-only (which is all ACT4 needs), this is unnecessary overhead. The `ziskemu` CLI path is more direct — but Ere wraps it with ROM setup and caching infrastructure.
4. **RAM-aware parallelism.** Current infra auto-scales test parallelism based on available RAM (ziskemu pre-allocates ~8 GB). Ere has no equivalent; parallelism would need external management.

**Feasibility:** Medium-Low. The `ziskemu` CLI invocation is simple enough to call directly, which undermines the value of Ere's abstraction for this use case. Ere adds overhead (server setup, ROM generation) without benefit for compliance testing.

---

## 3. Architectural Mismatches

### 3.1 Compilation Model

| | ACT4 Pipeline | Ere |
|---|---|---|
| **Source language** | RISC-V assembly (.S) | Rust (or Go for Zisk) |
| **Compiler** | `riscv64-unknown-elf-gcc` | `rustc` with zkVM-specific targets |
| **Linker script** | Custom per-ZKVM `link.ld` | zkVM SDK default |
| **Entry point** | Varies: 0x0, 0x01000000, 0x80000000 | SDK-defined |
| **Output** | Self-checking ELF with Sail-embedded expected values | Standard Rust guest binary |

**This is the fundamental mismatch.** ACT4 tests are assembly programs compiled with GCC and custom linker scripts. Ere's compilation pipeline assumes Rust source compiled for zkVM-specific targets. There is no overlap.

### 3.2 IO Model

ACT4 tests communicate via:
- **Exit code**: 0 = all checks passed, non-zero = failure
- **tohost/ecall/opcode**: ZKVM-specific halt mechanism
- **No stdin/stdout**: Tests are self-contained

Ere's IO model:
- **stdin**: Raw bytes input (prefixed or raw)
- **public values**: Output bytes (limited: 32B for Airbender/OpenVM, 256B for Zisk)
- **Exit code**: Available but secondary to public values

ACT4 only cares about exit codes. Ere can surface these, but it's using a sledgehammer for a nail.

### 3.3 Test Discovery and Orchestration

ACT4 uses `act` (Python CLI) for test configuration, generation, and discovery. Results are parsed from `run_tests.py` output. Ere has no equivalent test orchestration — it's an execution engine, not a test framework.

---

## 4. What Would a Transition Look Like?

### Option A: Ere as Execution Backend Only (Minimal Integration)

Replace just the DUT wrapper scripts with Ere SDK calls.

**Current:** `entrypoint.sh` → shell wrapper → `zkvm-binary <args>`
**New:** `entrypoint.sh` → Rust binary using Ere → `zkvm.execute(pre_built_elf)`

**Requirements:**
1. Add a "raw ELF loader" to Ere that bypasses `Compiler` trait — accepts pre-built ELFs
2. Keep all ACT4 infrastructure (config, Sail, compilation, patching) unchanged
3. Ere provides unified exit-code extraction across backends

**Effort:** Low-medium (add raw ELF support to 3 backends)
**Value:** Low — replaces ~10 lines of shell per ZKVM with a Rust binary that does the same thing

### Option B: Ere-Native Test Harness (Deep Integration)

Rewrite the test pipeline in Rust using Ere's traits.

**Requirements:**
1. Port ACT4 test generation (Sail reference, self-checking assembly) to Rust or keep as external tool
2. Implement ELF patching in Rust (port `patch_elfs.py`)
3. Build a Rust test orchestrator that discovers tests, runs them through Ere, collects results
4. Keep per-ZKVM configs (linker scripts, macros) but integrate with Ere's compilation

**Effort:** High (months of work)
**Value:** Medium — unified codebase, but ACT4's Python tooling works well and is actively maintained upstream

### Option C: Hybrid — Ere for New Tests, ACT4 for Compliance (Recommended Path)

Keep ACT4 infrastructure for RISC-V ISA compliance testing. Use Ere for:
- **Functional tests** (custom guest programs testing ZKVM behavior beyond ISA compliance)
- **Cross-ZKVM benchmarking** (cycle counts, proving times)
- **Regression tests** (standard Rust guest programs compiled for all backends)

**Rationale:** ACT4's value is its exhaustive ISA coverage generated from the RISC-V spec. Ere's value is portable guest programs. They solve different problems.

---

## 5. Specific Technical Barriers

### 5.1 Pre-Built ELF Ingestion

Ere currently requires programs to flow through `Compiler::compile()`. For ACT4, we need:

```rust
// Hypothetical API
let elf_bytes = std::fs::read("test.elf")?;
let zkvm = EreAirbender::from_raw_elf(elf_bytes)?;
let (_, report) = zkvm.execute(&Input::empty())?;
assert_eq!(report.exit_code, 0);
```

This doesn't exist today. Each backend would need a `from_raw_elf()` constructor.

### 5.2 Custom Memory Layouts

ACT4 linker scripts place sections at ZKVM-specific addresses. Ere's backends may not support arbitrary memory layouts — they expect programs compiled for their standard target triple. Airbender is the most flexible (flat binary with explicit entry/tohost params). OpenVM and Zisk may reject ELFs with non-standard layouts.

### 5.3 ELF Patching

Even with Ere, `patch_elfs.py` is still needed for OpenVM and Zisk. This means the pipeline can't be "pure Ere" — a preprocessing step remains. This dilutes the benefit of switching.

### 5.4 Parallelism and Resource Management

Current infrastructure has ZKVM-specific parallelism tuning (Zisk's RAM-aware scaling). Ere provides no equivalent — you'd need to manage test parallelism externally, losing the per-ZKVM optimization.

---

## 6. What Ere Brings That's Genuinely Useful

Despite the mismatches, Ere offers real value for **extending** (not replacing) the test infrastructure:

1. **Unified exit-code extraction.** Currently each ZKVM has different halt conventions (tohost, ecall, opcode 0x0b). Ere normalizes this to `report.exit_code`.

2. **Docker-free execution.** Ere can run ZKVMs via direct SDK integration, eliminating the Docker overhead for development iteration.

3. **Proving capability.** ACT4 only tests execution. Ere could extend compliance testing to **prove** that execution is correct — verifying the ZKVM's proof system alongside ISA compliance.

4. **Version pinning.** Ere pins ZKVM SDK versions in `Cargo.toml`. Currently, `config.json` + Docker builds handle this, but Ere's Cargo-based approach is more robust for Rust-native ZKVMs.

5. **New ZKVM onboarding.** Adding a ZKVM to Ere (if already supported) would be simpler than building custom Docker infrastructure from scratch.

---

## 7. Recommendation

**Short term (now):** Don't transition. The current ACT4 infrastructure works, is well-tuned per ZKVM, and solves a problem (ISA compliance from assembly) that Ere isn't designed for.

**Medium term:** Add a `from_raw_elf()` capability to Ere for the three target ZKVMs. This enables:
- Running ACT4 ELFs through Ere as an **alternative** execution path
- A/B testing Ere execution vs. direct binary execution
- Gradual validation that Ere produces identical results

**Long term:** If Ere matures to the point where it can:
1. Accept pre-built (non-Rust) ELFs with custom memory layouts
2. Handle ELF patching (or upstream fixes make patching unnecessary)
3. Provide per-ZKVM resource management (RAM-aware parallelism)

...then a full transition becomes viable. Until then, the two systems are complementary, not substitutional.

---

## 8. Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Ere rejects ACT4 ELFs due to memory layout | High | Blocks transition | Test with real ELFs early; add raw ELF support |
| ELF patching can't be eliminated | High | Permanent dependency on Python preprocessing | Upstream ACT4 fixes or port patcher to Rust |
| Ere overhead degrades test throughput | Medium | Slower CI | Benchmark before committing; keep direct path as fallback |
| Ere ZKVM version != tested binary version | Medium | Different behavior | Pin Ere versions to match config.json commits |
| Ere API changes break test harness | Low | Maintenance burden | Pin Ere version; update quarterly |
