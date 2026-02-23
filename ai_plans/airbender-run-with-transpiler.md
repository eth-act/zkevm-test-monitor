# Airbender: Generic Transpiler Run Command Implementation Plan

## Executive Summary

The Airbender CLI currently has two compliance-test-specific commands (`run-for-act`,
`run-for-riscof`) that embed ACT4 and RISCOF testing logic directly into the ZK-VM binary.
The goal is to replace these with a single generic `run-with-transpiler` command that uses
the new transpiler/VM stack and knows nothing about test frameworks. All test-specific logic
(ELF-to-binary conversion, address extraction, pass/fail interpretation) moves to our test
infrastructure in `zkevm-test-monitor`.

The existing upstream `run` command uses the old `risc_v_simulator` (a cycle-accurate
interpreter, not the transpiler). The new command replaces this with `preprocess_bytecode` +
`VM::run_basic_unrolled` — the same execution path used by the actual prover — making
`run-with-transpiler` a genuine simulation of what gets proved.

Termination works the same way as the old simulator: the program spins in an infinite loop
(`j .`) when done, which corresponds to a tohost write. The new command polls a
caller-supplied `--tohost-addr` to detect this, giving a clean 0/1/2 exit code when needed,
or just prints registers if no tohost addr is given.

**Data flow (ACT4 testing after this change):**
```
ACT4 ELF
  → [our side] objcopy -O binary          → flat binary
  → [our side] readelf/nm                 → entry_point, tohost_addr
  → airbender-binary run-with-transpiler  → exit 0 (pass) / 1 (fail) / 2 (timeout)
  → run_tests.py                          → summary JSON
```

## Goals & Objectives

### Primary Goals
- `run-for-act` and `run-for-riscof` removed from Airbender CLI
- New generic `run-with-transpiler` command added, suitable for upstreaming to matter-labs
- All ACT4 test complexity lives in `docker/act4-airbender/entrypoint.sh`

### Secondary Objectives
- Remove `object` crate dependency from `riscv_transpiler` (no more ELF parsing in the prover crate)
- RISCOF plugin for Airbender disabled (ACT4 is the active framework)
- `ir/mod.rs` Illegal instruction support retained (general improvement, not test-specific)

## Solution Overview

### Approach

Replace the two test-specific modules (`act.rs`, `riscof.rs`) in `riscv_transpiler` with a
single generic `run.rs`. The CLI gains `RunWithTranspiler` and loses `RunForAct` /
`RunForRiscof`. The test entrypoint gains a wrapper that does the ELF preprocessing that
`act.rs` previously did internally.

### Key Components

1. **`riscv_transpiler/src/run.rs`** (NEW): Generic `run_binary()` — loads flat binary at
   entry point, runs through transpiler, optionally polls tohost. Returns `RunResult` with
   registers, tohost value, and timed-out flag.

2. **`tools/cli/src/main.rs`** (MODIFIED): Add `RunWithTranspiler`, remove `RunForAct` and
   `RunForRiscof` and their handler code.

3. **`riscv_transpiler/src/lib.rs`** (MODIFIED): `pub mod run` replaces `pub mod act` and
   `pub mod riscof`.

4. **`riscv_transpiler/Cargo.toml`** (MODIFIED): Remove `object` dependency (was only used
   by act.rs and riscof.rs for ELF parsing).

5. **`docker/act4-airbender/entrypoint.sh`** (MODIFIED): `run-dut.sh` wrapper expands to do
   objcopy + address extraction before calling `run-with-transpiler`.

6. **`riscof/plugins/airbender/riscof_airbender.py`** (MODIFIED): Disabled with clear error
   message pointing to ACT4.

### Data Flow

```
Before:
  ELF → RunForAct (parses ELF, separates segments, polls tohost) → exit code

After:
  ELF → objcopy → flat binary  ─┐
  ELF → readelf/nm → addrs     ─┴→ RunWithTranspiler → exit code
```

### Expected Outcomes

