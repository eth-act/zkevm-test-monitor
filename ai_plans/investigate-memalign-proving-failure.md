# Investigate Zisk MemAlign Proving Failure

## Executive Summary

**Problem:** All 8 ACT4 Misalign tests (lh, lhu, lw, lwu, ld, sh, sw, sd) pass Zisk execution but fail proving with "Invalid evaluations" on the `MemAlign` instance. The `MemAlignByte` instance (used by all other tests) verifies successfully.

**Goal:** Backtrack from the failing constraint to a specific witness row, then to the assembly instruction in the test that generated that row. This requires understanding Zisk's prover inspection tooling and using it systematically.

**Technical context:**
- Zisk v0.15.0 (commit b3ca745b8), source at `/home/cody/zisk/`
- The MemAlign state machine handles multi-byte misaligned memory accesses (width > 1, non-8-byte-aligned address)
- It models a mini-processor with 8 byte-registers and a ROM program, using 2-5 rows per operation
- The MemAlignByte state machine handles single-byte accesses and works correctly
- The prover generates a valid witness (execution passes) but proof verification rejects the MemAlign polynomial evaluations

**Approach:**
1. Use existing Zisk tools (`verify-constraints`, debug feature flags, RUST_LOG) to get constraint-level failure details
2. Dump the MemAlign witness table to identify the failing row(s)
3. Map failing rows back to memory operations in the execution trace
4. Map those operations to specific assembly instructions in the test ELF

### Key Components

1. **`cargo-zisk verify-constraints`** — CLI command that runs witness generation + constraint checking without full proving. Faster iteration, richer error output.
2. **`debug_mem_align` feature flag** — Compile-time flag in `state-machines/mem/Cargo.toml` that enables per-row tracing in MemAlign witness generation.
3. **`save_mem_bus_data` feature flag** — Dumps all memory bus operations to disk for offline analysis.
4. **PIL constraint definitions** — `state-machines/mem/pil/mem_align.pil` (190 lines) defines all constraints.
5. **Witness generation** — `state-machines/mem/src/mem_align_sm.rs` (~800 lines) fills the witness table.

### Data Flow

```
Test ELF (Misalign-lh-00.elf)
  │
  ▼
ziskemu execution (passes, exit 0)
  │
  ▼
Execution trace (memory operations with addr, step, width, value)
  │
  ▼
MemAlign collector (mem_align_collector.rs)
  │ Filters: multi-byte && !aligned → MemAlign instance
  │          single-byte → MemAlignByte instance
  ▼
MemAlign witness generation (mem_align_sm.rs)
  │ For each op: 2-5 rows with reg[], sel[], value[], etc.
  ▼
PIL constraint verification (proofman)
  │ Evaluates all constraints at each row
  ▼
"Invalid evaluations" ← FAILURE HERE
```

### Expected Outcomes

- Identify the exact PIL constraint(s) that fail and at which row(s)
- Determine whether the bug is in witness generation (Rust code) or constraint definition (PIL)
- Map the failing operation back to a specific misaligned load/store instruction in the test
- Produce a minimal reproducer or clear bug report for upstream Zisk

## Goals & Objectives

### Primary Goals
- Identify the exact constraint and row where MemAlign verification fails
- Determine root cause: witness generation bug vs PIL constraint bug
- Map failure back to specific assembly instruction in test

### Secondary Objectives
- Document the debugging workflow for future Zisk proving failures
- Understand whether this affects production workloads (not just compliance tests)

## Implementation Tasks

### Visual Dependency Tree

