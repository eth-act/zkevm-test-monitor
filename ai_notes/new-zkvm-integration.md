# Integrating a New ZKVM

What a ZKVM needs to provide — and what you need to create in this repo — to
run ACT4 compliance tests against it.

## What the ZKVM Must Provide


```
config.json                                    # Add your ZKVM entry here
docker/
  build-myzkvm/
    Dockerfile                                 # Builds binary from source
  myzkvm/
    Dockerfile                                 # Test runner image (toolchain + ACT4)
    entrypoint.sh                              # Test orchestrator + DUT wrapper
act4-configs/
  myzkvm/
    myzkvm-rv64im/                             # Native ISA config
      test_config.yaml                         # Points to tools + other configs
      myzkvm-rv64im.yaml                       # UDB config: declared extensions
      sail.json                                # Sail simulator: memory, extensions
      rvmodel_macros.h                         # Halt protocol (assembly macros)
      link.ld                                  # Linker script (memory layout)
    myzkvm-rv64im-zicclsm/                     # ETH-ACT target profile config
      test_config.yaml                         # (same structure, different extensions)
      myzkvm-rv64im-zicclsm.yaml
      sail.json
      rvmodel_macros.h                         # (usually identical to native)
      link.ld                                  # (usually identical to native)
```

### 1. A deterministic executor binary

The binary must:

- Accept an ELF file (or flat binary) as input
- Execute the program to completion
- **Exit with the guest program's exit code** (0 = pass, non-zero = fail)

The binary can have any CLI interface — you'll write a small wrapper script to
adapt it. Examples of how existing ZKVMs are invoked (see each ZKVM's
`docker/<zkvm>/entrypoint.sh` for the full wrapper, specifically the
`cat > /act4/run-dut.sh` section):

```bash
# Simple: just takes an ELF
ziskemu -e "$ELF"
jolt-emu "$ELF"
openvm-binary "$ELF"

# Needs flags
r0vm-binary --elf "$ELF" --execute-only

# Needs dummy stdin
sp1-binary --program "$ELF" --param stdin.bin --mode node --local

# Needs ELF-to-binary conversion + address extraction
riscv64-unknown-elf-objcopy -O binary "$ELF" "$BIN"
airbender-binary run-with-transpiler --bin "$BIN" --entry-point 0x1000000 ...
```

### 2. A halt mechanism

The test framework needs a way to tell the ZKVM "stop and report this exit
code." This is defined in `rvmodel_macros.h` and varies widely:

| Mechanism | Used by | How it works |
|-----------|---------|--------------|
| `ecall` with t0 (x5) | SP1, Pico | Write 0 to t0 (syscall "halt"), exit code in a0 |
| `ecall` with a7=93 | Zisk | Linux-style exit syscall, exit code in a0 |
| HTIF (tohost) | Airbender | Write to memory-mapped `tohost` address |
| Custom opcode 0x0b | OpenVM | `.insn i 0x0b, 0, x0, x0, <code>` |
| `ecall` with a7=93 | r0vm | Same as Zisk convention |

If your ZKVM uses a standard mechanism (ecall, HTIF), you can likely copy an
existing `rvmodel_macros.h`. If it uses something custom, you'll need to write
assembly macros.

### 3. A known memory layout

You need to know:

- **Where code can be loaded** — some ZKVMs enforce minimum addresses (e.g.,
  SP1 v6 requires `>= 0x78000000`)
- **Where data can live** — some ZKVMs have separate regions (e.g., Zisk
  requires data in `0xa0000000-0xc0000000`)
- **Whether the ZKVM pre-processes all words as instructions** — if so, data
  words in the ELF will need to be patched to NOPs (SP1, Pico, OpenVM)
- **Whether code segments are execute-only** — if so, the ACT4 failure handler
  may need patching (Zisk)

### 4. The supported ISA

Know exactly which RISC-V extensions your ZKVM implements:

- **Base**: RV32I or RV64I
- **Standard extensions**: M (multiply/divide), A (atomics), F (float),
  D (double), C (compressed)
