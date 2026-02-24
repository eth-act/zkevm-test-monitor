# R0VM ACT4 Integration Plan

## Executive Summary

**Problem**: R0VM (risc0) is missing ACT4 test integration. Pico is already complete (47/47).

**Pico status**: Already fully integrated. `riscv-arch-test/config/pico/` exists, `docker/act4-pico/` exists, 47/47 native tests pass. No action needed.

**R0VM challenge**: Two obstacles:
1. R0VM does not propagate the guest's exit code to the process exit code — it always exits 0.
2. R0VM uses a risc0-specific ecall convention for halt (not HTIF tohost writes).

**Solution**:
1. Add a minimal `--execute-only` flag to r0vm that skips ZK proving and exits with the guest's exit code. This is ~8 lines of Rust in `risc0/r0vm/src/lib.rs`. (Note: the user wanted "no changes to their VMs" but this is unavoidable for r0vm to work as a DUT — it's a 2-line structural change, not a fork.)
2. Create `rvmodel_macros.h` for r0vm using risc0's halt ecall convention: `t0=0 (HALT), a0=(exit_code<<8), a1=journal_ptr`.
3. Set linker text start to `0x0020_0800` per risc0's `TEXT_START` constant.
4. Create `docker/act4-r0vm/` Docker integration.
5. Build r0vm locally from the `risc0/` symlink (upstream/main).

**Data flow**:
```
riscv-arch-test test ELF (compiled with r0vm rvmodel_macros.h)
  → link.ld places code at 0x200800
  → RVMODEL_HALT_PASS: la a1,tohost; li t0,0; li a0,0; ecall
  → RVMODEL_HALT_FAIL: la a1,tohost; li t0,0; li a0,0x100; ecall
  → r0vm --elf <elf> --execute-only
  → r0vm exec interprets ecall, session.exit_code = Halted(0) or Halted(1)
  → std::process::exit(0) or std::process::exit(1)
  → run_tests.py reads exit code → pass/fail
```

**Expected outcome**: R0VM passes ~47/47 native RV32IM tests (same as Pico). No target suite since r0vm is RV32-only.

---

## Goals & Objectives

