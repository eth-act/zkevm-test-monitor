# ACT4 Migration: From RISCOF to ACT4 Framework

## Summary

The RISC-V architectural compliance tests have moved from the RISCOF framework to the new
**ACT4 framework** (on the `act4` branch of riscv-arch-test, now the default working copy
at `riscv-arch-test/`). This doc captures what changed, how both frameworks work, and what's
needed to integrate Airbender with ACT4.

---

## Part 1: Building Airbender Locally

### Symlink
`/home/cody/zkevm-test-monitor/zksync-airbender` → `/home/cody/zksync-airbender`

The repo is on branch `riscof-dev`, which adds `riscv_transpiler/src/riscof.rs` and a
`RunForRiscof` CLI subcommand on top of upstream.

### Build
```bash
cd /home/cody/zksync-airbender
cargo build --profile test-release -p cli
```
- Binary output: `target/test-release/cli`
- Profile `test-release`: opt-level=2, codegen-units=256, no LTO, incremental — fast compilation
- Requires nightly Rust (pinned in `rust-toolchain.toml`)

### Copy to test monitor
```bash
cp /home/cody/zksync-airbender/target/test-release/cli \
   /home/cody/zkevm-test-monitor/binaries/airbender-binary
```

### Or via Docker (same as other ZKVMs)
```bash
cd /home/cody/zkevm-test-monitor
./run build airbender
```
The Dockerfile at `docker/build-airbender/Dockerfile` clones from the repo in `config.json`,
builds with `--profile test-release -p cli`, and extracts the binary.

### Config entry (config.json)
```json
"airbender": {
  "repo_url": "https://github.com/codygunton/zksync-airbender",
  "commit": "riscof-dev",
  "build_cmd": "cargo build --profile test-release --bin cli",
  "binary_name": "airbender-binary",
  "binary_path": "target/test-release/cli"
}
```

### CLI commands relevant to testing
```bash
# Run a binary (flat binary file, not ELF)
airbender-binary run --bin my.bin --cycles 100000

# Run for RISCOF compliance (signature extraction mode)
airbender-binary run-for-riscof \
  --bin my.bin \    # flat binary
  --elf my.elf \    # ELF (for symbol extraction only)
  --signatures out.sig \
  --cycles 100000
```

### Run existing RISCOF tests
```bash
cd /home/cody/zkevm-test-monitor
./run test --arch airbender
```

---

## Part 2: RISCOF Framework (Current Setup)

**Status**: In use, but RISCOF itself is deprecated.

### How it works

1. **Docker image** built from `riscof/Dockerfile`:
   - Installs `riscof==1.25.3` Python package
   - Downloads RISC-V toolchain (`riscv64-elf-ubuntu-24.04-gcc`)
   - Downloads Sail RISC-V simulator (reference model)
   - Clones `riscv-arch-test` at version 3.9.1 (the *old* RISCOF-compatible format)

2. **Plugin system**: Each ZKVM has a Python plugin in `riscof/plugins/<zkvm>/`:
   - `riscof_<name>.py` — implements compile, run, signature extraction
   - `<name>_isa.yaml` — ISA spec (riscv-config format)
   - `<name>_platform.yaml` — platform spec
   - `env/link.ld` — linker script
   - `env/model_test.h` — DUT-specific macros

3. **Test flow for Airbender**:
   ```
   .S test file
     → gcc compile to ELF (rv32im, ilp32 ABI)
     → objcopy ELF to flat binary
     → airbender run-for-riscof --bin <bin> --elf <elf> --signatures <sig> --cycles 100000
     → sig file compared against Sail reference signature
   ```

4. **Pass/fail**: Signature comparison. Airbender writes contents of `begin_signature`..`end_signature`
   memory region to a file; RISCOF diffs against Sail's output.

5. **Test format**: Old-style assembly with `RVMODEL_*` macros and explicit signature region.
   Tests live in `riscv-test-suite/rv64i_m/` etc. (pre-generated assembly files).