- `airbender-binary run-with-transpiler --bin foo.bin --entry-point 0x1000000 --tohost-addr 0x1001000 --cycles 10000000` exits 0/1/2
- `airbender-binary run-with-transpiler --bin foo.bin --entry-point 0x1000000 --cycles 1000000` prints registers and exits 0
- ACT4 tests for Airbender continue passing at current pass rate
- `run-for-act` and `run-for-riscof` are gone from the binary
- `./run test --arch airbender` prints "RISCOF not supported for airbender; use --act4"

---

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. No placeholder code — every function must be fully implemented
2. `run.rs` is a direct factoring of the logic already in `act.rs` and `riscof.rs` — reuse it
3. The `ir/mod.rs` Illegal instruction change is retained as-is (do not revert it)
4. All types used in `run.rs` come from `crate::vm` and `crate::ir` — same imports as act.rs

### Visual Dependency Tree

```
zksync-airbender/
├── riscv_transpiler/
│   ├── Cargo.toml                (Task #2: remove object dep)
│   ├── src/
│   │   ├── lib.rs                (Task #2: swap pub mod act/riscof → pub mod run)
│   │   ├── run.rs                (Task #1: NEW — generic run_binary function)
│   │   ├── act.rs                (Task #1: DELETE)
│   │   └── riscof.rs             (Task #1: DELETE)
│
└── tools/cli/src/
    └── main.rs                   (Task #2: RunWithTranspiler, remove RunForAct/RunForRiscof)

zkevm-test-monitor/
├── docker/act4-airbender/
│   └── entrypoint.sh             (Task #3: new run-dut.sh wrapper)
└── riscof/plugins/airbender/
    └── riscof_airbender.py       (Task #3: disable with error message)
```

### Execution Plan

#### Group A — Airbender transpiler layer (execute first, independently)

- [ ] **Task #1**: Create `riscv_transpiler/src/run.rs`, delete `act.rs` and `riscof.rs`

  **File to create:** `riscv_transpiler/src/run.rs`
  **Files to delete:** `riscv_transpiler/src/act.rs`, `riscv_transpiler/src/riscof.rs`

  **Imports:**
  ```rust
  use crate::ir::{preprocess_bytecode, FullMachineDecoderConfig, Instruction};
  use crate::vm::{DelegationsCounters, RamPeek, RamWithRomRegion, Register, SimpleTape, State, VM};
  use common_constants;
  ```

  **Types to define:**
  ```rust
  pub struct RunResult {
      /// Final register state (x0..x31 + pc at index 32 if present, else [u32; 32])
      /// Match the exact field name/type from State — check State struct definition
      pub registers: <match State.registers type>,
      /// Some(v) if tohost_addr was given and tohost fired; None if no tohost_addr
      /// or cycles exhausted before tohost fired
      pub tohost_value: Option<u32>,
      /// true iff max_cycles exhausted before tohost fired (only meaningful when
      /// tohost_addr was Some)
      pub timed_out: bool,
  }
  ```

  **Function to implement:**
  ```rust
  /// Run a flat binary through the transpiler VM.
  ///
  /// `binary`: raw bytes of the flat binary (produced by objcopy -O binary).
  ///           Placed at `entry_point` in the address space.
  /// `entry_point`: load address AND initial PC.
  /// `max_cycles`: hard cycle ceiling.
  /// `tohost_addr`: if Some, poll this word address every 100k cycles and return
  ///                when nonzero.
  pub fn run_binary(
      binary: &[u8],
      entry_point: u32,
      max_cycles: usize,
      tohost_addr: Option<u32>,
  ) -> RunResult
  ```

  **Implementation** (adapted directly from act.rs + riscof.rs):

  ```
  1. bytes_to_words(binary) → binary_words  (copy bytes_to_words from riscof.rs)
  2. entry_offset = entry_point / 4
  3. padded_instructions = vec![0u32; entry_offset + binary_words.len()]
  4. padded_instructions[entry_offset..] = binary_words
  5. instructions = preprocess_bytecode::<FullMachineDecoderConfig>(&padded_instructions)
  6. tape = SimpleTape::new(&instructions)
  7. Allocate RAM (MEMORY_SIZE / 4 words), place binary_words at entry_offset in backing
  8. state.pc = entry_point

  If tohost_addr is Some(addr):
    - Loop in 100_000-cycle chunks (POLL_CHUNK constant)
    - After each chunk: peek word at addr
    - If nonzero: return RunResult { tohost_value: Some(val), timed_out: false, registers }
    - If cycles exhausted: return RunResult { tohost_value: None, timed_out: true, registers }

  If tohost_addr is None:
    - Single call: VM::run_basic_unrolled(..., max_cycles, ...)
    - Return RunResult { tohost_value: None, timed_out: false, registers }
  ```

  **Constants** (copy from act.rs/riscof.rs):
  ```rust
  const ROM_SECOND_WORD_BITS: usize = common_constants::rom::ROM_SECOND_WORD_BITS;
  const MEMORY_SIZE: usize = 1 << 30;
  const POLL_CHUNK: usize = 100_000;
  ```

  **Private helper** (copy verbatim from riscof.rs):
  ```rust
  fn bytes_to_words(bytes: &[u8]) -> Vec<u32>
  ```

  **No `catch_unwind`** — panics from unsupported instructions propagate as non-zero exit (correct
  failure semantics), no special handling needed.

