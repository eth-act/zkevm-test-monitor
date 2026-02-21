# ACT4 Integration Plan for a New ZKVM

This document describes how to integrate ACT4 (RISC-V Architecture Compliance Tests, 4th
generation) self-checking tests for a new ZKVM, using the airbender integration as the
reference implementation.

## Background

ACT4 replaces the legacy RISCOF signature-comparison approach with **self-checking ELFs**.
Expected register values are computed by the Sail reference model at compile time and baked
directly into each test ELF. At runtime the ELF checks its own results and signals pass/fail
via the HTIF `tohost` mechanism: writing `1` means pass, any other nonzero value means fail.
The DUT (device under test) just needs to run the ELF and report the exit code.

### How ACT4 works end-to-end

1. **`uv run make tests EXTENSIONS=I,M,...`** — generates assembly test sources from templates
2. **`uv run act <config_path> --workdir <work> --test-dir tests --extensions I,M,...`** —
   reads a DUT config, generates per-test Makefiles, invokes Sail to compute expected values,
   and produces the compilation rules
3. **`make -C <work>`** — cross-compiles all test sources into self-checking ELFs using the
   DUT's linker script and macros
4. **`python3 run_tests.py "<dut_command>" <elf_dir> -j N`** — runs each ELF by appending its
   path to the DUT command string. Exit code 0 = pass, nonzero = fail.

## What You Need

### 1. ZKVM CLI binary with an ELF runner command

The ZKVM binary must accept a command that:
- Loads a RISC-V ELF (not a flat binary — it needs ELF segment loading)
- Reads the `tohost` symbol address from the ELF symbol table
- Runs the program, periodically polling the `tohost` memory location
- Exits with code 0 if `tohost == 1` (pass), 1 if `tohost != 0 && tohost != 1` (fail),
  2 if cycles exhausted (timeout)

**Airbender reference:** The `run-for-act` subcommand in `tools/cli/src/main.rs` delegates
to `riscv_transpiler::act::run_elf_for_act()`. Key implementation details:

- Uses the `object` crate to parse ELF segments and symbols
- Loads executable segments into an instruction tape (pre-decoded via `preprocess_bytecode`)
- Loads ALL segments (including `.data`, `.tohost`) into RAM
- Uses the entry point from the ELF header (not hardcoded)
- Polls `tohost` every 100K cycles via `ram.peek_word(tohost_addr)`
- Wraps execution in `catch_unwind` to handle panics from unsupported instructions

**For other ZKVMs:** If the ZKVM doesn't have a native ELF runner with HTIF support, you
need to add one. The implementation pattern is:

```
parse ELF → load segments into memory → find tohost symbol → set PC to entry point
→ run in chunks → poll tohost after each chunk → exit with appropriate code
```

If modifying the ZKVM source isn't feasible, a wrapper script could theoretically load the
ELF, extract tohost, run it, and check memory — but this requires the ZKVM to support
reading back memory after execution, which most don't expose.

### 2. ACT4 config directory in `riscv-arch-test/config/<zkvm>/`

Each ZKVM needs one or more config directories under `riscv-arch-test/config/<zkvm>/`.
Each config directory (e.g., `<zkvm>-rv32im/`) contains 6 files:

#### a. `test_config.yaml` — Framework entry point
```yaml
name: <zkvm>-rv32im
compiler_exe: riscv64-unknown-elf-gcc
objdump_exe: riscv64-unknown-elf-objdump
ref_model_exe: sail_riscv_sim
udb_config: <zkvm>-rv32im.yaml        # references the UDB config below
linker_script: link.ld
dut_include_dir: .                     # directory containing rvmodel_macros.h
```

#### b. `<zkvm>-rv32im.yaml` — UDB (Unified Database) config
Declares the ISA extensions and microarchitectural parameters. This is a verbose YAML file
that tells the ACT framework exactly what the ZKVM supports.

Key sections:
- `implemented_extensions`: list of `{ name: X, version: "= Y.Z" }` entries
- `params`: detailed microarchitectural parameters (trap behavior, CSR support, alignment
  handling, endianness, etc.)

**Starting point:** Copy from `config/airbender/airbender-rv32im/airbender-rv32im.yaml` and
adjust:
- Change `name` and `description`
- Modify `MXLEN` (32 or 64)
- Adjust `MISALIGNED_LDST` based on whether the ZKVM supports misaligned loads/stores
- Set trap/CSR parameters to match the ZKVM's actual behavior

#### c. `sail.json` — Sail reference model config
Configures the Sail simulator to match the ZKVM's behavior when generating expected values.
This is a JSON file with sections for `base`, `memory`, `platform`, and `extensions`.

**Key fields to customize:**
- `base.xlen`: 32 or 64
- `memory.misaligned.supported`: true/false
- `memory.regions[0].size`: memory size (e.g., `"0x40000000"` = 1GB)
- `extensions.*`: set `supported: true` for each extension the ZKVM implements

**Starting point:** Copy from `config/airbender/airbender-rv32im/sail.json`.