- **Fine-grained extensions**: Zaamo, Zalrsc (if A is partial), Zca, Zcf, Zcd
  (if C is partial)
- **Privilege**: Zicsr (CSR access), Sm (machine mode)
- **Memory**: Misaligned load/store support, Zicclsm

This determines which tests will be generated and what Sail will expect.

## What You Create in This Repo

### Step 1: Add to `config.json`

```json
{
  "zkvms": {
    "myzkvm": {
      "repo_url": "https://github.com/org/myzkvm",
      "commit": "abc123",
      "build_cmd": "cargo build --release -p myzkvm-cli",
      "binary_name": "myzkvm-binary",
      "binary_path": "target/release/myzkvm-cli"
    }
  }
}
```

### Step 2: Create the build Dockerfile

File: `docker/build-myzkvm/Dockerfile`

This builds the ZKVM binary from source inside Docker. The contract:

- Accept `REPO_URL` and `COMMIT_HASH` build args
- Clone the repo, checkout the commit, build
- Place the final binary at `/usr/local/bin/<binary_name>`
- Write the actual commit hash to `/commit.txt`

`src/build.sh` will extract the binary from the image via
`docker cp` and place it in `binaries/myzkvm-binary`.

Example (simple Rust project):

```dockerfile
FROM rust:1.82-bookworm AS builder

RUN apt-get update && apt-get install -y build-essential pkg-config libssl-dev

ARG REPO_URL
ARG COMMIT_HASH

WORKDIR /build
RUN git clone "$REPO_URL" . && git checkout "$COMMIT_HASH"
RUN echo "$(git rev-parse HEAD)" > /commit.txt
RUN cargo build --release -p myzkvm-cli

FROM debian:bookworm-slim
COPY --from=builder /build/target/release/myzkvm-cli /usr/local/bin/myzkvm-binary
COPY --from=builder /commit.txt /commit.txt
```

### Step 3: Create ACT4 config directory

Directory: `act4-configs/myzkvm/<isa>/`

You need one config directory per ISA profile. Most ZKVMs have two:
- `myzkvm-rv64im/` (or `rv32im`) — native ISA
- `myzkvm-rv64im-zicclsm/` — ETH-ACT target profile

Each directory contains 5-6 files:

#### `test_config.yaml`

Points the ACT framework to all other config files. Copy from an existing ZKVM
and adjust the name:

```yaml
name: myzkvm-rv64im
compiler_exe: riscv64-unknown-elf-gcc
objdump_exe: riscv64-unknown-elf-objdump
ref_model_exe: sail_riscv_sim
udb_config: myzkvm-rv64im.yaml
linker_script: link.ld
dut_include_dir: .
```

#### `myzkvm-rv64im.yaml` (UDB config)

Declares which extensions and behaviors your ZKVM implements. This is the most
important config file — it determines which tests are selected and what Sail
expects.

Start by copying a similar ZKVM's UDB config. Key fields:

```yaml
hart:
  # ...
  extensions:
    I:
      version: "2.1"
    M:
      version: "2.0"
    # Add others as supported
  base:
    MXLEN: 64  # or 32
```

If you declare an extension here, tests for it will be generated. If your ZKVM
doesn't actually support it, those tests will fail. Be conservative — only
declare what you know works.

#### `sail.json`

Sail simulator configuration. Critical fields:

```json
{
  "base": {
    "xlen": 64
  },
  "memory": {
    "regions": [{
      "base": {"len": 64, "value": "0x0"},
      "size": {"len": 64, "value": "0x80000000"},
      "attributes": {
        "reservability": "RsrvNone",
        "misaligned_fault": "NoFault"
      }
    }],
    "misaligned": {
      "supported": true
    }
  },
  "extensions": {
    "M": {"supported": true},
    "Zalrsc": {"supported": false}
  }
}
```

Key pitfalls:
- The memory region must cover your linker script's load address. If code loads
  at `0x78000000` and the region only goes to `0x40000000`, Sail will loop
  forever.
