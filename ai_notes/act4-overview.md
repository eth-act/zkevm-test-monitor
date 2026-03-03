# ACT4 Integration: End-to-End Flow

How the ACT4 (Architecture Compliance Test v4) framework is integrated into
zkevm-test-monitor, from `./run test` to dashboard HTML.

## What ACT4 is

ACT4 produces **self-checking ELFs**. At compile time, the Sail RISC-V reference
model runs each test and computes expected register/memory values. These values
are embedded directly into the ELF as inline assertions. At run time, the test
checks its own results and exits 0 (pass) or non-zero (fail). There is no
signature file extraction — pass/fail is determined entirely by the exit code.

Source: [riscv-non-isa/riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test),
branch `act4`. Symlinked locally at `riscv-arch-test/`.

## Sequential Flow

### 1. Entry point: `./run test [zkvm...]`

File: `run` (root)

Parses the command and delegates to `src/test.sh`. If no ZKVM is specified, all
ZKVMs from `config.json` are tested. Environment variables:
- `JOBS` — limit Docker CPU cores
- `ACT4_JOBS` — override parallelism inside the container

### 2. Build the test Docker image

File: `src/test.sh` (lines ~40-50)

```bash
docker build -t "${ZKVM}:latest" -f "docker/${ZKVM}/Dockerfile" .
```

Each ZKVM has its own Dockerfile at `docker/<zkvm>/Dockerfile`. These images
are heavyweight (~3-4 GB) because they bundle the full toolchain:

- **RISC-V GCC** (`riscv64-elf-*`) — cross-compiler for test ELFs
- **Sail RISC-V simulator** (`sail_riscv_sim`) — reference model for computing
  expected values at compile time
- **uv** — Python package manager used by the `act` CLI
- **riscv-arch-test repo** (act4 branch) — cloned into `/act4/` inside the image
- **UDB submodule** (`external/riscv-unified-db`) — config schema validation

The Dockerfile also:
- Patches `tests/env/test_setup.h` to remove `.option rvc` (prevents ELFs from
  getting the `EF_RISCV_RVC` flag, which causes some ZKVMs to misparse them)
- Pre-generates assembly test sources (`uv run make tests EXTENSIONS=...`) so
  this slow step is cached in the Docker layer
- Copies `docker/shared/patch_elfs.py` and `docker/<zkvm>/entrypoint.sh`

Reference Dockerfile: `docker/sp1/Dockerfile`

### 3. Run the test container

File: `src/test.sh` (lines ~55-75)

```bash
docker run --rm \
  -v binaries/${ZKVM}-binary:/dut/${ZKVM}-binary \
  -v act4-configs/${ZKVM}:/act4/config/${ZKVM} \
  -v test-results/${ZKVM}:/results \
  ${ZKVM}:latest
```

Three bind mounts:
| Mount | Host path | Container path | Purpose |
|-------|-----------|----------------|---------|
| DUT binary | `binaries/<zkvm>-binary` | `/dut/<zkvm>-binary` | The ZKVM executor to test |
| ACT4 configs | `act4-configs/<zkvm>/` | `/act4/config/<zkvm>/` | DUT-specific ISA/platform configs |
| Results | `test-results/<zkvm>/` | `/results/` | Output directory for JSON results |

### 4. Inside the container: entrypoint.sh

File: `docker/<zkvm>/entrypoint.sh`

Each entrypoint runs two test suites by calling `run_act4_suite` twice:

1. **Full ISA** (native) — tests the ZKVM's actual ISA (e.g., `I,M` for SP1;
   `I,M,F,D,Zca,...` for Zisk). File label: `full-isa`.
2. **Standard ISA** (target) — tests the ETH-ACT target profile
   (`I,M,Misalign` / `rv64im-zicclsm`). File label: `standard-isa`.

The `run_act4_suite` function performs steps 5-10 below.

### 5. Pre-generate extensions.txt

File: `docker/<zkvm>/entrypoint.sh`, inside `run_act4_suite()`

```bash
echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"
```

The ACT framework normally calls UDB (via Podman/Docker) to validate the
config and generate `extensions.txt`. Since we're already inside a container,
we pre-write this file with a future timestamp so the framework skips UDB
validation.

### 6. Generate Makefiles: `uv run act`

File: `docker/<zkvm>/entrypoint.sh`

```bash
uv run act "$CONFIG" \
    --workdir "$WORKDIR" \
    --test-dir tests \
    --extensions "$EXTENSIONS"
```

The `act` CLI (defined in `riscv-arch-test/pyproject.toml`, entry point
`framework/src/act/act.py:main`) reads the DUT config and:

1. Loads `test_config.yaml` to find the compiler, objdump, Sail binary,
   UDB config, linker script, and macro include directory
2. Reads the UDB config (`<name>.yaml`) to determine which extensions and
   behaviors the DUT declares
3. Matches available tests against the DUT's declared capabilities
4. Generates Makefiles that will compile each test into a self-checking ELF

The config files live in `act4-configs/<zkvm>/<isa>/`:

| File | Purpose |
|------|---------|
| `test_config.yaml` | Top-level ACT config: points to tools + other config files |
| `<name>.yaml` | UDB config: declared extensions, MXLEN, misalign behavior, etc. |
| `sail.json` | Sail simulator config: memory regions, platform params, extension flags |
| `rvmodel_macros.h` | DUT halt protocol (how to exit with pass/fail code) |
| `link.ld` | Linker script (memory layout, entry point, tohost section) |

### 7. Compile ELFs: `make`

```bash
make -C "$WORKDIR" -j "$JOBS"
```

The generated Makefiles:
1. Invoke Sail (`sail_riscv_sim`) for each test to compute expected register
   values. Sail reads `sail.json` for memory/platform config.
2. Compile each test's assembly source with `riscv64-unknown-elf-gcc`, linking
   against the DUT's `link.ld` and including `rvmodel_macros.h`
3. Expected values from Sail are baked into the ELF as `.word` directives in
   the SELFCHECK sections

Output: `$WORKDIR/$CONFIG_NAME/elfs/<isa>/<ext>/<test>.elf`

Note: ELFs for the same ISA config are shared across suites via symlinks to
`$WORKDIR/common/<hash>/elfs/`.

### 8. Post-process ELFs: `patch_elfs.py`

File: `docker/shared/patch_elfs.py`

```bash
python3 /act4/patch_elfs.py "$ELF_DIR"          # default mode
python3 /act4/patch_elfs.py --zisk "$ELF_DIR"   # zisk mode
```

Some ZKVMs pre-process every word in loadable ELF segments as an instruction
during transpilation. The SELFCHECK sections contain `.word` directives (data,
not code) that can't be decoded as valid instructions, causing panics.

**Default mode** (used by SP1, Pico, OpenVM):

Walks every loadable segment, identifies words that are NOT valid RV32/RV64
instructions (using opcode analysis), and replaces them with `ADDI x0, x0, 0`
(NOP = `0x00000013`). This is safe because these words are data that is
referenced by address, not by position relative to the executing code.

**Zisk mode** (`--zisk` flag):

Different problem: Zisk maps `.text.init` as execute-only (no read permission).
The ACT4 failure handler (`failedtest_saveresults`) reads instruction bytes
via `lhu` with negative offsets to record which instruction failed. On Zisk this
causes a fault. The patch replaces the first instruction of
`failedtest_saveresults` with a `JAL x0, failedtest_terminate`, skipping the
byte-reading code and jumping directly to the exit sequence. Failure semantics
are preserved (exit code remains non-zero).