```
/home/cody/zisk/
├── cli/src/commands/verify_constraints.rs  (Task #1: Understand verify-constraints output)
├── state-machines/mem/
│   ├── Cargo.toml                          (Task #2: Build with debug features)
│   ├── pil/
│   │   ├── mem_align.pil                   (Task #3: Annotate constraints)
│   │   └── mem_align_byte.pil              (reference - working)
│   └── src/
│       ├── mem_align_sm.rs                 (Task #4: Trace witness generation)
│       ├── mem_align_byte_sm.rs            (reference - working)
│       └── mem_align_collector.rs          (Task #4: Understand routing)

/home/cody/zkevm-test-monitor/
├── test-results/zisk/elfs/target/rv64i/
│   ├── Misalign/Misalign-lh-00.elf         (Task #5: Disassemble + trace)
│   └── I/I-add-00.elf                      (reference - passes MemAlignByte)
├── binaries/
│   ├── cargo-zisk                          (Task #1: Run verify-constraints)
│   └── zisk-binary                         (Task #1: Run execution)
└── ai_notes/
    └── memalign-investigation.md           (Task #6: Document findings)
```

### Execution Plan

#### Group A: Understand Existing Tooling (Execute in parallel)

- [ ] **Task #1**: Run `cargo-zisk verify-constraints` on a failing misalign test
  - Purpose: Determine what constraint-level error info is available WITHOUT recompiling
  - Commands to try:
    ```bash
    # Basic verify-constraints
    LD_LIBRARY_PATH=binaries/zisk-lib binaries/cargo-zisk verify-constraints \
      --elf test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf \
      --witness-lib binaries/libzisk_witness.so \
      --emulator -vv

    # With RUST_LOG for maximum output
    RUST_LOG=debug LD_LIBRARY_PATH=binaries/zisk-lib binaries/cargo-zisk verify-constraints \
      --elf test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf \
      --witness-lib binaries/libzisk_witness.so \
      --emulator -vv

    # Also try stats command
    LD_LIBRARY_PATH=binaries/zisk-lib binaries/cargo-zisk stats \
      --elf test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf \
      --witness-lib binaries/libzisk_witness.so \
      --emulator -vv
    ```
  - **Key question**: Does `verify-constraints` report WHICH constraint fails and at WHICH row?
  - Also try on a passing test (I-add-00.elf) to see what success output looks like
  - Save all output to `ai_notes/memalign-verify-constraints-output.txt`
  - Context: The `verify_constraints.rs` CLI calls `prover.verify_constraints_debug(&pk, stdin, self.debug.clone())` which uses proofman's constraint checker

- [ ] **Task #1b**: Run `cargo-zisk verify-constraints` on a passing test for comparison
  - Run the same commands on `test-results/zisk/elfs/target/rv64i/I/I-add-00.elf`
  - Compare output format to understand what "success" looks like
  - This test uses MemAlignByte (not MemAlign), so if verify-constraints passes, it confirms the issue is MemAlign-specific

- [ ] **Task #1c**: Disassemble the failing test ELF
  - ```bash
    riscv64-unknown-elf-objdump -d test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf > ai_notes/misalign-lh-00-disasm.txt
    ```
  - Identify all misaligned load/store instructions and their addresses
  - Note the memory addresses used (from LA(x13, scratch) setup)
  - Count how many misaligned ops there are → each generates 2-5 MemAlign rows

#### Group B: Build with Debug Features (After Group A, only if verify-constraints doesn't give enough info)

- [ ] **Task #2**: Build cargo-zisk with `debug_mem_align` and `save_mem_bus_data` features
  - Folder: `/home/cody/zisk/`
  - Check current checkout: `cd /home/cody/zisk && git log --oneline -1`
  - Build command:
    ```bash
    cd /home/cody/zisk
    cargo build --release -p cargo-zisk --features "debug_mem_align,save_mem_bus_data"
    ```
  - If build fails (feature flags may not propagate to workspace members):
    ```bash
    # Check actual feature flag locations
    grep -r "debug_mem_align" /home/cody/zisk/state-machines/mem/Cargo.toml
    # May need to edit Cargo.toml to enable features by default temporarily
    ```
  - Copy debug binary: `cp target/release/cargo-zisk /home/cody/zkevm-test-monitor/binaries/cargo-zisk-debug`
  - Also build ziskemu with debug features if needed:
    ```bash
    cargo build --release -p ziskemu --features "debug_mem_align"
    ```

