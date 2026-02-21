# ACT4 Multi-ZKVM Integration Plan

## Executive Summary

Extend ACT4 self-checking RISC-V compliance testing from airbender-only to 5 additional ZKVMs: **jolt, sp1, pico, openvm, and zisk**. For each ZKVM, create config files defining the DUT's ISA capabilities and halt mechanism, Docker containers with test runners, and generalize the test harness. Each ZKVM runs two suites: native ISA (I,M) and RV64IM_Zicclsm target profile.

The key challenge is that each ZKVM halts differently (HTIF, ecall, custom opcode). We customize `rvmodel_macros.h` per ZKVM so PASS uses the native halt and FAIL uses an illegal instruction or explicit fail exit. No upstream ZKVM source changes are needed — the existing RISCOF-modified binaries work as-is.

Additionally, we update/verify the **build Dockerfiles** (`docker/build-<zkvm>/`) to ensure `./run build <zkvm>` produces binaries compatible with both RISCOF and ACT4 testing. This was missed during the airbender preliminary work and needs to be addressed for all 6 ZKVMs (airbender + the 5 new ones).

## Goals & Objectives

### Primary Goals
- Run ACT4 native ISA tests (I, M extensions) for all 5 ZKVMs
- Run ACT4 RV64IM_Zicclsm target profile tests for all 5 ZKVMs
- Update the dashboard with results for all ZKVMs

### Secondary Objectives
- Establish reusable patterns for adding more ZKVMs to ACT4
- Identify ZKVMs that need upstream changes for full ACT4 support

## Solution Overview

### Per-ZKVM Reference Table

| ZKVM | XLEN | Entry Point | Native Profile | HALT_PASS | HALT_FAIL | sail.json xlen (native) | Memory Region |
|------|------|-------------|----------------|-----------|-----------|------------------------|---------------|
| jolt | 64 | 0x80000000 | jolt-rv64im | HTIF tohost=1 | HTIF tohost=3 | 64 | 0x0–0x100000000 |
| sp1 | 32 | 0x20000000 | sp1-rv32im | ecall a7=0 a1=0x400 | .4byte 0 | 32 | 0x0–0x40000000 |
| pico | 32 | 0x20000000 | pico-rv32im | ecall a7=0 | .4byte 0 | 32 | 0x0–0x40000000 |
| openvm | 32 | 0x00000000 | openvm-rv32im | .insn i 0x0b,0,x0,x0,0 | .4byte 0 | 32 | 0x0–0x40000000 |
| zisk | 64 | 0x80000000 | zisk-rv64im | ecall a7=93 a0=0 | ecall a7=93 a0=1 | 64 | 0x0–0x100000000 |

All target profiles use MXLEN:64, sail xlen:64, and test I,M,Misalign extensions.

### DUT Command Strategy

`run_tests.py` appends the ELF path to the command string. ZKVMs where the ELF isn't the last positional arg need a wrapper script.

| ZKVM | Wrapper needed? | DUT command for run_tests.py |
|------|----------------|------------------------------|
| jolt | No | `/dut/jolt-binary <elf>` (positional) |
| sp1 | Yes | `/act4/run-dut.sh <elf>` → `sp1-binary --program <elf> --stdin ... --executor-mode simple` |
| pico | Yes | `/act4/run-dut.sh <elf>` → `pico-binary pico test-emulator --elf <elf> --signatures /tmp/sig` |
| openvm | Yes | `/act4/run-dut.sh <elf>` → `openvm-binary openvm run --exe <elf> --signatures /tmp/sig` |
| zisk | Yes | `/act4/run-dut.sh <elf>` → `zisk-binary -e <elf> > /dev/null` |

### Architecture

```
riscv-arch-test/config/
├── airbender/              (existing)
├── jolt/                   (Task #0)
│   ├── jolt-rv64im/
│   └── jolt-rv64im-zicclsm/
├── sp1/                    (Task #1)
│   ├── sp1-rv32im/
│   └── sp1-rv64im-zicclsm/
├── pico/                   (Task #2)
│   ├── pico-rv32im/
│   └── pico-rv64im-zicclsm/
├── openvm/                 (Task #3)
│   ├── openvm-rv32im/
│   └── openvm-rv64im-zicclsm/
└── zisk/                   (Task #4)
    ├── zisk-rv64im/
    └── zisk-rv64im-zicclsm/

docker/
├── act4-airbender/         (existing)
├── act4-jolt/              (Task #0)
├── act4-sp1/               (Task #1)
├── act4-pico/              (Task #2)
├── act4-openvm/            (Task #3)
└── act4-zisk/              (Task #4)

src/test.sh                 (Task #5: generalize ACT4 section)
```