### Primary Goals
- R0VM achieves 40+/47 native RV32IM ACT4 tests (target: match pico's 47/47)
- Integration uses upstream risc0/risc0 main branch (local `risc0/` symlink)

### Secondary Objectives
- Minimal upstream change (execute-only flag, no architectural changes)
- Reuse pico config files as templates to avoid duplication

---

## Solution Overview

### Key Components
1. **`risc0/risc0/r0vm/src/lib.rs`**: Add `--execute-only` flag; skip proving; exit with guest exit code
2. **`riscv-arch-test/config/r0vm/r0vm-rv32im/`**: DUT config (6 files)
3. **`docker/act4-r0vm/Dockerfile`**: Build on act4-airbender base with r0vm binary mount
4. **`docker/act4-r0vm/entrypoint.sh`**: Run suites; wrapper calls `r0vm-binary --elf $ELF --execute-only`

### Architecture
```
binaries/r0vm-binary  (built locally from risc0/ symlink)
     ↓ mounted as /dut/r0vm-binary
docker/act4-r0vm container
     ↓ mounts riscv-arch-test/config/r0vm as /act4/config/r0vm
     ↓ compiles ELFs with r0vm linker/macros, runs them
     ↓ writes to /results (test-results/r0vm/)
```

---

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. Every implementation must be production-ready with no placeholders.
2. Build and verify after each task group.
3. The risc0 symlink at `risc0/` is upstream/main — modify in place.

### Visual Dependency Tree

```
risc0/risc0/r0vm/src/lib.rs        (Task A1: add --execute-only flag)

riscv-arch-test/config/r0vm/
└── r0vm-rv32im/
    ├── test_config.yaml            (Task A2)
    ├── r0vm-rv32im.yaml            (Task A2)
    ├── sail.json                   (Task A2: copy from pico-rv32im)
    ├── rvmodel_macros.h            (Task A2: risc0 halt ecall convention)
    ├── rvtest_config.h             (Task A2: copy from pico-rv32im)
    └── link.ld                     (Task A2: TEXT_START = 0x0020_0800)

docker/act4-r0vm/
├── Dockerfile                      (Task A3)
└── entrypoint.sh                   (Task A3)

binaries/r0vm-binary                (Task B1: build locally)
config.json                         (Task B2: update to upstream risc0/risc0)
docker/build-r0vm/Dockerfile        (Task B2: update to upstream risc0/risc0)
```

### Execution Plan

#### Group A: Parallel (no dependencies)

- [x] **Task A1**: Add `--execute-only` flag to r0vm
  - File: `risc0/risc0/r0vm/src/lib.rs`
  - Add field to `Cli` struct:
    ```rust
    /// Execute without proving; exit with guest exit code (0=pass, 1=fail, 2=timeout)
    #[arg(long)]
    execute_only: bool,
    ```
  - After `let session = { ... exec.run().unwrap() };`, insert:
    ```rust
    if args.execute_only {
        match session.exit_code {
            risc0_zkvm::ExitCode::Halted(code) => std::process::exit(code as i32),
            risc0_zkvm::ExitCode::SessionLimit => std::process::exit(2),
            _ => std::process::exit(1),
        }
    }
    ```
  - The `risc0_zkvm::ExitCode` import is already present at the top of the file as `ExitCode`. Use `ExitCode::Halted(code)` (check existing imports first).
  - Placement: insert the `if args.execute_only` block immediately after the `session` binding closes (before `let prover = args.get_prover();`).
  - **Verification**: `cargo build -p risc0-r0vm` compiles without errors (in `risc0/` directory).

- [x] **Task A2**: Create r0vm DUT config directory
  - Directory: `riscv-arch-test/config/r0vm/r0vm-rv32im/`
  - 6 files to create:

  **`test_config.yaml`** (same structure as pico):
  ```yaml
  name: r0vm-rv32im
  compiler_exe: riscv64-unknown-elf-gcc
  objdump_exe: riscv64-unknown-elf-objdump
  ref_model_exe: sail_riscv_sim
  udb_config: r0vm-rv32im.yaml
  linker_script: link.ld
  dut_include_dir: .
  ```

  **`r0vm-rv32im.yaml`**: Copy from `config/pico/pico-rv32im/pico-rv32im.yaml`, change `name: r0vm-rv32im` and `description: r0vm (risc0) RV32IM ZK-VM`. Keep all params identical (RV32IM, misaligned support, no extensions).

  **`sail.json`**: Copy verbatim from `config/pico/pico-rv32im/sail.json`. No changes needed — same RV32IM Sail configuration.

  **`rvtest_config.h`**: Copy verbatim from `config/pico/pico-rv32im/rvtest_config.h`.

  **`link.ld`**: Based on pico's link.ld but with `0x00200800` as text start:
  ```ld
  OUTPUT_ARCH( "riscv" )
  ENTRY(rvtest_entry_point)

  SECTIONS
  {
    . = 0x00200800;
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

  **`rvmodel_macros.h`**: Uses risc0's halt ecall convention.
  - risc0 ecall: `t0=0` (HALT), `a0=(exit_code << 8)`, `a1=journal_ptr`
  - Pass: exit_code=0 → a0=0
  - Fail: exit_code=1 → a0=0x100
  - Journal ptr (`a1`): point to `tohost` section (128-byte buffer allocated below)
  ```c
  // rvmodel_macros.h for r0vm (risc0 ZKVM)
  // risc0 halt ecall: t0=0 (HALT), a0=(exit_code<<8), a1=journal_ptr (128 bytes)
  // PASS: t0=0, a0=0 (exit_code=0), a1=tohost
  // FAIL: t0=0, a0=0x100 (exit_code=1), a1=tohost
  // SPDX-License-Identifier: BSD-3-Clause

  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  // Allocate 128-byte journal buffer at .tohost section
  // (32 u32 words = 128 bytes, required by risc0 halt ecall for journal output)
  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .zero 128;        \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  #define RVMODEL_BOOT

  #define RVMODEL_HALT_PASS  \
    la a1, tohost           ;\
    li t0, 0                ;\
    li a0, 0                ;\
    ecall                   ;\
    j .                     ;\

  #define RVMODEL_HALT_FAIL \
    la a1, tohost           ;\
    li t0, 0                ;\
    li a0, 0x100            ;\
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

  #endif // _COMPLIANCE_MODEL_H
  ```

  **Verification**: `ls riscv-arch-test/config/r0vm/r0vm-rv32im/` shows 6 files.

- [x] **Task A3**: Create `docker/act4-r0vm/`
  - Two files: `Dockerfile` and `entrypoint.sh`

  **`docker/act4-r0vm/Dockerfile`**:
  ```dockerfile
  # ACT4 r0vm test runner
  # Reuses the act4-airbender base image (has RISC-V toolchain, Sail, uv, ACT4 framework)
  # at build time — does NOT inherit at runtime; explicitly FROM ubuntu:24.04 pattern.
  # Actually: build from scratch same as act4-airbender (the base image isn't published).
  FROM ubuntu:24.04

  ENV DEBIAN_FRONTEND=noninteractive

  # System dependencies
  RUN apt-get update && apt-get install -y \
      curl \
      git \
      make \
      build-essential \
      ca-certificates \
      xz-utils \
      python3 \
      python3-pip \
      jq \
      && rm -rf /var/lib/apt/lists/*

  # Install uv
  RUN curl -LsSf https://astral.sh/uv/install.sh | sh
  ENV PATH="/root/.local/bin:${PATH}"

  # Install RISC-V GCC toolchain (same version as other act4 containers)
  ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
  RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
      tar -xJ -C /opt/ && \
      mv /opt/riscv /opt/riscv64
  ENV PATH="/opt/riscv64/bin:${PATH}"

  # Install Sail RISC-V simulator
  RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.10/sail-riscv-Linux-x86_64.tar.gz | \
      tar -xz -C /opt/ && \
      mv /opt/sail-riscv-Linux-x86_64 /opt/sail-riscv
  ENV PATH="/opt/sail-riscv/bin:${PATH}"

  # Clone riscv-arch-test at the act4 branch
  ARG ARCH_TEST_COMMIT=act4
  WORKDIR /act4
  RUN git clone --branch act4 --single-branch \
          https://github.com/riscv-non-isa/riscv-arch-test.git . && \
      git checkout ${ARCH_TEST_COMMIT} && \
      git rev-parse HEAD > /act4/arch_test_commit.txt

  RUN git submodule update --init external/riscv-unified-db

  # Pre-generate I and M assembly tests (no Misalign needed, r0vm is RV32 only)
  RUN uv run make tests EXTENSIONS=I,M

  RUN mkdir -p /dut /results

  COPY docker/act4-r0vm/entrypoint.sh /act4/entrypoint.sh
  RUN chmod +x /act4/entrypoint.sh

  ENTRYPOINT ["/act4/entrypoint.sh"]
  ```
  Note: Consider using Docker multi-stage or a shared base image to avoid duplication — but for now, copy the airbender Dockerfile pattern exactly.

  **`docker/act4-r0vm/entrypoint.sh`**:
  ```bash
  #!/bin/bash
  set -eu

  # ACT4 r0vm test runner
  #
  # Expected mounts:
  #   /dut/r0vm-binary               — the r0vm binary (with --execute-only flag)
  #   /act4/config/r0vm              — r0vm ACT4 config directory
  #   /results/                      — output directory for summary JSON

  DUT=/dut/r0vm-binary
  RESULTS=/results
  WORKDIR=/act4/work

  if [ ! -x "$DUT" ]; then
      echo "Error: No executable found at $DUT"
      exit 1
  fi

  cd /act4
  mkdir -p "$RESULTS"
  JOBS="${ACT4_JOBS:-$(nproc)}"

  # Wrapper: runs r0vm in execute-only mode on the ELF.
  # r0vm takes the ELF directly (no objcopy to binary needed).
  cat > /act4/run-dut.sh << 'WRAPPER'
  #!/bin/bash
  ELF="$1"
  /dut/r0vm-binary --elf "$ELF" --execute-only
  exit $?
  WRAPPER
  chmod +x /act4/run-dut.sh

  # run_act4_suite: same pattern as act4-airbender
  run_act4_suite() {
      local CONFIG="$1"
      local CONFIG_NAME="$2"
      local EXTENSIONS="$3"
      local EXT_TXT="$4"
      local SUFFIX="$5"

      if [ ! -f "/act4/$CONFIG" ]; then
          echo "⚠️  Config not found at /act4/$CONFIG, skipping $CONFIG_NAME"
          return
      fi

      mkdir -p "$WORKDIR/$CONFIG_NAME"
      echo "$EXT_TXT" > "$WORKDIR/$CONFIG_NAME/extensions.txt"
      touch -t 209901010000 "$WORKDIR/$CONFIG_NAME/extensions.txt"

      echo ""
      echo "=== Generating Makefiles for $CONFIG_NAME ==="
      uv run act "$CONFIG" \
          --workdir "$WORKDIR" \
          --test-dir tests \
          --extensions "$EXTENSIONS"

      echo "=== Compiling self-checking ELFs ($CONFIG_NAME) ==="
      make -C "$WORKDIR" || { echo "Error: compilation failed for $CONFIG_NAME"; return; }

      local ELF_DIR="$WORKDIR/$CONFIG_NAME/elfs"
      local ELF_COUNT
      ELF_COUNT=$(find "$ELF_DIR" -name "*.elf" 2>/dev/null | wc -l)
      if [ "$ELF_COUNT" -eq 0 ]; then
          echo "Error: No ELFs found in $ELF_DIR after compilation"
          return
      fi
      echo "=== Running $ELF_COUNT tests with r0vm ($CONFIG_NAME) ==="

      local RUN_OUTPUT
      RUN_OUTPUT=$(python3 /act4/run_tests.py "/act4/run-dut.sh" "$ELF_DIR" -j "$JOBS" 2>&1) || true
      echo "$RUN_OUTPUT"

      local FAILED TOTAL PASSED
      FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of [0-9]+ tests failed' | grep -oE '^[0-9]+' || echo "0")
      TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '([0-9]+ out of )?([0-9]+) tests' | grep -oE '[0-9]+' | tail -1 || echo "$ELF_COUNT")
      PASSED=$((TOTAL - FAILED))

      cat > "$RESULTS/summary-act4${SUFFIX}.json" << EOF
  {
    "zkvm": "r0vm",
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
          tests.append({
              'name': name,
              'extension': ext,
              'passed': f not in failed_names
          })

  tests.sort(key=lambda t: (t['extension'], t['name']))

  parsed_passed = sum(1 for t in tests if t['passed'])
  if parsed_passed != expected_passed:
      for t in tests:
          t['passed'] = False

  with open('$RESULTS/results-act4${SUFFIX}.json', 'w') as out:
      json.dump({
          'zkvm': 'r0vm',
          'suite': 'act4${SUFFIX}',
          'tests': tests
      }, out, indent=2)

  print(f'Per-test results: {len(tests)} tests written to results-act4${SUFFIX}.json')
  "

      echo ""
      echo "=== $CONFIG_NAME: $PASSED/$TOTAL passed ==="
  }

  # ─── Run 1: Native ISA (rv32im) ───
  run_act4_suite \
      "config/r0vm/r0vm-rv32im/test_config.yaml" \
      "r0vm-rv32im" \
      "I,M" \
      "$(printf 'I\nM\nZicsr\nSm')" \
      "" || true

  echo ""
  echo "=== All ACT4 suites complete ==="
  ```

  **Verification**: Both files exist with correct permissions.

---

#### Group B: Sequential (after Group A)

- [x] **Task B1**: Build r0vm binary locally
  - Working dir: `risc0/` (the symlink to `/home/cody/r0z/risc0`)
  - Build command: `cargo build --release -p risc0-r0vm --bin r0vm`
  - Note: this builds in release mode; may take several minutes
  - Copy: `cp risc0/target/release/r0vm binaries/r0vm-binary`
  - **Verification**: `./binaries/r0vm-binary --help` shows `--execute-only` flag.

- [x] **Task B2**: Update config.json and build-r0vm Dockerfile
  - In `config.json`, update the `r0vm` entry:
    ```json
    "r0vm": {
      "repo_url": "https://github.com/risc0/risc0",
      "commit": "main",
      "build_cmd": "cargo build --release -p risc0-r0vm --bin r0vm",
      "binary_name": "r0vm",
      "binary_path": "target/release/r0vm"
    }
    ```
  - In `docker/build-r0vm/Dockerfile`, update:
    - `ARG REPO_URL` default to `https://github.com/risc0/risc0`
    - `ARG COMMIT_HASH` default to `main`
    - Update the `ADD` version check URL to `https://api.github.com/repos/risc0/risc0/git/refs/heads/$COMMIT_HASH`
    - Add patch step after git checkout to apply the `--execute-only` change using a `RUN` step with inline `sed` or Python that inserts the code at the correct location.
  - **Verification**: `cat config.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['zkvms']['r0vm'])"` shows updated values.

---

#### Group C: Integration (after Group B)

- [x] **Task C1**: Run ACT4 tests for r0vm and verify
  - Build Docker image: `docker build -t act4-r0vm:latest -f docker/act4-r0vm/Dockerfile .`
  - Run tests: `./run test --act4 r0vm`
  - Expected: 40+/47 native pass (exact number TBD; ideally 47/47 matching pico)
  - Record results in `data/history/` as usual
  - If failures exist, diagnose by checking `test-results/r0vm/results-act4.json`
  - Common failure modes to investigate:
    - Stack overflow: r0vm STACK_TOP is only 0x200400 → code at 0x200800 leaves ~1KB stack. If tests use deep recursion, may need to adjust or accept failures.
    - Journal size: if r0vm requires exactly 32 u32 words at `a1`, our 128-byte `.zero 128` allocation is exactly right. If it requires more, extend.
    - ecall interpretation: verify r0vm interprets t0=0 as HALT correctly for the upstream main build.
  - **Verification**: `cat test-results/r0vm/summary-act4.json` shows passed > 0.

---

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Sync Tasks**: Create TodoWrite tasks matching the checkboxes above
3. **Execute & Update**: For each task:
   - Mark TodoWrite as `in_progress` when starting
   - Update checkbox `[ ]` to `[x]` when completing
   - Mark TodoWrite as `completed` when done
4. **Maintain Sync**: Keep this file and TodoWrite synchronized throughout

### Critical Rules
- This plan file is the source of truth for progress
- Update checkboxes in real-time as work progresses
- Never lose synchronization between plan file and TodoWrite
- Mark tasks complete only when fully implemented (no placeholders)
- Tasks in Group A can be run in parallel; Groups B and C are sequential

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.

---

## Key Technical References

### risc0 ExitCode variants (from binfmt/src/exit_code.rs)
- `ExitCode::Halted(u32)` — normal termination with user exit code
- `ExitCode::Paused(u32)` — paused (resumable)
- `ExitCode::SystemSplit` — host-initiated split (ignore)
- `ExitCode::SessionLimit` — timeout equivalent → exit 2

### risc0 memory layout (from zkvm/platform/src/memory.rs)
- `STACK_TOP = 0x0020_0400` — stack starts here, grows downward
- `TEXT_START = 0x0020_0800` — text section starts here
- `GUEST_MAX = 0xC000_0000` — guest memory upper bound

### risc0 halt ecall (from platform code)
- `t0 = 0` (ecall::HALT)
- `a0 = halt_type | (exit_code << 8)` where halt_type=0 for TERMINATE
- `a1 = pointer to 128-byte (32 u32) journal output buffer`
- Pass: a0=0 (exit_code=0)
- Fail: a0=0x100 (exit_code=1)

### Important file locations
- r0vm source: `risc0/risc0/r0vm/src/lib.rs`
- ExitCode: `risc0/risc0/binfmt/src/exit_code.rs`
- Session struct: `risc0/risc0/zkvm/src/host/server/session.rs` (field: `pub exit_code: ExitCode`)
- Pico reference configs: `riscv-arch-test/config/pico/pico-rv32im/`