**Airbender, Jolt, r0vm, Zisk**: Airbender and r0vm don't need the default
patch (they don't pre-process data words). Jolt doesn't need it either. Zisk
uses its own mode.

### 9. Run tests: `run_tests.py`

File: `riscv-arch-test/run_tests.py` (copied into container)

```bash
python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS"
```

The test runner:
1. Finds all `.elf` files recursively under `$ELF_DIR`
2. For each ELF, calls the DUT wrapper script with the ELF path as argument
3. Runs tests in parallel (`-j` flag) with a 5-minute timeout per test
4. Captures exit code: 0 = pass, non-zero = fail
5. Writes per-test logs to `$ELF_DIR/../logs/`
6. Prints summary: `All N tests passed.` or `X out of N tests failed.`

### 10. DUT wrapper scripts

Each entrypoint creates `/act4/run-dut.sh`, a wrapper that translates the
generic "run this ELF" call into the ZKVM's specific CLI:

**SP1** (`docker/sp1/entrypoint.sh`):
```bash
printf '\x00%.0s' {1..24} > "$TMPDIR/stdin.bin"
/dut/sp1-binary --program "$1" --param "$TMPDIR/stdin.bin" --mode node --local
```
Needs a dummy stdin file. Uses `--mode node` to exercise the full proving
pipeline (not just execution).

**Airbender** (`docker/airbender/entrypoint.sh`):
```bash
riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"
# extract entry point and tohost address from ELF headers
/dut/airbender-binary run-with-transpiler \
    --bin "$BIN" --entry-point $ENTRY --tohost-addr $TOHOST --cycles 10000000
```
Requires flat binary conversion and explicit entry/tohost addresses.

**Zisk** (`docker/zisk/entrypoint.sh`):
```bash
/dut/zisk-binary -e "$1" > /dev/null
```
Simplest wrapper. Suppresses verbose stdout; exit code determines pass/fail.

### 11. Result parsing and JSON output

File: `docker/<zkvm>/entrypoint.sh`, end of `run_act4_suite()`

After `run_tests.py` completes, the entrypoint parses its stdout:

```bash
FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | ...)
TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | ...)
PASSED=$((TOTAL - FAILED))
```

Writes two JSON files to `/results/` (bind-mounted to `test-results/<zkvm>/`):

**`summary-act4-<full-isa|standard-isa>.json`**:
```json
{"zkvm": "sp1", "suite": "act4", "timestamp": "...", "passed": 62, "failed": 2, "total": 64}
```

**`results-act4-<full-isa|standard-isa>.json`**:
```json
{"zkvm": "sp1", "suite": "act4", "tests": [
    {"name": "I-add-00", "extension": "I", "passed": true},
    {"name": "I-fence-00", "extension": "I", "passed": false}, ...
]}
```

The per-test JSON is built by an inline Python script that walks the ELF
directory, cross-references against failed test names from `run_tests.py`
output, and includes a safety check: if the parsed pass count doesn't match
the authoritative count (e.g., due to timeouts/OOM kills), all tests are
conservatively marked as failed.

### 12. History tracking

File: `src/test.sh` (lines ~80-160)

Back on the host, `test.sh` reads the summary JSONs and appends a run entry
to `data/history/<zkvm>-act4.json` and `data/history/<zkvm>-act4-target.json`:

```json
{"runs": [{"date": "2026-03-03", "test_monitor_commit": "4333acdf",
           "zkvm_commit": "213fc1ab", "passed": 62, "failed": 2, "total": 64, ...}]}
```

### 13. Dashboard generation

File: `src/update.py`

```bash
uv run --with pyyaml src/update.py
```

Reads `data/results.json` (aggregated), `data/history/*.json`, and per-ZKVM
result files. Generates static HTML:

| File | Content |
|------|---------|
| `docs/index.html` | ACT4 dashboard (main landing page) |
| `docs/index-extra.html` | Extra tests dashboard |
| `docs/index-arch.html` | Legacy RISCOF dashboard |
| `docs/act4/<zkvm>.html` | Per-ZKVM full-ISA detail page |
| `docs/act4/<zkvm>-target.html` | Per-ZKVM standard-ISA detail page |
| `docs/zkvms/<zkvm>.html` | ZKVM info page |
| `docs/reports/<zkvm>-arch.html` | Architecture report |

## Config Files Reference

### `config.json`
ZKVM registry. Each entry has `repo_url`, `commit`, `build_cmd`,
`binary_name`, `binary_path`. Used by `src/build.sh` to build binaries and
by `src/update.py` for dashboard metadata.

### `act4-configs/<zkvm>/<isa>/test_config.yaml`
Top-level ACT config. Points to compiler executables, Sail binary, UDB config
file, linker script, and include directory for `rvmodel_macros.h`.

### `act4-configs/<zkvm>/<isa>/<name>.yaml`
UDB (Unified Database) config. Declares which extensions the DUT implements,
architecture parameters (MXLEN, misaligned access behavior, etc.), and
behavioral choices. The ACT framework uses this to select which tests apply.

### `act4-configs/<zkvm>/<isa>/sail.json`
Sail RISC-V simulator configuration. Defines memory regions (base address,
size, access permissions, reservability), platform parameters (clock, CLINT),
and extension support flags. Critical settings:
- Memory region must cover the ELF's load address (from `link.ld`)
- `reservability` must be `RsrvEventual` if LR/SC tests are included
- Extension `supported` flags must match the UDB config

### `act4-configs/<zkvm>/<isa>/rvmodel_macros.h`
DUT-specific halt protocol. Defines `RVMODEL_HALT` (and its pass/fail
variants). Different ZKVMs use different halt mechanisms:
- SP1/Pico: write exit code to `t0` (x5), then `ecall`
- Zisk: write 93 to `a7`, exit code to `a0`, then `ecall`
- OpenVM: write exit code to custom halt opcode `0x0b`
- Airbender: write exit code to `tohost` memory address

### `act4-configs/<zkvm>/<isa>/link.ld`
Linker script. Sets base load address, section layout, entry point, and
`tohost` section location. Base address varies by ZKVM:
- SP1: `0x78000000` (must be >= STACK_TOP)
- Zisk: `0xa0000000` (Zisk RAM region)
- Airbender: `0x01000000` (custom layout)

## Key Invariants

1. **Exit code is the only signal.** ACT4 tests are self-checking. The test
   monitor never inspects registers, memory, or signatures. Exit 0 = pass.

2. **Sail runs at compile time, not run time.** Expected values are baked into
   ELFs. The Sail config must match the DUT's actual behavior or tests will
   have wrong expected values.

3. **Two suites per ZKVM.** Full-ISA tests the ZKVM's native capabilities.
   Standard-ISA tests the ETH-ACT target profile for cross-ZKVM comparison.

4. **patch_elfs.py is not optional for some ZKVMs.** SP1, Pico, and OpenVM
   will panic on unpatched ELFs because their transpilers try to decode data
   words as instructions.

5. **The DUT wrapper must propagate exit codes.** If the wrapper swallows
   non-zero exits (e.g., via `set -e` without `|| true`), failures become
   invisible.

6. **Execution mode matters.** Some ZKVMs have separate execution and proving
   paths. An instruction may execute fine but crash the prover (e.g., SP1's
   FENCE → UNIMP, which passes in JIT mode but fails in the splicing executor).
   Use a mode that exercises the proving pipeline when possible.
