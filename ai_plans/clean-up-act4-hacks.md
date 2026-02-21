# ACT4 Hack Clean-Up Implementation Plan

## Executive Summary

Three workarounds were added to make ACT4 tests run on SP1/Pico/OpenVM. Two of them
are self-inflicted — they can be eliminated by fixing config files rather than patching
compiled test binaries.

**The three hacks:**

1. **CSR patch** — `patch_elfs.py` replaces CSR instructions in compiled ELFs with NOPs.
   Root cause: SP1/Pico's UDB config declares `Sm` (machine-mode spec), which tells ACT4's
   test generator to define `rvtest_mtrap_routine`, which causes the test preamble
   (`RVTEST_INIT_REGS`) to emit `csrw mstatus/mepc/mip/mtval/mcause`. SP1/Pico treat
   ALL opcode-0x73 as ecalls and panic. **Fix: remove `Sm` (and `Zicsr`) from UDB
   configs. No binary patching needed.**

2. **RVC flag patch** — `patch_elfs.py` strips the `EF_RISCV_RVC` bit from ELF headers.
   Root cause: `test_setup.h` uses `.option rvc` / `.align` / `.option norvc` as an
   alignment trick, setting the flag as a side-effect even though no compressed
   instructions are emitted. ACT4 already added `.option norelax` globally (commit
   9b8c8d28) which makes the `.option rvc` trick redundant. **Fix: remove the three
   `.option rvc`/`.option norvc` lines from `test_setup.h`. No binary patching needed.**

3. **`.word`-in-`.text` patch** — `patch_elfs.py` replaces inline data words in `.text`
   with NOPs. Root cause: ACT4's SELFCHECK mechanism places a string-pointer `.word`
   immediately after each `jal failedtest_*` call. SP1/Pico/OpenVM pre-process all
   words in executable sections as instructions and panic on non-instruction data.
   **This is a genuine ACT4 framework design issue.** The current patch is safe (the
   `.word` is dead code; patching it with a NOP loses only diagnostic strings, which
   `RVMODEL_IO_WRITE_STR` ignores for these ZKVMs anyway). An upstream fix would move
   these pointers to `.rodata`. Until that lands, this patch stays — but the code is
   simplified to only do this one thing.

**After this plan:** `patch_elfs.py` becomes a single-purpose file (~60 lines → ~40
lines), with no duplicate copies. The CSR and RVC patches are gone. The only remaining
patch is the `.word`-in-`.text` workaround, clearly documented as tracking an upstream
ACT4 issue.

---

## Goals & Objectives

### Primary Goals
- Eliminate the self-inflicted CSR hack by correcting UDB config files
- Eliminate the RVC flag hack by fixing `test_setup.h`
- Reduce `patch_elfs.py` to a single patch with clear justification
- Consolidate the three identical `patch_elfs.py` copies into one

### Secondary Objectives
- `HACK_TRACKING.md` reflects the new status
- SP1/Pico/OpenVM pass the same test counts as before (no regressions)

---

## Solution Overview

### Approach

Fix the configs so the tests compile without CSR instructions and without the RVC flag.
Then simplify the binary patcher to only handle the one remaining issue.

### Key Changes

1. **UDB YAML files** (6 files, one per ZKVM × ISA variant):
   Remove `Sm` and `Zicsr` from `implemented_extensions`. Also remove the params that
   are only valid under those extensions (`TRAP_ON_ECALL_FROM_M`, `MARCHID_IMPLEMENTED`,
   `MIMPID_IMPLEMENTED`, `VENDOR_ID_*`, `REPORT_VA_IN_MTVAL_*`, etc.). Keep I/M base
   params (`MXLEN`, `MISALIGNED_*`, `MUTABLE_MISA_M`).

   > **Fallback if schema validation rejects MXLEN without Sm**: keep `Sm` in the
   > extensions list but add `#undef rvtest_mtrap_routine` to the DUT's
   > `rvmodel_macros.h`. This prevents the generator from emitting CSR infrastructure
   > without touching the schema. This is messier but avoids schema uncertainty.

2. **`tests/env/test_setup.h`** (3 lines deleted):
   Remove the `.option rvc` / `.option norvc` alignment block. The surrounding
   `.option norelax` (already present) is sufficient.

3. **`docker/shared/patch_elfs.py`** (new file, replaces 3 identical copies):
   Stripped down to only patch 2 (`.word`-in-`.text`). Remove patch 1 (RVC flag) and
   patch 3 (CSR). Add a comment linking to HACK_TRACKING.md.

4. **Dockerfiles** (`docker/act4-{sp1,pico,openvm}/Dockerfile`):
   Change `COPY patch_elfs.py` → `COPY docker/shared/patch_elfs.py`. Requires
   changing the Docker build context in `src/test.sh` from `"$DOCKER_DIR"` to `. -f
   "$DOCKER_DIR/Dockerfile"` so the build context includes the repo root.

