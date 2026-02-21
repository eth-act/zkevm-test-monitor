# Use Normal `run` Command Instead of `run-for-act`

## Executive Summary

Currently ACT4 tests use a custom `run-for-act` airbender CLI command that loads ELFs, polls HTIF tohost for termination, and returns exit codes. This required changes to the airbender codebase.

We can eliminate the airbender dependency by using the existing `run --bin` command with changes entirely on our side:
- `objcopy` ELFs to flat binaries
- Adjust linker script to start at address 0 (matching `run`'s hardcoded entry point)
- Signal pass/fail via register x10 instead of tohost (so we can read it from `run`'s output)
- Wrapper script handles objcopy + invocation + output parsing

### Data Flow
```
ELF → objcopy → flat.bin → airbender run --bin → parse "Result:" → exit code
```

### Tradeoff
- **No early termination**: `run` doesn't poll tohost, so tests run the full cycle count. Tests that reach HALT will loop until cycles exhaust. This is slower but correct.
- **No ELF-native loading**: We flatten ELFs ourselves. Data sections appear in instruction tape but are never executed.

## Goals
- Remove dependency on `run-for-act` command in airbender
- All changes in zkevm-test-monitor and riscv-arch-test only
- Maintain identical pass/fail results

## Implementation Tasks

### Visual Dependency Tree
```
riscv-arch-test/config/airbender/
├── airbender-rv32im/
│   ├── link.ld              (Task #0: entry at 0x0)
│   └── rvmodel_macros.h     (Task #0: x10 = pass/fail)
├── airbender-rv64im-zicclsm/
│   ├── link.ld              (Task #0: entry at 0x0)
│   └── rvmodel_macros.h     (Task #0: x10 = pass/fail)

docker/act4-airbender/
└── entrypoint.sh            (Task #1: wrapper script + use `run`)
```

### Group A: Foundation (parallel)

- [ ] **Task #0**: Update linker scripts and RVMODEL macros for both configs
  - Files:
    - `riscv-arch-test/config/airbender/airbender-rv32im/link.ld`
    - `riscv-arch-test/config/airbender/airbender-rv64im-zicclsm/link.ld`
    - `riscv-arch-test/config/airbender/airbender-rv32im/rvmodel_macros.h`
    - `riscv-arch-test/config/airbender/airbender-rv64im-zicclsm/rvmodel_macros.h`
  - Linker script changes:
    - Change `. = 0x01000000;` to `. = 0x00000000;`
    - Keep all other layout (relative offsets preserved)
  - RVMODEL macro changes:
    - `RVMODEL_HALT_PASS`: add `li x10, 0` before the tohost write+loop
    - `RVMODEL_HALT_FAIL`: add `li x10, 1` before the tohost write+loop
    - Keep tohost writes (harmless, and useful for debugging)
  - Rationale: `run` hardcodes entry_point=0, so code must be linked at 0. `run` prints registers x10-x25, so pass/fail must be in x10.

### Group B: Entrypoint (after Group A)

- [ ] **Task #1**: Update entrypoint.sh to use `run --bin` via wrapper
  - File: `docker/act4-airbender/entrypoint.sh`
  - Generate `/tmp/run_wrapper.sh` in entrypoint that:
    1. Receives ELF path as $1
    2. `objcopy -O binary $1 /tmp/test_$$.bin`
    3. Runs `$DUT run --bin /tmp/test_$$.bin --cycles 1000000`
    4. Captures output and exit code
    5. If airbender exits non-zero → exit 1 (VM panic = fail)
    6. Parses "Result: X, ..." line, extracts first value (x10)
    7. If x10 == 0 → exit 0 (pass), else exit 1 (fail)
    8. Cleans up temp file
  - Change run_tests.py invocation from `"$DUT run-for-act"` to `"/tmp/run_wrapper.sh"`
  - objcopy binary: use `riscv64-unknown-elf-objcopy` (available in container PATH)

## Verification
1. Rebuild Docker image: need to recompile ELFs with new linker script
2. Run: `./run test --act4 airbender`
3. Confirm same 42/47 pass on native, 0/72 on target
4. Regenerate dashboard, verify no regressions

## Implementation Workflow
1. Load plan, create tasks
2. Execute tasks
3. Rebuild and test
4. Commit
