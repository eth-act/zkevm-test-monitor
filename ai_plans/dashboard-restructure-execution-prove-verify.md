# Dashboard Restructure: Full ISA / Standard ISA Columns

## Executive Summary

> The current dashboard groups columns as "Execution" (native ISA, execution results) and
> "Prove Then Verify" (target ISA execution, prove, verify). This is misleading — execution
> happens for both suites. The user wants columns grouped by *ISA scope*:
>
> - **Full ISA**: ISA + Execution results (native suite, always execute-only)
> - **[Standard ISA](url)**: Execution + Prove + Verify (target suite, execute then prove+verify)
>
> Additionally, `test.sh` currently runs *both* suites in the same mode (execute/prove/full),
> meaning the native suite wastefully attempts proving. Native should always be execute-only.
>
> Target layout:
> ```
> ZKVM | CI? | Commit |     Full ISA    |     Standard ISA           | Last Run
>                     | ISA | Execution | Execution | Prove | Verify |
> ```
> Where "Standard ISA" links to https://github.com/eth-act/zkvm-standards/blob/main/standards/riscv-target/target.md

## Goals & Objectives

### Primary Goals
- Dashboard columns restructured: `Full ISA (ISA, Execution)` | `Standard ISA (Execution, Prove, Verify)`
- "Standard ISA" header links to the zkvm-standards target spec
- `GPU=1 ./run test zisk` runs: (1) execute full ISA, (2) execute+prove+verify standard ISA
- Native suite always runs execute-only regardless of `ZISK_MODE`

### Secondary Objectives
- Detail page labels updated to match new column naming
- No changes to data format (results.json, history files, summary files)

## Solution Overview

### Approach
Two files need changes: `src/test.sh` (test flow) and `src/update.py` (dashboard HTML generation).

### Data Flow
```
GPU=1 ./run test zisk
  ↓
test.sh:
  1. act4-runner --suite act4 --label full-isa --mode execute          (native, always execute)
  2. act4-runner --suite act4-target --label standard-isa --mode full   (target, execute+prove+verify)
  ↓
update.py:
  Dashboard columns: Full ISA (ISA, Execution) | Standard ISA (Execution, Prove, Verify)
```

### Expected Outcomes
- `GPU=1 ./run test zisk` runs native in execute mode, then target in full mode
- Dashboard shows "Full ISA" and "Standard ISA" column groups
- "Standard ISA" header is a hyperlink to the target spec

## Implementation Tasks

### Visual Dependency Tree

```
src/
├── test.sh    (Task #0a: Split native=execute, target=mode)
└── update.py  (Task #0b: Restructure dashboard column headers + detail page labels)
```

### Execution Plan

#### Group A: All tasks are independent (Execute in parallel)

- [ ] **Task #0a**: Update test.sh — native always execute, target gets the mode
  - File: `src/test.sh`
  - Current (lines 230-267): Both suites use the same `$MODE` and `$ZKVM_ARG`
  - Change: Split into two separate invocation configs
  - **Native suite** (lines 244-254):
    - Always use `--zkvm zisk --binary binaries/zisk-binary`
    - Always use `--mode execute`
    - Never pass `$GPU_ARG` or `$PROVE_ARGS`
    - Echo: `"Running zisk native suite (execute)..."`
  - **Target suite** (lines 257-267):
    - Use `$ZKVM_ARG` / `$TARGET_ZKVM_ARG` (zisk or zisk-prove depending on mode)
    - Use `--mode "$MODE"` (the actual mode from ZISK_MODE env)
    - Pass `$PROVE_ARGS` (includes GPU flag if set)
    - Echo: `"Running zisk target suite (mode: $MODE)..."`
  - Replace lines 230-267 with:
    ```bash
    # Native suite: always execute-only (proving is only for standard ISA target suite)
    if [ -d "$ELF_DIR/native" ]; then
      echo "Running $ZKVM native suite (execute)..."
      "$RUNNER" \
        --zkvm zisk --binary binaries/zisk-binary \
        --elf-dir "$ELF_DIR/native" \
        --output-dir "test-results/${ZKVM}" \
        --suite act4 \
        --label full-isa \
        --mode execute \
        $RUNNER_JOBS || true
    fi

    # Target suite: run in requested mode (execute, prove, or full)
    if [ -d "$ELF_DIR/target" ]; then
      local TARGET_ZKVM_ARG TARGET_PROVE_ARGS=""
      if [ "$MODE" = "execute" ]; then
        TARGET_ZKVM_ARG="--zkvm zisk --binary binaries/zisk-binary"
      else
        TARGET_ZKVM_ARG="--zkvm zisk-prove --binary binaries/zisk-binary --cargo-zisk $CARGO_ZISK"
        TARGET_PROVE_ARGS="$GPU_ARG"
        if [ -f "binaries/libzisk_witness.so" ]; then
          TARGET_ZKVM_ARG="$TARGET_ZKVM_ARG --witness-lib binaries/libzisk_witness.so"
        fi
      fi

      echo "Running $ZKVM target suite (mode: $MODE)..."
      "$RUNNER" \
        $TARGET_ZKVM_ARG \
        --elf-dir "$ELF_DIR/target" \
        --output-dir "test-results/${ZKVM}" \
        --suite act4-target \
        --label standard-isa \
        --mode "$MODE" \
        $TARGET_PROVE_ARGS $RUNNER_JOBS || true
    fi
    ```

- [ ] **Task #0b**: Update dashboard column headers and detail page labels
  - File: `src/update.py`
  - **Main dashboard header** (`generate_act4_dashboard_html`, lines 588-605):
    - Row 1: `<th colspan="2" ...>Execution</th>` → `<th colspan="2" ...>Full ISA</th>`
    - Row 1: `<th colspan="3" ...>Prove Then Verify</th>` → `<th colspan="3" ...><a href="https://github.com/eth-act/zkvm-standards/blob/main/standards/riscv-target/target.md" style="color: inherit; text-decoration: underline;">Standard ISA</a></th>`
    - Row 2 under Full ISA: `ISA`, `Results` → `ISA`, `Execution`
    - Row 2 under Standard ISA: `Executed`, `Proved`, `Verified` → `Execution`, `Prove`, `Verify`
  - **Detail page label** (line 695):
    - Change `'Prove Then Verify — RV64IM_Zicclsm'` → `'Standard ISA — RV64IM_Zicclsm'`
    - Change `'Execution — Full ISA'` → `'Full ISA'`

---

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Execute & Update**: For each task, mark `[ ]` → `[x]` when completing
3. **Build & Test**: After changes, run `./run update` and verify dashboard renders correctly

### Critical Rules
- This plan file is the source of truth for progress
- Do not change data formats (results.json, history files, summary files)
- Only change presentation (HTML headers/labels) and test flow (native always execute)