### Limitations
- RISCOF tool is deprecated (no active development)
- Complex plugin architecture per ZKVM
- Signature comparison requires running Sail reference model
- Tests use old format (RISCOF v3.9.1 era)
- Inflexible: must patch bugs in `riscof` Python package (see `Dockerfile`)

---

## Part 3: ACT4 Framework (New)

**Repo**: `riscv-arch-test` on `act4` branch (currently the default branch).
**Symlink**: `/home/cody/zkevm-test-monitor/riscv-arch-test` → `/home/cody/riscv-arch-test`

### Core concept shift

| | RISCOF | ACT4 |
|---|---|---|
| Test type | Signature extraction | Self-checking ELFs |
| Reference model | Sail runs at test time | Sail values compiled into ELF |
| DUT output | Memory signature file | Exit code (0=pass, nonzero=fail) |
| DUT integration | Python plugin | Config files + any command |
| Pass/fail | RISCOF compares signatures | DUT's `RVMODEL_HALT_PASS/FAIL` |
| Test generation | Pre-generated `.S` files | Generated on-demand via `make tests` |
| Framework | `riscof` Python package | Makefile + `uv`/Python `act` tool |

### Architecture

```
riscv-arch-test/
├── framework/src/act/     # Python package: 'act' CLI tool
├── generators/testgen/    # Test generators (Python)
├── testplans/             # CSV testplans per extension (I.csv, M.csv, ...)
├── tests/                 # Generated .S test files (from make tests)
├── config/                # Per-DUT configurations
│   ├── sail/sail-RVI20U32/
│   │   ├── test_config.yaml    # Name, compiler, ref model exe, UDB config
│   │   ├── sail-RVI20U32.yaml  # UDB config (extensions + params)
│   │   ├── rvmodel_macros.h    # DUT-specific pass/fail/IO macros
│   │   └── link.ld             # Linker script
│   ├── spike/spike-rv32-max/
│   ├── qemu/qemu-rv64-max/
│   └── cores/cve2/, cvw/
├── work/                  # Generated ELFs and build artifacts (per config)
│   └── <config-name>/elfs/
├── run_tests.py           # Parallel ELF runner
└── Makefile               # Orchestrates everything
```

### Workflow

```bash
# Step 1: Generate assembly test files (one-time, or after testplan changes)
make tests

# Step 2: Compile ELFs for a config
make elfs CONFIG_FILES=config/sail/sail-RVI20U32/test_config.yaml

# Equivalent to:
uv run act config/sail/sail-RVI20U32/test_config.yaml --workdir work --test-dir tests
make -C work compile

# Step 3: Run ELFs on DUT
./run_tests.py "spike --isa=rv32imafd" work/sail-RVI20U32/elfs
# Or: ./run_tests.py "my-dut-command" work/my-config/elfs
```

Convenience targets in Makefile:
```bash
make spike        # build + run for spike
make qemu         # build + run for qemu
make spike-rv32   # rv32 only
```

### Config files

**test_config.yaml**:
```yaml
name: my-dut-rv32
compiler_exe: riscv64-unknown-elf-gcc
objdump_exe: riscv64-unknown-elf-objdump        # optional
ref_model_exe: sail_riscv_sim
udb_config: my-dut-rv32.yaml
linker_script: link.ld
dut_include_dir: .   # dir containing rvmodel_macros.h
```

**UDB YAML** (e.g., `my-dut-rv32.yaml`):
- Lists implemented extensions with versions
- Specifies parameters (MXLEN, misaligned behavior, etc.)
- Schema: `external/riscv-unified-db/spec/schemas/config_schema.json`

**rvmodel_macros.h**:
- `RVMODEL_BOOT` — startup code
- `RVMODEL_HALT_PASS` — terminate simulation, signal pass
- `RVMODEL_HALT_FAIL` — terminate simulation, signal fail
- `RVMODEL_IO_INIT`, `RVMODEL_IO_WRITE_STR` — console I/O (optional)
- `RVMODEL_DATA_SECTION` — DUT-specific data (e.g., tohost/fromhost for HTIF)