- If you include LR/SC tests (Zalrsc), set `"reservability": "RsrvEventual"`.
  `RsrvNone` causes Sail to raise access faults on LR instructions.
- Extension `supported` flags must be consistent with the UDB config.

Start with the full template from `act4-configs/sp1/sp1-rv64im-zicclsm/sail.json`
and adjust the memory region and extensions.

#### `rvmodel_macros.h`

Assembly macros that define how the test halts with a pass/fail code. This is
ZKVM-specific. The framework requires at minimum:

```c
// Called at test start (can be empty)
#define RVMODEL_BOOT

// Called to halt with pass (exit code 0)
#define RVMODEL_HALT                                                    \
    /* your halt-with-pass assembly here */

// These are used by the self-checking framework:
#define RVMODEL_HALT_PASS RVMODEL_HALT
#define RVMODEL_HALT_FAIL \
    /* your halt-with-fail assembly here (exit code 1) */
```

Example for an ecall-based ZKVM (a7=93, a0=exit code):

```c
#define RVMODEL_HALT                                                    \
    li a0, 0;                                                           \
    li a7, 93;                                                          \
    ecall;

#define RVMODEL_HALT_FAIL                                               \
    li a0, 1;                                                           \
    li a7, 93;                                                          \
    ecall;
```

Example for an HTIF-based ZKVM (write to tohost address):

```c
#define RVMODEL_HALT                                                    \
    la t0, tohost;                                                      \
    li t1, 1;                                                           \
    sw t1, 0(t0);                                                       \
    j .;

#define RVMODEL_HALT_FAIL                                               \
    la t0, tohost;                                                      \
    li t1, 3;                                                           \
    sw t1, 0(t0);                                                       \
    j .;
```

Also typically includes `RVMODEL_IO_WRITE_STR` (can be a no-op) and
`RVMODEL_SET_MSW_INT` (can be a no-op).

#### `link.ld`

Linker script. Must place code and data at addresses your ZKVM can access:

```ld
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;          /* adjust to your ZKVM's valid range */
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) }
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

The `.tohost` section is used by HTIF-based ZKVMs. Even if your ZKVM doesn't
use HTIF, keep it — the test framework expects the section to exist.

#### `rvtest_config.h` (optional)

Usually minimal or empty. Can define `XLEN`:

```c
#ifndef RVTEST_CONFIG_H
#define RVTEST_CONFIG_H
#define XLEN 64
#endif
```

### Step 4: Create the test Dockerfile

File: `docker/myzkvm/Dockerfile`

This is the test runner image. All ZKVMs use the same template — copy from
an existing one (e.g., `docker/sp1/Dockerfile`) and adjust:

1. The `EXTENSIONS` list in the `uv run make tests` command
2. Whether to copy `patch_elfs.py`
3. The entrypoint script name

```dockerfile
FROM ubuntu:24.04

# ... (standard toolchain install — same for all ZKVMs) ...

# Pre-generate test sources for your ZKVM's supported extensions
RUN uv run make tests EXTENSIONS=I,M,Misalign

# Only copy patch_elfs.py if your ZKVM needs ELF patching
COPY docker/shared/patch_elfs.py /act4/patch_elfs.py

COPY docker/myzkvm/entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh

ENTRYPOINT ["/act4/entrypoint.sh"]
```

### Step 5: Create the entrypoint script

File: `docker/myzkvm/entrypoint.sh`

Copy from an existing simple entrypoint (e.g., `docker/zisk/entrypoint.sh`)
and customize:

1. **The DUT wrapper** — how to invoke your binary with an ELF:

```bash
cat > /act4/run-dut.sh << 'WRAPPER'
#!/bin/bash
/dut/myzkvm-binary "$1"
WRAPPER
chmod +x /act4/run-dut.sh
```

2. **The suite definitions** — which configs and extensions to test:

```bash
# Native ISA
run_act4_suite \
    "config/myzkvm/myzkvm-rv64im/test_config.yaml" \
    "myzkvm-rv64im" \
    "I,M" \
    "$(printf 'I\nM')" \
    "" || true