### Build Dockerfile Status

The `docker/build-<zkvm>/` Dockerfiles are used by `./run build <zkvm>` (via `src/build.sh`) to build ZKVM binaries from source. Current state:

| ZKVM | Dockerfile Default Commit | config.json Commit | Missing commit.txt? | Notes |
|------|--------------------------|-------------------|---------------------|-------|
| airbender | `riscof` | `riscof-dev` | No | Default stale; needs `riscof-dev` for `run-for-act` |
| jolt | `c4b9b060` | `0156f771` | No | Default stale |
| sp1 | `fc98075a` | `eb86c1dee` | **Yes** | Default stale, no commit.txt tracking |
| pico | `v1.1.10` | `f8617c9c` | No | Default stale |
| openvm | `a6f77215f` | `b5f3f0197` | **Yes** | Default stale, no commit.txt tracking |
| zisk | `main` | `b3ca745b` | No | Default stale |

While `build.sh` passes `--build-arg COMMIT_HASH` from config.json (so actual builds use the right commit), the Dockerfile defaults should match for reproducibility and standalone builds. Missing `commit.txt` means `build.sh` can't track the built commit.

Each ZKVM task below includes updating the build Dockerfile.

### Expected Outcomes
- ACT4 test results for all 5 ZKVMs visible on dashboard
- Each ZKVM shows native ISA pass/fail and RV64IM_Zicclsm target pass/fail
- `./run test --act4 <zkvm>` works for any configured ZKVM
- `./run test --act4` runs all ZKVMs with act4 Docker configs
- `./run build <zkvm>` produces ACT4-compatible binaries for all ZKVMs

## Shared Templates

All ZKVMs share the same Dockerfile (only entrypoint.sh differs) and most config files are copies of airbender's with parameter substitutions.

### Dockerfile Template (identical for all 5 ZKVMs)

```dockerfile
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    curl git make build-essential ca-certificates xz-utils \
    python3 python3-pip jq && rm -rf /var/lib/apt/lists/*
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
    tar -xJ -C /opt/ && mv /opt/riscv /opt/riscv64
ENV PATH="/opt/riscv64/bin:${PATH}"
RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.10/sail-riscv-Linux-x86_64.tar.gz | \
    tar -xz -C /opt/ && mv /opt/sail-riscv-Linux-x86_64 /opt/sail-riscv
ENV PATH="/opt/sail-riscv/bin:${PATH}"
ARG ARCH_TEST_COMMIT=act4
WORKDIR /act4
RUN git clone --branch act4 --single-branch \
        https://github.com/riscv-non-isa/riscv-arch-test.git . && \
    git checkout ${ARCH_TEST_COMMIT} && \
    git rev-parse HEAD > /act4/arch_test_commit.txt
RUN git submodule update --init external/riscv-unified-db
RUN uv run make tests EXTENSIONS=I,M,Misalign
RUN mkdir -p /dut /results
COPY entrypoint.sh /act4/entrypoint.sh
RUN chmod +x /act4/entrypoint.sh
ENTRYPOINT ["/act4/entrypoint.sh"]
```

### Config File Templates

**test_config.yaml** — replace `<PROFILE>`:
```yaml
name: <PROFILE>
compiler_exe: riscv64-unknown-elf-gcc
objdump_exe: riscv64-unknown-elf-objdump
ref_model_exe: sail_riscv_sim
udb_config: <PROFILE>.yaml
linker_script: link.ld
dut_include_dir: .
```