#### d. `link.ld` — Linker script for test ELFs
Defines the memory layout. Must match where the ZKVM loads code and data.

```ld
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x01000000;                    /* Code start address — must match ZKVM entry point */
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }          /* HTIF tohost/fromhost symbols */
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .data.string : { *(.data.string) }
  . = ALIGN(0x1000);
  .bss : { *(.bss) }
  _end = .;
}
```

**Customization:** Change the base address (`0x01000000`) to match the ZKVM's expected
entry point / code load address.

#### e. `rvmodel_macros.h` — Test harness macros
Defines how the test framework signals pass/fail. The standard pattern uses HTIF:

```c
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .align 8; .global tohost; tohost: .dword 0;         \
        .align 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

#define RVMODEL_BOOT
// No special boot sequence (adjust if the ZKVM needs initialization)

#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  write_tohost_pass:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    j write_tohost_pass   ;\

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  write_tohost_fail:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    j write_tohost_fail   ;\
```

The pass/fail macros write to `tohost` and spin forever. The ZKVM's ELF runner polls
`tohost` and terminates execution when it sees a nonzero value.

**Customization:** If the ZKVM uses a different termination mechanism (e.g., ECALL, a
specific CSR write, a magic memory address), adapt these macros. But HTIF tohost is the
standard and simplest approach.

#### f. `rvtest_config.h` — Preprocessor constants
Minimal file declaring PMP (Physical Memory Protection) parameters:

```c
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
#define RVMODEL_PMP_GRAIN 0
#define RVMODEL_NUM_PMPS 0
```

Most ZKVMs don't implement PMP, so this is usually copied as-is.

### 3. Docker container (`docker/act4-<zkvm>/`)

#### a. `Dockerfile`
Builds the ACT4 test environment. The structure is standardized:

```dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# System deps
RUN apt-get update && apt-get install -y \
    curl git make build-essential ca-certificates xz-utils \
    python3 python3-pip jq && rm -rf /var/lib/apt/lists/*

# uv (Python package manager for riscv-arch-test)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# RISC-V GCC toolchain
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"

# Sail RISC-V simulator (reference model)
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.10/sail-riscv-Linux-x86_64.tar.gz | \
    tar -xz -C /opt/ && mv /opt/sail-riscv-Linux-x86_64 /opt/sail-riscv
ENV PATH="/opt/sail-riscv/bin:${PATH}"

# Clone riscv-arch-test act4 branch
ARG ARCH_TEST_COMMIT=act4
WORKDIR /act4
RUN git clone --branch act4 --single-branch \
        https://github.com/riscv-non-isa/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt

# Initialize UDB submodule (required for config schema validation)
RUN git submodule update --init external/riscv-unified-db

# Pre-generate test assembly sources (slow step, baked into image)
# Adjust EXTENSIONS to match what the ZKVM supports
RUN uv run make tests EXTENSIONS=I,M

RUN mkdir -p /dut /results
COPY entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
```

**Customization per ZKVM:**
- The `EXTENSIONS=I,M` in `make tests` should list all extensions the ZKVM supports
- If the ZKVM needs Misalign tests, add `Misalign` to the list
- The Dockerfile is identical across ZKVMs except for the extensions list

#### b. `entrypoint.sh`
Runs when the container starts. It:

1. Verifies the DUT binary is mounted at `/dut/<zkvm>-binary`
2. For each config (native ISA, target profile):
   - Pre-generates `extensions.txt` to skip UDB validation (avoids needing Docker-in-Docker)
   - Runs `uv run act <config> --workdir <work> --test-dir tests --extensions <list>` to
     generate Makefiles
   - Runs `make -C <work>` to compile self-checking ELFs
   - Runs `python3 run_tests.py "<dut_command>" <elf_dir> -j N` to execute tests
   - Parses `run_tests.py` output to extract pass/fail counts
   - Writes `summary-act4.json` and `results-act4.json` to `/results/`

**Key pattern — the `run_act4_suite` function:**

```bash
run_act4_suite() {
    local CONFIG="$1"       # e.g. "config/<zkvm>/<zkvm>-rv32im/test_config.yaml"
    local CONFIG_NAME="$2"  # e.g. "<zkvm>-rv32im"
    local EXTENSIONS="$3"   # e.g. "I,M"
    local EXT_TXT="$4"      # newline-separated extension list for extensions.txt
    local SUFFIX="$5"       # "" for native, "-target" for target profile

    # Pre-generate extensions.txt to bypass UDB validation
    mkdir -p "$WORKDIR/$CONFIG_NAME"
    echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
    touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

    # Generate Makefiles + compile ELFs
    uv run act "$CONFIG" --workdir "$WORKDIR" --test-dir tests --extensions "$EXTENSIONS"
    make -C "$WORKDIR"

    # Run tests — the DUT command gets the ELF path appended by run_tests.py
    RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT run-for-act" "$ELF_DIR" -j "$JOBS" 2>&1) || true

    # Parse results and write JSON summaries
    # ...
}
```