### Before / After

```
Before:
  UDB config declares Sm/Zicsr
    → generator defines rvtest_mtrap_routine
    → csrw mstatus/mepc/mip/mtval in every test preamble
    → patch_elfs.py replaces them with NOPs   [HACK]

  test_setup.h uses .option rvc for alignment
    → ELF header gets EF_RISCV_RVC flag
    → patch_elfs.py strips flag from header   [HACK]

  SELFCHECK embeds .word in .text
    → patch_elfs.py replaces with NOPs        [legitimate workaround]

After:
  UDB config declares only I + M
    → no rvtest_mtrap_routine
    → no CSR instructions in test preamble    [no patch needed]

  test_setup.h uses .option norelax only
    → no EF_RISCV_RVC flag                   [no patch needed]

  SELFCHECK embeds .word in .text
    → patch_elfs.py replaces with NOPs        [one remaining patch, clearly documented]
```

### Expected Outcomes
- SP1: still passes 47/47 native tests
- Pico: still passes 47/47 native tests
- OpenVM: still passes 47/47 native tests
- `patch_elfs.py` exists in one place with one patch, ~40 lines
- Jolt/Zisk unaffected (they never used `patch_elfs.py`)

---

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. Verify the exact content of each UDB yaml before editing — the subagent research
   may have minor inaccuracies. Use `cat` or Read to check before modifying.
2. After UDB changes, run `uv run act <config>` (or equivalent) schema validation
   if possible, to catch param/extension mismatches early.
3. The `test_setup.h` change affects ALL DUTs (Jolt, Zisk, Airbender, etc.). Verify
   it doesn't break them — it should be safe since `.option norelax` already supersedes
   the `.option rvc` trick.
4. When updating the Docker build context in `src/test.sh`, only change the ACT4
   build block (`act4-*` images), not the RISCOF build block.
5. Mark checkboxes as work progresses.

### Visual Dependency Tree

```
riscv-arch-test/                    (separate git repo, symlinked)
├── tests/env/test_setup.h          (Task A4: remove .option rvc alignment trick)
└── config/
    ├── sp1/
    │   ├── sp1-rv32im/sp1-rv32im.yaml            (Task A1: remove Sm, Zicsr)
    │   └── sp1-rv64im-zicclsm/sp1-rv64im-zicclsm.yaml  (Task A1: remove Sm, Zicsr)
    ├── pico/
    │   ├── pico-rv32im/pico-rv32im.yaml           (Task A2: remove Sm, Zicsr)
    │   └── pico-rv64im-zicclsm/pico-rv64im-zicclsm.yaml (Task A2: remove Sm, Zicsr)
    └── openvm/
        ├── openvm-rv32im/openvm-rv32im.yaml       (Task A3: remove Zicsr, maybe Sm)
        └── openvm-rv64im-zicclsm/openvm-rv64im-zicclsm.yaml (Task A3: remove Sm, Zicsr)

zkevm-test-monitor/
├── src/test.sh                     (Task B2: widen Docker build context for ACT4)
├── docker/
│   ├── shared/
│   │   └── patch_elfs.py           (Task B1: NEW — single-patch version, word-in-text only)
│   ├── act4-sp1/
│   │   ├── Dockerfile              (Task B2: COPY path docker/shared/patch_elfs.py)
│   │   └── patch_elfs.py           (Task B2: DELETE after Dockerfile update)
│   ├── act4-pico/
│   │   ├── Dockerfile              (Task B2: COPY path docker/shared/patch_elfs.py)
│   │   └── patch_elfs.py           (Task B2: DELETE after Dockerfile update)
│   └── act4-openvm/
│       ├── Dockerfile              (Task B2: COPY path docker/shared/patch_elfs.py)
│       └── patch_elfs.py           (Task B2: DELETE after Dockerfile update)
└── HACK_TRACKING.md                (Task C1: update status of resolved hacks)
```

---

### Execution Plan

#### Group A: Config fixes (all parallel — independent files)