**link.ld** — replace `<ENTRY_POINT>`:
```ld
OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)
SECTIONS
{
  . = <ENTRY_POINT>;
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

**rvtest_config.h** — identical for all ZKVMs:
```c
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
#define RVMODEL_PMP_GRAIN 0
#define RVMODEL_NUM_PMPS 0
```

**UDB config (`<PROFILE>.yaml`)** — copy from `airbender-rv32im.yaml`, change these fields:
- `name:` → `<PROFILE>`
- `description:` → `<ZKVM> <ISA> ZK-VM`
- `MXLEN:` → 32 or 64 (per ZKVM)
- `MTVAL_WIDTH:` → 32 or 64 (match MXLEN)
- `PHYS_ADDR_WIDTH:` → 32 or 64 (match MXLEN)

For target profiles, copy from `airbender-rv64im-zicclsm.yaml` and change only name/description.

**sail.json** — copy from airbender's, change:
- `"xlen":` → 32 or 64
- For 64-bit entry (0x80000000): expand memory region size to `"0x100000000"`

## Implementation Tasks

### Visual Dependency Tree

```
docker/build-airbender/Dockerfile              (Task #0a: update default commit)

riscv-arch-test/config/
├── jolt/                              (Task #0)
│   ├── jolt-rv64im/                   6 config files
│   └── jolt-rv64im-zicclsm/          6 config files
├── sp1/                               (Task #1)
│   ├── sp1-rv32im/                    6 config files
│   └── sp1-rv64im-zicclsm/           6 config files
├── pico/                              (Task #2)
│   ├── pico-rv32im/                   6 config files
│   └── pico-rv64im-zicclsm/          6 config files
├── openvm/                            (Task #3)
│   ├── openvm-rv32im/                 6 config files
│   └── openvm-rv64im-zicclsm/        6 config files
└── zisk/                              (Task #4)
    ├── zisk-rv64im/                   6 config files
    └── zisk-rv64im-zicclsm/          6 config files

docker/
├── build-airbender/Dockerfile         (Task #0a: update default commit)
├── build-jolt/Dockerfile              (Task #0: update default commit)
├── build-sp1/Dockerfile               (Task #1: update commit + add commit.txt)
├── build-pico/Dockerfile              (Task #2: update default commit)
├── build-openvm/Dockerfile            (Task #3: update commit + add commit.txt)
├── build-zisk/Dockerfile              (Task #4: update default commit)
├── act4-jolt/Dockerfile + entrypoint.sh     (Task #0)
├── act4-sp1/Dockerfile + entrypoint.sh      (Task #1)
├── act4-pico/Dockerfile + entrypoint.sh     (Task #2)
├── act4-openvm/Dockerfile + entrypoint.sh   (Task #3)
└── act4-zisk/Dockerfile + entrypoint.sh     (Task #4)

src/test.sh                                   (Task #5)
```

### Execution Plan

#### Group A: Per-ZKVM Setup (All 6 in Parallel — includes airbender build fix)

---

- [ ] **Task #0a**: Airbender build Dockerfile fix

  The `docker/build-airbender/Dockerfile` was not updated during the preliminary ACT4 work.

  **Changes to `docker/build-airbender/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=riscof` → `ARG COMMIT_HASH=riscof-dev` (line 37)

  **Changes to `config.json`:**
  - [ ] Verify `airbender.commit` is `riscof-dev` (already correct)

  **Verification:**
  ```bash
  FORCE=1 ./run build airbender
  binaries/airbender-binary run-for-act --help  # should show run-for-act subcommand
  ```

---

- [ ] **Task #0**: Jolt ACT4 integration

  **Parameters:**
  - XLEN: 64, Entry: `0x80000000`, Misaligned: true
  - Native profile: `jolt-rv64im` (MXLEN:64)
  - Target profile: `jolt-rv64im-zicclsm` (MXLEN:64)
  - Halt: HTIF tohost (same mechanism as airbender)
  - DUT command: `/dut/jolt-binary` (ELF appended as positional arg, no wrapper needed)

  **Config files — `riscv-arch-test/config/jolt/`:**

  - [ ] `jolt-rv64im/test_config.yaml` — PROFILE=`jolt-rv64im`
  - [ ] `jolt-rv64im/jolt-rv64im.yaml` — copy airbender-rv32im.yaml, set: name=`jolt-rv64im`, description=`Jolt RV64IM ZK-VM`, MXLEN=64, MTVAL_WIDTH=64, PHYS_ADDR_WIDTH=64
  - [ ] `jolt-rv64im/sail.json` — copy airbender sail.json, set: xlen=64, memory region size=`"0x100000000"`
  - [ ] `jolt-rv64im/link.ld` — ENTRY_POINT=`0x80000000`
  - [ ] `jolt-rv64im/rvmodel_macros.h` — HTIF-based (see below)
  - [ ] `jolt-rv64im/rvtest_config.h` — identical to airbender
  - [ ] `jolt-rv64im-zicclsm/test_config.yaml` — PROFILE=`jolt-rv64im-zicclsm`
  - [ ] `jolt-rv64im-zicclsm/jolt-rv64im-zicclsm.yaml` — copy airbender-rv64im-zicclsm.yaml, set name=`jolt-rv64im-zicclsm`, description=`ETH-ACT Target — RV64IM+Zicclsm compliance profile (Jolt)`
  - [ ] `jolt-rv64im-zicclsm/sail.json` — copy airbender target sail.json, set memory region size=`"0x100000000"`
  - [ ] `jolt-rv64im-zicclsm/link.ld` — ENTRY_POINT=`0x80000000`
  - [ ] `jolt-rv64im-zicclsm/rvmodel_macros.h` — same as native (HTIF)
  - [ ] `jolt-rv64im-zicclsm/rvtest_config.h` — identical to airbender

  **rvmodel_macros.h for Jolt** (identical to airbender — both use HTIF):
  ```c
  // rvmodel_macros.h for Jolt (RV64IM ZK-VM)
  // Uses HTIF tohost/fromhost for test termination.
  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

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

  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif
  ```

  **Docker — `docker/act4-jolt/`:**
  - [ ] `Dockerfile` — use shared Dockerfile template (copy verbatim)
  - [ ] `entrypoint.sh`:
  ```bash
  #!/bin/bash
  set -eu
  DUT=/dut/jolt-binary
  RESULTS=/results
  WORKDIR=/act4/work
  ZKVM=jolt

  if [ ! -x "$DUT" ]; then
      echo "Error: No executable found at $DUT"
      exit 1
  fi

  cd /act4
  mkdir -p "$RESULTS"
  JOBS="${ACT4_JOBS:-$(nproc)}"

  run_act4_suite() {
      local CONFIG="$1" CONFIG_NAME="$2" EXTENSIONS="$3" EXT_TXT="$4" SUFFIX="$5"
      if [ ! -f "/act4/$CONFIG" ]; then
          echo "Warning: Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
          return
      fi
      mkdir -p "$WORKDIR/$CONFIG_NAME"
      echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
      touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"
      echo "=== Generating Makefiles for $CONFIG_NAME ==="
      uv run act "$CONFIG" --workdir "$WORKDIR" --test-dir tests --extensions "$EXTENSIONS"
      echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
      make -C "$WORKDIR" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }
      local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
      local ELF_COUNT
      ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
      if [ "$ELF_COUNT" -eq 0 ]; then
          echo "Error: No ELFs found in $ELF_DIR"
          return
      fi
      echo "=== Running $ELF_COUNT tests ($CONFIG_NAME) ==="
      local RUN_OUTPUT
      RUN_OUTPUT=$(python3 /act4/run_tests.py "$DUT" "$ELF_DIR" -j "$JOBS" 2>&1) || true
      echo "$RUN_OUTPUT"
      local FAILED TOTAL PASSED
      FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
      TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
      PASSED=$((TOTAL - FAILED))
      cat > "$RESULTS/summary-act4${SUFFIX}.json" << EOF
  {
    "zkvm": "$ZKVM",
    "suite": "act4${SUFFIX}",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "passed": $PASSED,
    "failed": $FAILED,
    "total": $TOTAL
  }
  EOF
      python3 -c "
  import json, os, re
  elf_dir = '$ELF_DIR'
  run_output = '''$RUN_OUTPUT'''
  expected_passed = $PASSED
  failed_names = set()
  for line in run_output.splitlines():
      m = re.match(r'\tTest (\S+\.elf) failed', line)
      if m:
          failed_names.add(m.group(1))
  tests = []
  for root, dirs, files in os.walk(elf_dir):
      for f in sorted(files):
          if not f.endswith('.elf'):
              continue
          ext = os.path.basename(root)
          name = f.removesuffix('.elf')
          tests.append({'name': name, 'extension': ext, 'passed': f not in failed_names})
  tests.sort(key=lambda t: (t['extension'], t['name']))
  parsed_passed = sum(1 for t in tests if t['passed'])
  if parsed_passed != expected_passed:
      for t in tests:
          t['passed'] = False
  with open('$RESULTS/results-act4${SUFFIX}.json', 'w') as out:
      json.dump({'zkvm': '$ZKVM', 'suite': 'act4${SUFFIX}', 'tests': tests}, out, indent=2)
  print(f'Per-test results: {len(tests)} tests written to results-act4${SUFFIX}.json')
  "
      echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
  }

  run_act4_suite \
      "config/jolt/jolt-rv64im/test_config.yaml" \
      "jolt-rv64im" \
      "I,M" \
      "$(printf 'I\nM\nZicsr\nSm')" \
      "" || true

  run_act4_suite \
      "config/jolt/jolt-rv64im-zicclsm/test_config.yaml" \
      "jolt-rv64im-zicclsm" \
      "I,M,Misalign" \
      "$(printf 'I\nM\nZicsr\nZicclsm\nSm\nMisalign')" \
      "-target" || true

  echo "=== All ACT4 suites complete ==="
  ```

  **Note:** Jolt uses HTIF natively, so the DUT command is simply `$DUT` with ELF appended by run_tests.py. No wrapper script needed.

  **Build Dockerfile — `docker/build-jolt/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=c4b9b060` → `ARG COMMIT_HASH=0156f771` (match config.json)
  - [ ] Verify `commit.txt` is saved (already present at line 40)

---

- [ ] **Task #1**: SP1 ACT4 integration

  **Parameters:**
  - XLEN: 32, Entry: `0x20000000`, Misaligned: true
  - Native profile: `sp1-rv32im` (MXLEN:32)
  - Target profile: `sp1-rv64im-zicclsm` (MXLEN:64)
  - Halt: ecall with a7=0, a1=0x400
  - DUT command: wrapper script (reformats args for sp1-binary)

  **Config files — `riscv-arch-test/config/sp1/`:**

  - [ ] `sp1-rv32im/test_config.yaml` — PROFILE=`sp1-rv32im`
  - [ ] `sp1-rv32im/sp1-rv32im.yaml` — copy airbender-rv32im.yaml, set: name=`sp1-rv32im`, description=`SP1 RV32IM ZK-VM`
  - [ ] `sp1-rv32im/sail.json` — copy airbender sail.json (xlen=32, same region)
  - [ ] `sp1-rv32im/link.ld` — ENTRY_POINT=`0x20000000`
  - [ ] `sp1-rv32im/rvmodel_macros.h` — ecall-based (see below)
  - [ ] `sp1-rv32im/rvtest_config.h` — identical to airbender
  - [ ] `sp1-rv64im-zicclsm/test_config.yaml` — PROFILE=`sp1-rv64im-zicclsm`
  - [ ] `sp1-rv64im-zicclsm/sp1-rv64im-zicclsm.yaml` — copy airbender-rv64im-zicclsm.yaml, set name=`sp1-rv64im-zicclsm`, description=`ETH-ACT Target — RV64IM+Zicclsm compliance profile (SP1)`
  - [ ] `sp1-rv64im-zicclsm/sail.json` — copy airbender target sail.json (xlen=64, same region)
  - [ ] `sp1-rv64im-zicclsm/link.ld` — ENTRY_POINT=`0x20000000`
  - [ ] `sp1-rv64im-zicclsm/rvmodel_macros.h` — same as native
  - [ ] `sp1-rv64im-zicclsm/rvtest_config.h` — identical to airbender

  **rvmodel_macros.h for SP1:**
  ```c
  // rvmodel_macros.h for SP1 (RV32IM ZK-VM)
  // PASS: ecall with a7=0, a1=0x400 (SP1 halt pattern)
  // FAIL: illegal instruction (.4byte 0)
  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

  #define RVMODEL_HALT_PASS  \
    li a7, 0                ;\
    li a1, 0x400            ;\
    ecall                   ;\
    j .                     ;\

  #define RVMODEL_HALT_FAIL \
    .4byte 0x00000000       ;\

  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif
  ```

  **Docker — `docker/act4-sp1/`:**
  - [ ] `Dockerfile` — shared template
  - [ ] `entrypoint.sh` — same structure as Jolt's but with wrapper script and SP1 paths:
    - `DUT=/dut/sp1-binary`, `ZKVM=sp1`
    - Config paths: `config/sp1/sp1-rv32im/...` and `config/sp1/sp1-rv64im-zicclsm/...`
    - **Wrapper script** embedded at top of entrypoint:
      ```bash
      # Create wrapper script for SP1 (reformats args)
      cat > /act4/run-dut.sh << 'WRAPPER'
      #!/bin/bash
      TMPDIR=$(mktemp -d)
      printf '\x00%.0s' {1..24} > "$TMPDIR/stdin.bin"
      /dut/sp1-binary --program "$1" --stdin "$TMPDIR/stdin.bin" --executor-mode simple
      EC=$?
      rm -rf "$TMPDIR"
      exit $EC
      WRAPPER
      chmod +x /act4/run-dut.sh
      ```
    - DUT command in run_act4_suite: `"/act4/run-dut.sh"` instead of `"$DUT"`

  **Build Dockerfile — `docker/build-sp1/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=fc98075a` → `ARG COMMIT_HASH=eb86c1dee` (match config.json)
  - [ ] Add `commit.txt` tracking: after `git checkout`, add `git rev-parse HEAD | head -c8 > /workspace/commit.txt`
  - [ ] Add `COPY --from=builder /workspace/commit.txt /commit.txt` to final stage

---

- [ ] **Task #2**: Pico ACT4 integration

  **Parameters:**
  - XLEN: 32, Entry: `0x20000000`, Misaligned: true
  - Native profile: `pico-rv32im` (MXLEN:32)
  - Target profile: `pico-rv64im-zicclsm` (MXLEN:64)
  - Halt: ecall a7=0
  - DUT command: wrapper

  **Config files — `riscv-arch-test/config/pico/`:**
  Same structure as SP1. Entry point `0x20000000`. Same sail.json regions.

  - [ ] Native profile: 6 files in `pico-rv32im/`
  - [ ] Target profile: 6 files in `pico-rv64im-zicclsm/`

  **rvmodel_macros.h for Pico:**
  ```c
  // rvmodel_macros.h for Pico (RV32IM ZK-VM)
  // PASS: ecall with a7=0 (Pico halt pattern)
  // FAIL: illegal instruction (.4byte 0)
  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

  #define RVMODEL_HALT_PASS  \
    li a7, 0                ;\
    ecall                   ;\
    j .                     ;\

  #define RVMODEL_HALT_FAIL \
    .4byte 0x00000000       ;\

  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif
  ```

  **Docker — `docker/act4-pico/`:**
  - [ ] `Dockerfile` — shared template
  - [ ] `entrypoint.sh` — `DUT=/dut/pico-binary`, `ZKVM=pico`, config paths use `pico/pico-rv32im/...`
    - **Wrapper:**
      ```bash
      cat > /act4/run-dut.sh << 'WRAPPER'
      #!/bin/bash
      TMPDIR=$(mktemp -d)
      /dut/pico-binary pico test-emulator --elf "$1" --signatures "$TMPDIR/sig"
      EC=$?
      rm -rf "$TMPDIR"
      exit $EC
      WRAPPER
      chmod +x /act4/run-dut.sh
      ```

  **Build Dockerfile — `docker/build-pico/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=v1.1.10` → `ARG COMMIT_HASH=f8617c9c` (match config.json)
  - [ ] Verify `commit.txt` is saved (already present at line 33)

---

- [ ] **Task #3**: OpenVM ACT4 integration

  **Parameters:**
  - XLEN: 32, Entry: `0x00000000`, Misaligned: true
  - Native profile: `openvm-rv32im` (MXLEN:32)
  - Target profile: `openvm-rv64im-zicclsm` (MXLEN:64)
  - Halt: custom opcode `.insn i 0x0b, 0, x0, x0, 0`
  - DUT command: wrapper

  **Config files — `riscv-arch-test/config/openvm/`:**
  Same structure. Entry point `0x00000000`. sail.json region 0x0–0x40000000.

  - [ ] Native profile: 6 files in `openvm-rv32im/`
  - [ ] Target profile: 6 files in `openvm-rv64im-zicclsm/`

  **rvmodel_macros.h for OpenVM:**
  ```c
  // rvmodel_macros.h for OpenVM (RV32IM ZK-VM)
  // PASS: custom terminate opcode (.insn i 0x0b, 0, x0, x0, 0)
  // FAIL: illegal instruction (.4byte 0)
  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

  #define RVMODEL_HALT_PASS  \
    .insn i 0x0b, 0, x0, x0, 0 ;\
    j .                     ;\

  #define RVMODEL_HALT_FAIL \
    .4byte 0x00000000       ;\

  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif
  ```

  **Docker — `docker/act4-openvm/`:**
  - [ ] `Dockerfile` — shared template
  - [ ] `entrypoint.sh` — `DUT=/dut/openvm-binary`, `ZKVM=openvm`, config paths use `openvm/openvm-rv32im/...`
    - **Wrapper:**
      ```bash
      cat > /act4/run-dut.sh << 'WRAPPER'
      #!/bin/bash
      TMPDIR=$(mktemp -d)
      /dut/openvm-binary openvm run --exe "$1" --signatures "$TMPDIR/sig"
      EC=$?
      rm -rf "$TMPDIR"
      exit $EC
      WRAPPER
      chmod +x /act4/run-dut.sh
      ```

  **Build Dockerfile — `docker/build-openvm/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=a6f77215f` → `ARG COMMIT_HASH=b5f3f0197` (match config.json)
  - [ ] Add `commit.txt` tracking: after `git checkout`, add `git rev-parse HEAD | head -c8 > /workspace/commit.txt`
  - [ ] Add `COPY --from=builder /workspace/commit.txt /commit.txt` to final stage

---

- [ ] **Task #4**: Zisk ACT4 integration

  **Parameters:**
  - XLEN: 64, Entry: `0x80000000`, Misaligned: true
  - Native profile: `zisk-rv64im` (MXLEN:64)
  - Target profile: `zisk-rv64im-zicclsm` (MXLEN:64)
  - Halt: ecall a7=93 with exit code in a0 (Linux exit syscall)
  - DUT command: wrapper

  **Config files — `riscv-arch-test/config/zisk/`:**
  Same structure as Jolt. Entry point `0x80000000`. Memory region 0x0–0x100000000.

  - [ ] Native profile: 6 files in `zisk-rv64im/`
  - [ ] Target profile: 6 files in `zisk-rv64im-zicclsm/`

  **rvmodel_macros.h for Zisk:**
  ```c
  // rvmodel_macros.h for Zisk (RV64IM ZK-VM)
  // PASS: ecall a7=93 (exit), a0=0
  // FAIL: ecall a7=93 (exit), a0=1
  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

  #define RVMODEL_HALT_PASS  \
    li a0, 0                ;\
    li a7, 93               ;\
    ecall                   ;\
    j .                     ;\

  #define RVMODEL_HALT_FAIL \
    li a0, 1                ;\
    li a7, 93               ;\
    ecall                   ;\
    j .                     ;\

  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif
  ```

  **Docker — `docker/act4-zisk/`:**
  - [ ] `Dockerfile` — shared template
  - [ ] `entrypoint.sh` — `DUT=/dut/zisk-binary`, `ZKVM=zisk`, config paths use `zisk/zisk-rv64im/...`
    - **Wrapper:**
      ```bash
      cat > /act4/run-dut.sh << 'WRAPPER'
      #!/bin/bash
      /dut/zisk-binary -e "$1" > /dev/null
      WRAPPER
      chmod +x /act4/run-dut.sh
      ```

  **Build Dockerfile — `docker/build-zisk/Dockerfile`:**
  - [ ] Update default `ARG COMMIT_HASH=main` → `ARG COMMIT_HASH=b3ca745b` (match config.json)
  - [ ] Verify `commit.txt` is saved (already present at line 64)

---

#### Group B: Infrastructure (Parallel with Group A)

- [ ] **Task #5**: Generalize `src/test.sh` for multi-ZKVM ACT4

  **File:** `src/test.sh`
  **Changes to the ACT4 section (lines 49–163):**

  1. **Replace default ZKVMS** (line 52): Instead of hardcoding `ZKVMS="airbender"`, auto-detect from docker/act4-*/ dirs:
     ```bash
     if [ "$TARGETS" = "all" ] || [ -z "$TARGETS" ]; then
       ZKVMS=""
       for dir in docker/act4-*/; do
         [ -d "$dir" ] && ZKVMS="$ZKVMS $(basename "$dir" | sed 's/^act4-//')"
       done
       ZKVMS="${ZKVMS# }"
     else
       ZKVMS="$TARGETS"
     fi
     ```

  2. **Remove hardcoded Docker build** (lines 57–61): Move build inside the per-ZKVM loop.

  3. **Remove airbender guard** (lines 64–66): Delete `if [ "$ZKVM" != "airbender" ]` block.

  4. **Make Docker build per-ZKVM** (inside loop):
     ```bash
     DOCKER_DIR="docker/act4-${ZKVM}"
     if [ ! -d "$DOCKER_DIR" ]; then
       echo "  ⚠️  No ACT4 Docker config at $DOCKER_DIR, skipping $ZKVM"
       continue
     fi
     echo "🔨 Building ACT4 Docker image for $ZKVM..."
     docker build -t "act4-${ZKVM}:latest" "$DOCKER_DIR" || {
       echo "❌ Failed to build ACT4 Docker image for $ZKVM"
       continue
     }
     ```

  5. **Make Docker run mounts dynamic** (line 85–91):
     ```bash
     docker run --rm \
       ${CPUSET_ARG} \
       -e ACT4_JOBS="${ACT4_JOBS:-${JOBS:-$(nproc)}}" \
       -v "$PWD/binaries/${ZKVM}-binary:/dut/${ZKVM}-binary" \
       -v "$PWD/riscv-arch-test/config/${ZKVM}:/act4/config/${ZKVM}" \
       -v "$PWD/test-results/${ZKVM}:/results" \
       "act4-${ZKVM}:latest" || true
     ```

---

#### Group C: Execution (After Groups A and B)

- [ ] **Task #6**: Build Docker images and run ACT4 tests

  **Prerequisites:** Tasks #0–#5 complete, ZKVM binaries exist in `binaries/`
  **Command:**
  ```bash
  # Run all 5 ZKVMs (binaries must exist)
  ./run test --act4 jolt sp1 pico openvm zisk
  ```
  If a binary is missing, that ZKVM is skipped automatically.

  **Verification:** Check `test-results/<zkvm>/summary-act4.json` and `summary-act4-target.json` for each ZKVM.

  **Expected issues:**
  - Some ZKVMs may exit 0 on illegal instructions (FAIL macro doesn't work) → adjust rvmodel_macros.h
  - Some RISCOF binaries may require `--signatures` and fail without it → adjust wrapper
  - Entry point mismatches → verify against RISCOF plugin linker scripts

- [ ] **Task #7**: Update dashboard

  **Command:**
  ```bash
  ./run update
  ```

  **Verification:** Open `docs/index-act4.html` and verify all 5 ZKVMs show results.

---

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process

#### Phase 0: Worktree Setup

Create a worktree per ZKVM agent in the test-monitor repo. Each worktree branches from `act4-airbender` and handles that ZKVM's Docker files + build Dockerfile changes. The shared `riscv-arch-test` symlink is used directly for config files (no conflicts since each ZKVM writes to its own `config/<zkvm>/` subdirectory).

```bash
# From the test-monitor repo root (/home/cody/zkevm-test-monitor)
BASE_BRANCH=act4-airbender

# Create worktrees (each gets its own branch)
git worktree add ../act4-wt-jolt   -b act4-jolt   $BASE_BRANCH
git worktree add ../act4-wt-sp1    -b act4-sp1    $BASE_BRANCH
git worktree add ../act4-wt-pico   -b act4-pico   $BASE_BRANCH
git worktree add ../act4-wt-openvm -b act4-openvm $BASE_BRANCH
git worktree add ../act4-wt-zisk   -b act4-zisk   $BASE_BRANCH
git worktree add ../act4-wt-infra  -b act4-infra  $BASE_BRANCH
```

Worktree layout:
```
/home/cody/
├── zkevm-test-monitor/          # main repo (act4-airbender branch)
├── act4-wt-jolt/                # worktree: docker/act4-jolt/, docker/build-jolt/
├── act4-wt-sp1/                 # worktree: docker/act4-sp1/, docker/build-sp1/
├── act4-wt-pico/                # worktree: docker/act4-pico/, docker/build-pico/
├── act4-wt-openvm/              # worktree: docker/act4-openvm/, docker/build-openvm/
├── act4-wt-zisk/                # worktree: docker/act4-zisk/, docker/build-zisk/
├── act4-wt-infra/               # worktree: src/test.sh + docker/build-airbender/
└── riscv-arch-test/             # shared across all (config/<zkvm>/ written directly)
```

Each ZKVM agent works in its worktree for:
- `docker/act4-<zkvm>/Dockerfile` + `entrypoint.sh` (new)
- `docker/build-<zkvm>/Dockerfile` (update)

And writes directly to the shared riscv-arch-test for:
- `riscv-arch-test/config/<zkvm>/` (new, no conflicts — disjoint directories)

The infra agent works in its worktree for:
- `src/test.sh` (update)
- `docker/build-airbender/Dockerfile` (update, Task #0a)

#### Phase 1: Parallel Implementation

Launch 6 agents in parallel:
1. **Jolt agent** → worktree `act4-wt-jolt` + shared riscv-arch-test config
2. **SP1 agent** → worktree `act4-wt-sp1` + shared riscv-arch-test config
3. **Pico agent** → worktree `act4-wt-pico` + shared riscv-arch-test config
4. **OpenVM agent** → worktree `act4-wt-openvm` + shared riscv-arch-test config
5. **Zisk agent** → worktree `act4-wt-zisk` + shared riscv-arch-test config
6. **Infra agent** → worktree `act4-wt-infra` (test.sh + airbender build fix)

Each agent commits to its worktree branch when done.

#### Phase 2: Merge and Commit

After all agents complete:
```bash
# Merge all worktree branches into act4-airbender
cd /home/cody/zkevm-test-monitor
git merge act4-jolt act4-sp1 act4-pico act4-openvm act4-zisk act4-infra

# Commit riscv-arch-test config changes
cd /home/cody/riscv-arch-test
git add config/jolt config/sp1 config/pico config/openvm config/zisk
git commit -m "Add ACT4 configs for jolt, sp1, pico, openvm, zisk"

# Clean up worktrees
cd /home/cody/zkevm-test-monitor
git worktree remove ../act4-wt-jolt
git worktree remove ../act4-wt-sp1
git worktree remove ../act4-wt-pico
git worktree remove ../act4-wt-openvm
git worktree remove ../act4-wt-zisk
git worktree remove ../act4-wt-infra
```

#### Phase 3: Execute and Verify

Run Tasks #6 and #7 (build, test, update dashboard) from the main repo.

### Key Risk: FAIL Mechanism
The `.4byte 0` illegal instruction approach for FAIL may not work for all ZKVMs. If a ZKVM catches illegal instructions gracefully (exit 0), tests will show false positives. After initial test runs, check whether failed tests actually report FAIL. If not, the FAIL macro needs adjustment per ZKVM.

### Progress Tracking
The checkboxes above represent the authoritative status of each task.