---

#### Group B — Airbender CLI + module wiring (after Task #1)

- [ ] **Task #2**: Update `lib.rs`, `Cargo.toml`, and `tools/cli/src/main.rs`

  **`riscv_transpiler/src/lib.rs`** changes:
  - Remove: `pub mod act;`
  - Remove: `pub mod riscof;`
  - Add: `pub mod run;`
  - Keep: all other modules unchanged (ir, jit, replayer, vm, witness)

  **`riscv_transpiler/Cargo.toml`** changes:
  - Remove the `object` dependency line (only used by deleted act.rs and riscof.rs)

  **`tools/cli/src/main.rs`** changes:

  Remove from imports:
  ```rust
  // remove PathBuf (only used by RunForRiscof)
  use std::path::{Path, PathBuf};  →  use std::path::Path;
  ```

  Remove from `Commands` enum:
  ```rust
  RunForAct { ... }
  RunForRiscof { ... }
  ```

  Add to `Commands` enum:
  ```rust
  /// Run a flat binary through the transpiler VM.
  /// The binary is placed at --entry-point in the address space.
  /// If --tohost-addr is given, polls that address every 100k cycles and exits
  /// 0 (tohost==1), 1 (tohost nonzero != 1), or 2 (cycle limit exhausted).
  /// If --tohost-addr is omitted, runs for --cycles cycles and prints registers.
  RunWithTranspiler {
      /// Path to flat binary (e.g. produced by riscv64-unknown-elf-objcopy -O binary)
      #[arg(short, long)]
      bin: String,
      /// Address where the binary is loaded and where execution begins
      #[arg(long, default_value_t = 0)]
      entry_point: u32,
      /// Maximum RISC-V cycles to execute. Defaults to 32_000_000.
      #[arg(long)]
      cycles: Option<usize>,
      /// If set, poll this word address for HTIF tohost signal.
      /// Nonzero tohost triggers exit: 1→exit(0), other nonzero→exit(1).
      /// Cycle exhaustion without tohost signal→exit(2).
      #[arg(long)]
      tohost_addr: Option<u32>,
  },
  ```

  Remove from `match &cli.command` block:
  - The `Commands::RunForAct { ... }` arm
  - The `Commands::RunForRiscof { ... }` arm
  - The `run_for_riscof_binary` helper function at bottom of file

  Add to `match &cli.command` block:
  ```rust
  Commands::RunWithTranspiler { bin, entry_point, cycles, tohost_addr } => {
      let binary = fs::read(bin).expect("Failed to read binary file");
      let result = riscv_transpiler::run::run_binary(
          &binary,
          *entry_point,
          cycles.unwrap_or(DEFAULT_CYCLES),
          *tohost_addr,
      );
      if tohost_addr.is_some() {
          if result.timed_out {
              eprintln!("run-with-transpiler: cycle limit exhausted without tohost signal");
              std::process::exit(2);
          }
          match result.tohost_value {
              Some(1) => std::process::exit(0),
              Some(_) => std::process::exit(1),
              None => std::process::exit(2),
          }
      } else {
          // No tohost: print registers x10..x17 (matches old Run output format)
          let regs = &result.registers[10..18];
          let s = regs.iter().map(|x| format!("{}", x)).collect::<Vec<_>>().join(", ");
          println!("Result: {}", s);
      }
  }
  ```

  **Note on `result.registers` indexing**: Check the exact field name and array bounds in
  `State` before implementing. If registers are `[u32; 32]`, `[10..18]` is x10-x17.
  If `[u32; 33]`, adjust accordingly.

