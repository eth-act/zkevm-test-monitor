# ACT4 Integration: End-to-End Flow

How ACT4 (Architecture Compliance Test v4) is integrated into zkevm-test-monitor.

Source: [riscv-non-isa/riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test),
branch `act4`. Symlinked locally at `riscv-arch-test/`.

## What ACT4 Is

ACT4 produces **self-checking ELFs**. At compile time, the Sail RISC-V reference
model runs each test and computes expected register values. These are embedded
into the ELF as `.word` directives. At run time, the test compares actual vs
expected inline and exits 0 (pass) or non-zero (fail). No signature extraction.

## Self-Checking ELF Structure

### Sections

| Section | Perms | Contents |
|---------|-------|----------|
| `.text.init` | RX | Entry point (`rvtest_entry_point`), test code, failure handlers |
| `.tohost` | RW | HTIF halt signal region (used by some ZKVMs) |
| `.data` | RW | Sail-generated expected values, canaries, trap handler save areas |
| `.bss` | RW | Scratch space |

### How self-checking works

Each test instruction is followed by a `RVTEST_SIGUPD` macro
(`riscv-arch-test/tests/env/signature.h:18-25`) that expands to:

```asm
lw   x4, 0(x2)                   # load expected value from .data (Sail output)
beq  x4, x28, 1f                 # compare expected vs actual result
jal  x5, failedtest_x5_x4        # mismatch → jump to failure handler
.word <test_name_string_ptr>      # (data word embedded in code stream)
1:
addi x2, x2, 4                   # advance signature pointer
```

On mismatch, the failure handler records diagnostic info and calls
`RVMODEL_HALT_FAIL` (exit non-zero). If all comparisons pass, execution
reaches `RVMODEL_HALT` (exit 0).

### How expected values get baked in

All orchestrated by generated Makefiles (`framework/src/act/makefile_gen.py:95-176`):

1. **First compile** with `-DSIGNATURE` — `RVTEST_SIGUPD` is in "store" mode,
   test writes results to memory → `test.sig.elf` (makefile_gen.py:137-149)
2. **Sail runs** the sig ELF, dumps the signature memory region →
   **`test.sig`** (makefile_gen.py:150-157). This is raw hex, one value per
   line (e.g. `12345678`). Not valid assembly.
3. **`sig_modify.py`** (`framework/src/act/sig_modify.py:14-22`) prepends
   `.word`/`.quad` directives → **`test.results`** (e.g. `.word 0x12345678`).
   This is valid assembly that can be `#include`d into a `.S` file.
4. **Recompile** with `-DRVTEST_SELFCHECK -DSIGNATURE_FILE="test.results"`
   (makefile_gen.py:167). `RVTEST_SIG_SETUP` (`tests/env/test_setup.h:248-250`)
   `#include`s the `.results` file into `.data`; `RVTEST_SIGUPD`
   (`tests/env/signature.h:18-25`) switches to "compare" mode