**link.ld**: Standard RISC-V linker script. Sail/Spike use `0x80000000` base.

### Self-checking ELF mechanism
- Sail reference model is run during ELF compilation (not at test runtime)
- Expected values are compiled into the ELF binary itself
- At runtime, the test compares its own results to the baked-in expected values
- If correct: calls `RVMODEL_HALT_PASS` → DUT exits 0
- If incorrect: calls `RVMODEL_HALT_FAIL` → DUT exits nonzero
- `run_tests.py` checks exit codes; all tests pass → print "All N tests passed"

### Extension selection
```bash
# Only generate tests for specific extensions:
make elfs EXTENSIONS=I,M

# Exclude extensions:
make elfs EXCLUDE_EXTENSIONS=F,D
```

---

## Part 4: What's Needed for Airbender + ACT4

### The fundamental challenge

ACT4 tests need the DUT to:
1. **Accept an ELF file** (not a flat binary) — or at minimum, a flat binary loadable at the right address
2. **Run the ELF** until the test terminates itself
3. **Report pass/fail via exit code** (exit 0 = pass, nonzero = fail)

Airbender currently:
- Takes flat binary (`--bin`) with separate ELF for symbol extraction (`--elf`)
- Runs for a fixed number of cycles (no termination detection)
- Only signals "done" by exhausting the cycle budget

### Required changes to Airbender CLI

Add a new command (e.g., `run-for-act` or extend `RunForRiscof`):
- Accept ELF directly (extract text sections + compute load address)
- Detect `RVMODEL_HALT_PASS`/`RVMODEL_HALT_FAIL` — likely via HTIF tohost write
- Return exit code 0 on pass, 1 on fail

### Required config files for ACT4

Create `config/airbender/airbender-rv32im/`:

**test_config.yaml**:
```yaml
name: airbender-rv32im
compiler_exe: riscv64-unknown-elf-gcc
objdump_exe: riscv64-unknown-elf-objdump
ref_model_exe: sail_riscv_sim
udb_config: airbender-rv32im.yaml
linker_script: link.ld
dut_include_dir: .
```

**airbender-rv32im.yaml** (UDB config):
- RV32IM only (no F, D, C)
- Based on the ISA from `riscof/plugins/airbender/airbender_isa.yaml`

**rvmodel_macros.h**:
- `RVMODEL_HALT_PASS`: Write 1 to tohost address, loop forever
- `RVMODEL_HALT_FAIL`: Write 3 to tohost address, loop forever
- Airbender must detect tohost writes and convert to exit code

**link.ld**:
- Airbender default entry point: `0x0100_0000`
- Can adapt from existing `riscof/plugins/airbender/env/link.ld`

### Proposed implementation path

1. **Check `riscof/plugins/airbender/env/link.ld`** — understand current memory map
2. **Add `run-for-act` CLI command** to Airbender:
   - Load ELF (use `object` crate, already a dependency from riscof.rs)
   - Extract PT_LOAD segments and map to memory
   - Run until tohost ≠ 0 (or max cycles)
   - tohost==1 → exit 0 (pass); tohost==3 → exit 1 (fail)
3. **Create config directory** `config/airbender/airbender-rv32im/` in riscv-arch-test
4. **Test workflow**:
   ```bash
   cd /home/cody/riscv-arch-test
   make elfs CONFIG_FILES=config/airbender/airbender-rv32im/test_config.yaml EXTENSIONS=I,M
   ./run_tests.py "airbender-binary run-for-act" work/airbender-rv32im/elfs
   ```

### Wrapper script alternative (simpler, no Airbender changes needed short-term)

If we don't want to modify Airbender yet, a wrapper script could:
1. Accept an ELF path (as `run_tests.py` provides)
2. `objcopy -O binary` to flat binary
3. Run `airbender-binary run-for-riscof --bin ... --elf ... --signatures /tmp/sig --cycles 100000`
4. Inspect the result (exit code, or check if signature file looks "successful")
5. Return 0 or 1