**Customization per ZKVM:**
- Change the DUT binary path and command. The key line is:
  ```
  python3 /act4/run_tests.py "$DUT <run-command>" "$ELF_DIR" -j "$JOBS"
  ```
  Where `<run-command>` is the ZKVM's subcommand for running ELFs (e.g., `run-for-act`).
  `run_tests.py` appends the ELF path to this command string.
- Change config paths to reference the ZKVM's config directory
- Adjust the extension lists for each suite

### 4. Test monitor integration (`src/test.sh`, `run`, `src/update.py`)

These changes were done once for the whole framework and should work for any ZKVM.
The `--act4` flag was added alongside `--arch` and `--extra`. The ACT4 code path in
`src/test.sh`:

- Builds the Docker image from `docker/act4-<zkvm>/`
- Mounts the ZKVM binary, config dir, and results dir
- Runs the container
- Reads the summary/results JSON files the container writes
- Appends to history and triggers dashboard regeneration

The dashboard generator (`src/update.py`) reads `test-results/<zkvm>/summary-act4.json`
and `results-act4.json` to populate the ACT4 dashboard page.

**What needs changing per ZKVM:**
- Currently `src/test.sh` hardcodes `if [ "$ZKVM" != "airbender" ]` — this needs to be
  generalized to support multiple ZKVMs. The Docker image name, config mount path, and
  DUT binary mount path are the ZKVM-specific parts.

## Step-by-step Checklist for Adding a New ZKVM

### Prerequisites
- [ ] The ZKVM can execute RV32IM (or RV64IM) ELFs
- [ ] The ZKVM has (or can be given) a command that loads an ELF and checks HTIF tohost

### ZKVM-side changes (in the ZKVM's own repo)
- [ ] Add a `run-for-act` (or equivalent) CLI command that:
  - Parses ELF segments and loads them into memory
  - Reads `tohost` symbol address from ELF symbol table
  - Runs the program, polling `tohost` periodically
  - Exits 0 (pass), 1 (fail), or 2 (timeout)
- [ ] Ensure unknown/unsupported opcodes don't panic during decode — they should be treated
  as illegal instructions (ACT4 test ELFs may contain inline data in non-executable segments)
- [ ] Build the ZKVM binary and place it at `binaries/<zkvm>-binary`

### riscv-arch-test config (in the `riscv-arch-test` repo, `act4` branch)
- [ ] Create `config/<zkvm>/` directory
- [ ] Create `config/<zkvm>/<zkvm>-rv32im/` (or appropriate ISA profile) containing:
  - [ ] `test_config.yaml` — entry point referencing all other files
  - [ ] `<zkvm>-rv32im.yaml` — UDB config declaring supported extensions and parameters
  - [ ] `sail.json` — Sail reference model configuration
  - [ ] `link.ld` — linker script matching the ZKVM's memory layout
  - [ ] `rvmodel_macros.h` — HTIF tohost pass/fail macros
  - [ ] `rvtest_config.h` — PMP parameters (usually no PMP)
- [ ] Optionally create a second config for the ETH-ACT target profile (rv64im-zicclsm)

### Test monitor changes (in `zkevm-test-monitor`)
- [ ] Create `docker/act4-<zkvm>/Dockerfile` (copy from airbender, adjust extensions)
- [ ] Create `docker/act4-<zkvm>/entrypoint.sh` (copy from airbender, adjust paths/commands)
- [ ] Update `src/test.sh` to handle the new ZKVM in the ACT4 code path
- [ ] Test: `./run test --act4 <zkvm>`
- [ ] Verify JSON outputs in `test-results/<zkvm>/`
- [ ] Run `./run update` and check the ACT4 dashboard

## Common Pitfalls

1. **Decoder panics on unknown opcodes:** ACT4 test ELFs contain inline data (failure codes,
   metadata) that gets loaded into memory. If the ZKVM's decoder panics on unrecognized bit
   patterns instead of treating them as illegal instructions, tests will crash during decode.
   The fix is to return an Illegal instruction marker instead of panicking.

2. **Entry point mismatch:** The linker script's base address must match where the ZKVM
   expects code to start. For airbender this is `0x01000000`. Check the ZKVM's memory map.

3. **tohost section placement:** The `.tohost` section must be in a writable, accessible
   memory region. If it's placed in ROM or outside the ZKVM's address space, tests can't
   signal pass/fail.

4. **extensions.txt generation:** Without pre-generating `extensions.txt`, the ACT framework
   tries to run UDB validation via Podman/Docker inside the container, which fails. The
   workaround is writing extensions.txt manually with a future timestamp.

5. **Misaligned access support:** If the ZKVM claims `MISALIGNED_LDST: true` in the UDB
   config but doesn't actually support misaligned loads/stores, tests will fail. Be honest
   about the ZKVM's capabilities.

6. **The DUT command string:** `run_tests.py` calls `shlex.split(command)` and appends the
   ELF path. So if your DUT command is `"/dut/my-binary run-for-act"`, the actual invocation
   is `["/dut/my-binary", "run-for-act", "/path/to/test.elf"]`. Make sure the ZKVM CLI
   accepts a positional ELF argument after the subcommand.