- [ ] **Task #2b**: Run the debug-built cargo-zisk on the failing test
  - ```bash
    RUST_LOG=debug,zisk=trace LD_LIBRARY_PATH=binaries/zisk-lib \
      binaries/cargo-zisk-debug verify-constraints \
      --elf test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf \
      --witness-lib binaries/libzisk_witness.so \
      --emulator -vv 2>&1 | tee ai_notes/memalign-debug-output.txt
    ```
  - The `debug_mem_align` feature enables `debug_info!()` macros in mem_align_sm.rs that emit per-row witness values
  - Look for: row index, reg[0..7] values, sel[0..7] flags, addr, offset, width, step, value[0..1]
  - If `save_mem_bus_data` works, check for saved files in current directory or /tmp

#### Group C: Analyze Constraint Failure (After Group B provides data)

- [ ] **Task #3**: Map constraint failure to PIL source
  - Read the proofman error output to identify:
    - Which constraint ID failed (maps to a line in mem_align.pil)
    - At which row index
    - What the actual vs expected evaluation was
  - Cross-reference with PIL constraints in `/home/cody/zisk/state-machines/mem/pil/mem_align.pil`:
    - Lines 116-117: Register preservation (`reg[i]' - reg[i]` across steps)
    - Lines 125-130: Binary constraints on selectors
    - Line 142: `delta_addr` computation
    - Line 143: ROM lookup
    - Line 165: Disjoint selectors (`sel_prove * sel_assume === 0`)
    - Lines 186-188: Value reconstruction (`value[i] === sel_prove * prove_val[i] + sel_assume * assume_val[i]`)
    - Line 189: Permutation with Memory SM
  - Document which constraint(s) fail

- [ ] **Task #4**: Trace from failing row to assembly instruction
  - From the failing row's `step` value, find the corresponding execution step
  - From the execution step, find the PC (program counter) in the execution trace
  - From the PC, find the instruction in the disassembly (from Task #1c)
  - This gives us: Constraint → Witness Row → Memory Operation → Assembly Instruction
  - If `step` isn't directly mappable, use the `addr` and `width` from the failing row to narrow down which misaligned instruction it corresponds to (there are only ~9 misaligned ops per test)

- [ ] **Task #4b**: Compare MemAlign witness for a byte-level access (working) vs multi-byte (failing)
  - If we can get witness dumps from both MemAlignByte (passing) and MemAlign (failing), compare:
    - Are the memory addresses consistent?
    - Are the step values monotonically increasing?
    - Are the value reconstructions correct?
  - This helps determine if the issue is in the witness generation logic or the constraint definitions

#### Group D: Root Cause Analysis (After Group C)

- [ ] **Task #5**: Manually verify the witness against PIL constraints
  - Take the failing row data from debug output
  - Manually evaluate each PIL constraint using the witness values
  - Identify which specific constraint equation doesn't hold
  - Determine if:
    - The witness values are wrong (bug in mem_align_sm.rs)
    - The constraint is wrong (bug in mem_align.pil)
    - The ROM table is wrong (bug in mem_align_rom.pil)
  - Check the byte rotation logic in particular:
    - `get_byte(value, index, offset)` uses `(offset + index) % CHUNK_NUM`
    - PIL uses `reg[(_offset + rc_index * CHUNKS_BY_RC + ichunk) % CHUNK_NUM]`
    - Do these match?

- [ ] **Task #6**: Document findings
  - File: `ai_notes/memalign-investigation.md`
  - Include:
    - The failing constraint, row, and PIL line number
    - The assembly instruction that triggered it
    - The witness values at the failing row
    - Root cause determination
    - Whether this is fixable in our test infrastructure or requires upstream fix
    - Clear bug report text suitable for Zisk GitHub issues

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
- Group A tasks can all run in parallel
- Group B is only needed if Group A doesn't provide enough constraint-level detail
- Groups C and D are sequential (each depends on previous)
- Save all output to `ai_notes/` for reference
- Do NOT modify Zisk source code — this is investigation only

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.