But this is fragile — the `run-for-riscof` mode doesn't detect pass/fail.
The **proper solution is a new CLI mode** that detects HTIF tohost termination.

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `zksync-airbender/riscv_transpiler/src/riscof.rs` | Current RISCOF execution (cycles-limited, signature extraction) |
| `zksync-airbender/tools/cli/src/main.rs` | CLI entry point, `RunForRiscof` command |
| `riscof/plugins/airbender/riscof_airbender.py` | RISCOF plugin (build + run tests) |
| `riscof/plugins/airbender/env/link.ld` | Current linker script |
| `riscv-arch-test/framework/src/act/act.py` | ACT4 Python tool entry point |
| `riscv-arch-test/config/spike/spike-rv32-max/` | Reference config to copy for Airbender |
| `riscv-arch-test/config/sail/sail-RVI20U32/rvmodel_macros.h` | Reference macros (tohost/fromhost pattern) |
| `riscv-arch-test/run_tests.py` | Parallel ELF runner (used after `make elfs`) |
| `riscv-arch-test/Makefile` | Build orchestration |

---

## HTIF tohost Convention (for rvmodel_macros.h)

Spike/Sail use HTIF (Host-Target Interface) via a `tohost` memory-mapped register:
- Write `1` to tohost → pass (exit 0)
- Write `3` to tohost → fail (exit 1)
- Address is defined by `tohost` symbol in linker script

This is the de-facto standard for baremetal RISC-V simulation termination. Since Sail
already uses this, Airbender should implement the same mechanism.

The `run_tests.py` checks `returncode != 0` for failure, so Airbender's new command
just needs to return the right exit code.

---

## Appendix A: Zisk ACT4 F/D Failure Root Cause Analysis

**Date**: 2026-02-20
**Status**: Open — initial theory (fcsr broken) was DISPROVED

> **Note**: Full tracking of this issue is in `ai_notes/zisk-issues.md` Issue 1.

### Summary

65 ACT4 F/D tests fail (17 F + 48 D), all exit code 101.

The initial theory that "fflags/fcsr always reads 0" was **disproved** by examining RISCOF
signatures. The `RVTEST_SIGUPD_F` macro in RISCOF dev-branch `test_macros.h` stores BOTH
the FP register value AND `csrr fcsr` to the signature region. All 342 RISCOF F/D signatures
match Sail perfectly, including non-zero fcsr values (NX=0x01, UF=0x02, etc.).

### Key Difference: RISCOF vs ACT4 Compilation

| Factor | RISCOF (passes) | ACT4 (fails) |
|--------|-----------------|---------------|
| F-test FLEN | 32 (`-DFLEN=32`) | 64 (`-DFLEN=64`) |
| F-test march | `rv64if_zicsr` | `rv64idf` |
| Test mechanism | Signature dump + comparison | Self-checking ELF (inline `beq`) |
| fcsr clear | `csrw fcsr, reg` | `fsflagsi 0b00000` |

The same Zisk binary is used for both frameworks.

### Leading Hypotheses

1. **FLEN=64 NaN-boxing**: ACT4 compiles F tests with FLEN=64 (config has F+D), changing
   NaN-boxing behavior for single-precision values in 64-bit FP registers
2. **Different test vectors**: ACT4 `-00` tests use random operands not in RISCOF suite
3. **`fsflagsi` vs `csrw fcsr`**: Different CSR clear instruction may behave differently
4. **Self-check mechanism sensitivity**: Inline comparison vs signature dump

### ACT4 Results (Zisk, 2026-02-20)

| Extension | Passed | Failed | Total | Rate |
|-----------|--------|--------|-------|------|
| I | 51 | 0 | 51 | 100% |
| M | 13 | 0 | 13 | 100% |
| F | 25 | 17 | 42 | 59.5% |
| D | 26 | 48 | 74 | 35.1% |
| Misalign | 8 | 0 | 8 | 100% (target only) |