These are **build-time intermediates** only. The final ELF is self-contained —
the DUT never produces or reads signature files. (The SELFCHECK macro only
loads and compares; it doesn't store actual values back to memory.)

This is why `sail.json` must match the DUT's behavior — wrong Sail config
produces wrong expected values.

### Why some ZKVMs need `patch_elfs.py`

The expected values from `test.results` end up in `.data` (harmless). But the
`RVTEST_SIGUPD` macro embeds `.word <string_ptr>` data words directly in the
`.text.init` code stream (signature.h:23, right after each `jal` to the failure
handler). ZKVMs that pre-process all words in executable segments as instructions
(SP1, Pico, OpenVM) try to decode these data words and panic. `patch_elfs.py`
replaces non-instruction words in executable sections with NOPs (`0x00000013`).

Zisk has a different problem. When a sub-test fails, the ACT4 failure handler
(`failedtest_saveresults` in `failure_code.h:72-125`) does post-mortem
disassembly: it reads raw instruction bytes backwards from the return address
via `lhu` to reconstruct which instruction failed, which registers were
involved, and what the actual vs expected values were. This requires *reading*
from `.text.init` — but Zisk's emulator transpiles executable sections into
its internal instruction format and never maps them into readable memory
(`zisk/core/src/elf_extraction.rs:101-125`, `elf2rom.rs:29-50`). This isn't a
linker script choice we could change; it's fundamental to Zisk's architecture
(instructions live in a ROM HashMap, not in addressable memory).

`patch_elfs.py --zisk` replaces the first instruction of
`failedtest_saveresults` with `JAL x0, failedtest_terminate` — skipping all
the `lhu` reads and jumping straight to `RVMODEL_HALT_FAIL` (exit non-zero).
The test still correctly reports failure; you just lose the diagnostic detail
about which sub-test failed. (This is moot anyway since `RVMODEL_IO_WRITE_STR`
is a no-op for all ZKVMs.)

## Build Pipeline

### Docker image (`docker/<zkvm>/Dockerfile`)

Each ZKVM's test image (~3-4 GB) bundles:
- **RISC-V GCC** (`riscv64-elf-*`)
- **Sail RISC-V** (`sail_riscv_sim`)
- **uv** + **riscv-arch-test** (act4 branch) cloned into `/act4/`
- **UDB submodule** (`external/riscv-unified-db`) — external RISC-V project
  for config schema validation

The Dockerfile also:
- Patches `tests/env/test_setup.h` to remove `.option rvc` (which would set
  `EF_RISCV_RVC` in the ELF header, causing SP1/Pico/OpenVM to attempt 16-bit
  instruction decoding on tests that are all 32-bit)
- Pre-generates assembly sources (`uv run make tests EXTENSIONS=...`) so this
  slow step is cached in the Docker layer

### DUT config files (`act4-configs/<zkvm>/<isa>/`)

| File | Purpose |
|------|---------|
| `test_config.yaml` | Points to compiler, Sail, UDB config, linker script, macros dir |
| `<name>.yaml` | UDB config: declared extensions, MXLEN, misalign behavior |
| `sail.json` | Sail config: memory regions, platform params, extension flags |
| `rvmodel_macros.h` | Halt protocol assembly (ZKVM-specific) |
| `link.ld` | Memory layout, entry point, tohost section |

## Test Pipeline

### Entry point: `./run test [zkvm...]`

`run` delegates to `src/test.sh`. Environment variables:
- `JOBS` — Docker CPU cores (`--cpuset-cpus=0-N`), also default for `ACT4_JOBS`
- `ACT4_JOBS` — parallelism inside the container (`make -j`, `run_tests.py -j`)

### Container execution

```bash
docker build -t "${ZKVM}:latest" -f "docker/${ZKVM}/Dockerfile" .
docker run --rm \
  -v binaries/${ZKVM}-binary:/dut/${ZKVM}-binary \
  -v act4-configs/${ZKVM}:/act4/config/${ZKVM} \
  -v test-results/${ZKVM}:/results \
  ${ZKVM}:latest
```

### Inside the container (`docker/<zkvm>/entrypoint.sh`)

Each entrypoint calls `run_act4_suite` twice:
1. **Full ISA** — ZKVM's native extensions (e.g. `I,M` for SP1). Label: `full-isa`.
2. **Standard ISA** — ETH-ACT target profile (`I,M,Misalign`). Label: `standard-isa`.

`run_act4_suite` does:

1. **Pre-write `extensions.txt`** with a future timestamp to skip UDB validation
   (can't run Docker-in-Docker)
2. **`uv run act`** — reads DUT config, matches tests to declared extensions,
   generates Makefiles
3. **`make -j`** — for each test: run Sail to get expected values, compile
   self-checking ELF (see "How expected values get baked in" above)
4. **`patch_elfs.py`** — if needed (SP1/Pico/OpenVM: default mode; Zisk: `--zisk`)
5. **`run_tests.py`** — runs each ELF through the DUT wrapper (`/act4/run-dut.sh`),
   captures exit codes, 5-min timeout, parallel execution
6. **Parse results** — writes `summary-act4-*.json` and `results-act4-*.json`
   to `/results/`

### DUT wrapper examples

Each entrypoint creates `/act4/run-dut.sh` to adapt the generic "run this ELF"
call to the ZKVM's CLI:

```bash
# Zisk — simplest
/dut/zisk-binary -e "$1" > /dev/null

# SP1 — needs dummy stdin, uses proving mode
printf '\x00%.0s' {1..24} > "$TMPDIR/stdin.bin"
/dut/sp1-binary --program "$1" --param "$TMPDIR/stdin.bin" --mode node --local

# Airbender — needs flat binary + address extraction
riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"
/dut/airbender-binary run-with-transpiler --bin "$BIN" --entry-point $ENTRY ...
```

## Results and Dashboard

### Result files

Each suite produces two JSON files in `test-results/<zkvm>/`:
- `summary-act4-<full-isa|standard-isa>.json` — pass/fail/total counts
- `results-act4-<full-isa|standard-isa>.json` — per-test pass/fail list

### History tracking (`src/test.sh`)

After the container exits, `test.sh` appends a run entry to
`data/history/<zkvm>-act4.json` with date, commits, and counts.

### Dashboard (`src/update.py`)

`uv run --with pyyaml src/update.py` generates static HTML into `docs/`:
- `index.html` — main ACT4 dashboard
- `act4/<zkvm>.html` / `act4/<zkvm>-target.html` — per-ZKVM detail pages
- `zkvms/<zkvm>.html` — ZKVM info pages

## Key Invariants

1. **Exit code is the only signal.** No registers, memory, or signatures inspected.
2. **Sail runs at compile time, not run time.** Sail config must match DUT behavior.
3. **Two suites per ZKVM.** Full-ISA (native) and Standard-ISA (cross-ZKVM comparison).
4. **`patch_elfs.py` is required for SP1/Pico/OpenVM.** Their transpilers decode data words.
5. **DUT wrapper must propagate exit codes.** Swallowed exits hide failures.
6. **Execution mode matters.** JIT may handle instructions the prover can't
   (e.g. SP1 FENCE → UNIMP). Use proving-path modes when possible.