- [x] **Task A1**: Fix SP1 UDB configs — remove `Sm` and `Zicsr`
  - Files:
    - `riscv-arch-test/config/sp1/sp1-rv32im/sp1-rv32im.yaml`
    - `riscv-arch-test/config/sp1/sp1-rv64im-zicclsm/sp1-rv64im-zicclsm.yaml`
  - Change in `implemented_extensions`: remove `{ name: Sm, version: "= 1.12.0" }` and
    `{ name: Zicsr, version: "= 2.0" }` from both files.
  - Change in `params`: remove all params that are only defined by `Sm` or `Zicsr`.
    Specifically remove: `PRECISE_SYNCHRONOUS_EXCEPTIONS`, `TRAP_ON_ECALL_FROM_M`,
    `TRAP_ON_EBREAK`, `MARCHID_IMPLEMENTED`, `MIMPID_IMPLEMENTED`, `VENDOR_ID_BANK`,
    `VENDOR_ID_OFFSET`, `MISALIGNED_LDST_EXCEPTION_PRIORITY`,
    `MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE`, `MISALIGNED_SPLIT_STRATEGY`,
    `TRAP_ON_ILLEGAL_WLRL`, `TRAP_ON_UNIMPLEMENTED_INSTRUCTION`,
    `TRAP_ON_RESERVED_INSTRUCTION`, `TRAP_ON_UNIMPLEMENTED_CSR`,
    and all `REPORT_VA_IN_MTVAL_*` params.
  - Keep: `MXLEN` (needed for XLEN-aware macros), `MISALIGNED_LDST`, `MUTABLE_MISA_M`.
  - **If schema validation fails because MXLEN is Sm-only**: use the fallback — keep `Sm`
    but add `#undef rvtest_mtrap_routine` at the top of
    `config/sp1/sp1-rv32im/rvmodel_macros.h` and
    `config/sp1/sp1-rv64im-zicclsm/rvmodel_macros.h` (before any other defines).
  - Verify: `grep -r "rvtest_mtrap_routine" riscv-arch-test/config/sp1/` should show
    nothing (or just the `#undef` if using the fallback approach).

- [x] **Task A2**: Fix Pico UDB configs — remove `Sm` and `Zicsr`
  - Files:
    - `riscv-arch-test/config/pico/pico-rv32im/pico-rv32im.yaml`
    - `riscv-arch-test/config/pico/pico-rv64im-zicclsm/pico-rv64im-zicclsm.yaml`
  - Same changes as A1 (identical extension list, identical param set).
  - Same fallback: `#undef rvtest_mtrap_routine` in the two `rvmodel_macros.h` files if
    schema rejects MXLEN without Sm.

- [x] **Task A3**: Fix OpenVM UDB configs — remove `Sm` and/or `Zicsr`
  - Files:
    - `riscv-arch-test/config/openvm/openvm-rv32im/openvm-rv32im.yaml`
    - `riscv-arch-test/config/openvm/openvm-rv64im-zicclsm/openvm-rv64im-zicclsm.yaml`
  - **First, read both files to check current state.** The rv32im variant may already
    lack `Sm` (it was observed to have only I, M, Zicsr). The rv64im-zicclsm variant
    likely has Sm.
  - Remove `Sm` (if present) and `Zicsr` from both. Remove associated params as per A1.
  - Same fallback as A1/A2 if schema issues arise.