---

#### Group C — zkevm-test-monitor (independent, run in parallel with A+B)

- [ ] **Task #3**: Update `docker/act4-airbender/entrypoint.sh` and disable RISCOF plugin

  **`docker/act4-airbender/entrypoint.sh`** — replace the `run-dut.sh` creation block:

  Current:
  ```bash
  RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT run-for-act" "$ELF_DIR" -j "$JOBS" 2>&1)
  ```
  Note: `run_tests.py` appends `<elf_path>` to the command string, so the DUT command
  currently receives the ELF path directly.

  New wrapper (replaces the `cat > /act4/run-dut.sh` block):
  ```bash
  cat > /act4/run-dut.sh << 'WRAPPER'
  #!/bin/bash
  ELF="$1"
  BIN="${ELF%.elf}.bin"

  # Convert ELF to flat binary (binary starts at lowest load VMA)
  riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"

  # Extract entry point from ELF header
  ENTRY=$(riscv64-unknown-elf-readelf -h "$ELF" \
      | grep "Entry point" | grep -oE '0x[0-9a-f]+')

  # Extract tohost symbol address
  TOHOST=$(riscv64-unknown-elf-nm "$ELF" \
      | awk '/\btohost\b/{print "0x"$1; exit}')

  /dut/airbender-binary run-with-transpiler \
      --bin "$BIN" \
      --entry-point "$ENTRY" \
      --tohost-addr "$TOHOST" \
      --cycles 10000000
  EC=$?
  rm -f "$BIN"
  exit $EC
  WRAPPER
  chmod +x /act4/run-dut.sh
  ```

  Replace the `run_tests.py` invocation:
  ```bash
  # Before:
  RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT run-for-act" "$ELF_DIR" -j "$JOBS" 2>&1)

  # After:
  RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1)
  ```

  Remove the `patch_elfs.py` call if present in the airbender entrypoint (Airbender
  does not use patch_elfs.py — verify this is already absent before making any change).

  **`riscof/plugins/airbender/riscof_airbender.py`** — disable the plugin:

  Replace the `runTestCase` method body (around line 160, where `simcmd` is built) with:
  ```python
  def runTestCase(self, testcase_dict):
      raise NotImplementedError(
          "RISCOF testing is not supported for Airbender. "
          "Use ACT4 instead: ./run test --act4 airbender"
      )
  ```

  Or alternatively, add a clear comment at the top of the file and let it error naturally
  when called — the RISCOF runner will report failures for each test, which is acceptable
  since we don't run `--arch airbender` anymore.

---

## Implementation Workflow

This plan file is the authoritative checklist. When implementing:

### Required Process
1. **Load Plan**: Read this entire file before starting
2. **Create Tasks**: Create TodoWrite tasks matching the checkboxes above
3. **Execute & Update**: For each task:
   - Mark TodoWrite as `in_progress` when starting
   - Update checkbox `[ ]` to `[x]` when completing
   - Mark TodoWrite as `completed` when done

### Task Order
- **Task #1** first (creates run.rs that Task #2 depends on)
- **Task #2** after Task #1 (wires run.rs into lib.rs and CLI)
- **Task #3** independently at any time (different repo, no dependency on #1/#2)

### Verification after implementation
1. Build: `cd zksync-airbender && cargo build --profile test-release -p cli`
2. Smoke test: `cp target/test-release/cli ../zkevm-test-monitor/binaries/airbender-binary`
3. Run ACT4: `cd ../zkevm-test-monitor && ./run test --act4 airbender`
4. Confirm pass rate matches pre-change baseline (currently 100% on I+M)
5. Confirm `airbender-binary run-for-act` and `run-for-riscof` no longer exist
6. Confirm `airbender-binary run-with-transpiler --help` shows correct usage