# ETH-ACT target
run_act4_suite \
    "config/myzkvm/myzkvm-rv64im-zicclsm/test_config.yaml" \
    "myzkvm-rv64im-zicclsm" \
    "I,M,Misalign" \
    "$(printf 'I\nM\nZicclsm\nMisalign')" \
    "-target" || true
```

3. **ELF patching** (if needed) — add before the `run_tests.py` call:

```bash
python3 /act4/patch_elfs.py "$ELF_DIR"
```

The `run_act4_suite` function handles Makefile generation, compilation, test
execution, and result JSON writing. It's defined inline in the entrypoint
(copy the full function from an existing entrypoint).

### Step 6: Build and test

```bash
./run build myzkvm    # build binary via docker/build-myzkvm/Dockerfile
./run test myzkvm     # run ACT4 tests via docker/myzkvm/Dockerfile
```

## Debugging a New Integration

### Common failure modes

**All tests exit 101 / crash immediately**
- Wrong CLI arguments in the DUT wrapper
- Binary can't parse the ELF format (try `--test-elf` vs `--elf`)
- Missing stdin/param file for ZKVMs that require input

**All tests exit non-zero (e.g., 1, 139)**
- Linker script places code/data outside ZKVM's valid memory range
- Sail memory region doesn't cover the load address (Sail loops → wrong
  expected values baked into ELFs)
- Wrong halt mechanism in `rvmodel_macros.h`

**0/N tests pass (but ELFs compile fine)**
- ZKVM is RV32 but config declares RV64 (or vice versa) — 64-bit operations
  produce different results than 32-bit
- Extension mismatch between UDB config and what ZKVM actually supports

**Tests pass in execution but fail in proving**
- Some instructions are handled in the fast executor (JIT) but not in the
  proof generation pipeline (e.g., SP1's FENCE → UNIMP)
- Use a mode that exercises the proving path (e.g., `--mode node` for SP1)

**Transpiler panics on data words**
- ZKVM pre-processes all ELF words as instructions
- Need `patch_elfs.py` to replace data words with NOPs

### Isolating a single test

Extract a test ELF from the Docker container and run it locally:

```bash
# Run the container, compile ELFs, copy one out
docker run --rm -v /tmp/debug:/results --entrypoint bash sp1:latest -c '
    # ... generate and compile ELFs ...
    cp -L $WORKDIR/$CONFIG/elfs/rv64i/I/I-add-00.elf /results/
'

# Run locally
./binaries/myzkvm-binary /tmp/debug/I-add-00.elf
echo "Exit code: $?"
```

### Checking Sail expected values

If tests fail with assertion errors (exit code 1, not crashes), the issue may
be in `sail.json`. Sail computes expected values at compile time based on
`sail.json` — if the config doesn't match your ZKVM's actual behavior, the
baked-in expected values will be wrong.

Common `sail.json` issues:
- Memory region too small (doesn't cover load address)
- `reservability` set to `RsrvNone` when LR/SC tests are included
- Misaligned access behavior doesn't match ZKVM

## Which Existing ZKVM to Copy From

| If your ZKVM... | Copy from |
|-----------------|-----------|
| Is simple (ELF in, exit code out) | Zisk or Jolt |
| Needs stdin/param files | SP1 |
| Needs ELF-to-binary conversion | Airbender |
| Pre-processes all words as instructions | SP1 (includes `patch_elfs.py`) |
| Uses ecall with a7 for halt | Zisk or r0vm |
| Uses ecall with t0 for halt | SP1 or Pico |
| Uses HTIF (tohost) for halt | Airbender |
| Has custom halt opcode | OpenVM |
| Is RV32IM | Airbender, OpenVM, Pico, or r0vm |
| Is RV64IM | SP1, Zisk, or Jolt |
| Supports atomics/float/compressed | Zisk |