- [x] **Task A4**: Fix `test_setup.h` — remove `.option rvc` alignment trick
  - File: `riscv-arch-test/tests/env/test_setup.h`
  - Find the block (around line 29-34):
    ```asm
    // Disable assembler/linker optimizations for RVTEST_BEGIN
    .option push
    .option rvc
    .align UNROLLSZ
    .option norvc
    .section .text.init
    ```
  - Remove the three lines `.option rvc`, `.align UNROLLSZ`, `.option norvc`.
    Keep the surrounding `.option push` / `.option pop` and add the `.align UNROLLSZ`
    back without the rvc context:
    ```asm
    // Disable assembler/linker optimizations for RVTEST_BEGIN
    .option push
    .option norvc
    .align UNROLLSZ
    .section .text.init
    ```
    (`.option norvc` should be explicit since we're inside an `.option push`.)
  - This change affects ALL DUTs. It is safe because:
    - `.option norelax` (already present two lines earlier) supersedes the purpose of
      the `.option rvc` alignment trick
    - No compressed instructions are generated; removing `.option rvc` only removes
      the spurious header flag

---

#### Group B: Consolidate patch_elfs.py (run in parallel after Group A)

- [x] **Task B1**: Create simplified `docker/shared/patch_elfs.py`
  - Create new file: `docker/shared/patch_elfs.py`
  - Keep only patch 2 (`.word`-in-`.text` NOP replacement). Remove:
    - The `strip_rvc_flag` logic (ELF header modification) — no longer needed after A4
    - The CSR instruction detection and replacement — no longer needed after A1-A3
  - The simplified `find_patches` function only needs to detect `.word` entries
    and raw data words in objdump output (not the `if rest.startswith('.word') or
    re.match(r'^0x[0-9a-f]+\s*$', rest)` branch is all that remains).
  - Update the docstring to explain only the remaining issue: SELFCHECK `.word`
    pointers in `.text`, why they appear, why they're safe to NOP, and a reference to
    HACK_TRACKING.md and the upstream ACT4 issue.
  - The `patch_elf` function no longer needs to strip the RVC flag (remove that block).
  - Keep the ELF32/ELF64 detection for `ei_class` only for the `vaddr_to_file_offset`
    section parsing (still needed).
  - Example simplified structure:
    ```python
    """Post-process ACT4 ELFs for ZKVMs that pre-process all words as instructions.

    Replaces non-instruction data words in executable segments with NOPs.
    ACT4's SELFCHECK mechanism embeds .word pointers (to test-name strings) in
    .text immediately after jal instructions. ZKVMs like SP1, Pico, and OpenVM
    pre-process ALL 32-bit words in executable segments as instructions, panicking
    on these data words.

    Replacing them with NOPs is safe because they are never executed (placed after
    unconditional jumps) and only read by the failure handler for diagnostics
    (RVMODEL_IO_WRITE_STR is a no-op for these ZKVMs).

    See HACK_TRACKING.md — Hack 2 for tracking an upstream ACT4 fix.

    Usage: python3 patch_elfs.py <elf_directory>
    """
    ```

- [x] **Task B2**: Update Docker build system to use shared `patch_elfs.py`
  - **Step 1**: Update `src/test.sh` ACT4 build command (line ~76):
    Change:
    ```bash
    docker build -t "act4-${ZKVM}:latest" "$DOCKER_DIR"
    ```
    To:
    ```bash
    docker build -t "act4-${ZKVM}:latest" -f "$DOCKER_DIR/Dockerfile" .
    ```
    This sets the build context to the repo root so Dockerfiles can reference
    `docker/shared/`.
  - **Step 2**: Update `docker/act4-sp1/Dockerfile`:
    Change `COPY patch_elfs.py /act4/patch_elfs.py`
    to `COPY docker/shared/patch_elfs.py /act4/patch_elfs.py`
  - **Step 3**: Same change in `docker/act4-pico/Dockerfile`
  - **Step 4**: Same change in `docker/act4-openvm/Dockerfile`
  - **Step 5**: Delete the now-redundant copies:
    - `docker/act4-sp1/patch_elfs.py`
    - `docker/act4-pico/patch_elfs.py`
    - `docker/act4-openvm/patch_elfs.py`
  - Note: also verify that `COPY entrypoint.sh` in each Dockerfile still works with the
    wider build context. It currently uses a bare `COPY entrypoint.sh`, which with a
    wider context would fail (Docker won't find it). Fix to
    `COPY docker/act4-${ZKVM}/entrypoint.sh` — since `${ZKVM}` is the directory name,
    this needs to be the literal path:
    - `COPY docker/act4-sp1/entrypoint.sh /act4/entrypoint.sh` in sp1's Dockerfile
    - `COPY docker/act4-pico/entrypoint.sh /act4/entrypoint.sh` in pico's Dockerfile
    - `COPY docker/act4-openvm/entrypoint.sh /act4/entrypoint.sh` in openvm's Dockerfile

---

#### Group C: Update documentation (after Group B)

- [x] **Task C1**: Update `HACK_TRACKING.md`
  - Mark Hack 1 (CSR instructions) as **Resolved** — UDB config fix (Tasks A1-A3)
  - Mark Hack 3 (EF_RISCV_RVC flag) as **Resolved** — test_setup.h fix (Task A4)
  - Update Hack 2 (`.word` in `.text`) status — still active, upstream issue, single
    patch in `docker/shared/patch_elfs.py`
  - Update the "Not Hacks" section to add the `docker/shared/patch_elfs.py` as a known
    remaining workaround
  - Update the summary table with resolved/unresolved status

---

#### Group D: Verification (after Group C — run before committing)

- [ ] **Task D1**: Rebuild and test SP1, Pico, OpenVM
  - From repo root:
    ```bash
    ./run test --act4 sp1
    ./run test --act4 pico
    ./run test --act4 openvm
    ```
  - Expected results (no regressions):
    - SP1: 47/47 native (rv32im), 0/72 target (expected — RV32 only)
    - Pico: 47/47 native (rv32im), 0/72 target (expected — RV32 only)
    - OpenVM: 47/47 native (rv32im), 0/72 target (expected — RV32 only)
  - If a count drops, bisect by reverting individual Group A tasks to isolate which
    config change caused the regression.
  - Also spot-check Jolt and Zisk to confirm `test_setup.h` change is safe:
    ```bash
    ./run test --act4 jolt
    ./run test --act4 zisk
    ```
    Expected: same counts as before (64/64 and 72/72 respectively)

---

## Implementation Workflow

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
- Tasks in the same group run in parallel (independent files)
- Group B starts only after all Group A tasks complete
- Group D verification is the gate before any commits

### Progress Tracking
The checkboxes above represent the authoritative status. Keep them updated.
