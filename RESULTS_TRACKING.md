# ACT4 Test Results Tracking

## Current Results (2026-02-20)

| ZKVM | Native Suite | Target (rv64im_zicclsm) | Notes |
|------|-------------|------------------------|-------|
| **SP1** | **47/47** | 0/72 (RV32 only) | t0 syscall + CSR/data-word patching |
| **Pico** | **47/47** | 0/72 (RV32 only) | t0 syscall + CSR/data-word patching |
| **OpenVM** | **47/47** | 0/72 (RV32 only) | CSR/data-word patching |
| **Jolt** | **64/64** | 64/72 | 8 target failures under investigation |
| **Zisk** | **64/64** | **72/72** | Linker script + RAM-based job scaling |
| **Airbender** | 42/47 | 0/72 (RV32 only) | 5 native failures (baseline, pre-existing) |

## Fixes Applied

### 1. SP1/Pico syscall register (rvmodel_macros.h)
Changed `li a7, 0` to `li t0, 0` in HALT macros. Both ZKVMs read syscall number
from **x5 (t0)**, not x17 (a7). Discovered by finding SP1 source at
`/home/cody/radek-sp1/crates/core/executor/src/syscalls/code.rs`.

### 2. CSR instruction patching (patch_elfs.py)
Extended `patch_elfs.py` to detect CSR instructions (opcode 0x73, funct3 != 0) via
objdump and replace them:
- CSR writes (rd=x0) → NOP
- CSR reads (rd!=x0) → `addi rd, x0, 0` (simulate CSR reading as 0)

SP1/Pico treat ALL opcode-0x73 instructions as ecalls. ACT4's test preamble uses
`csrw MSTATUS/MEPC/MIP/MTVAL/MCAUSE, x0` which triggered "invalid syscall number"
panics.

### 3. OpenVM data word patching (patch_elfs.py)
Added `patch_elfs.py` to OpenVM Docker setup. OpenVM also pre-processes all words in
executable segments as instructions, panicking on ACT4's embedded `.word` data in .text.

### 4. Zisk linker script (link.ld)
Copied exact linker script from existing RISCOF setup (`riscof/plugins/zisk/env/link.ld`).
Code at 0x80000000, data at 0xa0010000 (Zisk's RAM region: 0xa0000000-0xc0000000).

### 5. Zisk rvmodel_macros.h
Rebased on the proven RISCOF `model_test.h` layout (same DATA_SECTION with
tohost/regstate, same MSW_INT addresses). The RISCOF marchid/QEMU detection was
dropped because ACT4 compiles with `-march=rv64i` (no zicsr extension).

### 6. Zisk OOM fix — RAM-based parallelism auto-scaling
Each ziskemu instance pre-allocates **~8 GB** (6.2 GB emulation arena + 1.5 GB
threads/buffers) regardless of ELF size. With `$(nproc)` parallelism on a 64-core
machine, 64 × 8 GB = 512 GB exceeded the 251 GB available, causing OOM kills
(exit code 137 on random tests).

Fix: entrypoint now auto-scales jobs from available RAM:
`jobs = available_mb * 80% / 8192`, capped at 24, floor at 1.

### 7. Zisk binary rebuild
Force-rebuilt via Docker (`FORCE=1 ./run build zisk`) to fix libsodium.so.26 mismatch
between Arch Linux host and Ubuntu 24.04 container.

## Remaining Work

### Airbender: 42/47 native failures
5 tests fail — this is the pre-existing baseline, not a regression. Needs investigation
of which specific tests fail and why.

### Jolt: 64/72 target failures
8 tests fail on the rv64im_zicclsm target suite. Needs investigation.

### rv64im_zicclsm target: 0/72 for RV32 ZKVMs
SP1, Pico, OpenVM, and Airbender are 32-bit machines — 0/72 on the 64-bit target suite
is expected and correct.

## Files Modified

### riscv-arch-test/config/ (ACT4 configs)
- `sp1/sp1-rv32im/rvmodel_macros.h` — t0 syscall fix
- `sp1/sp1-rv64im-zicclsm/rvmodel_macros.h` — t0 syscall fix
- `pico/pico-rv32im/rvmodel_macros.h` — t0 syscall fix
- `pico/pico-rv64im-zicclsm/rvmodel_macros.h` — t0 syscall fix
- `zisk/zisk-rv64im/rvmodel_macros.h` — rebased on RISCOF model_test.h
- `zisk/zisk-rv64im/link.ld` — exact copy of RISCOF linker script
- `zisk/zisk-rv64im-zicclsm/rvmodel_macros.h` — same
- `zisk/zisk-rv64im-zicclsm/link.ld` — same

### docker/act4-{sp1,pico,openvm}/
- `patch_elfs.py` — objdump-based ELF post-processor (data words + CSR + RVC flag)
- `Dockerfile` — COPY patch_elfs.py
- `entrypoint.sh` — call patch_elfs.py after compilation

### docker/act4-zisk/
- `entrypoint.sh` — RAM-based parallelism auto-scaling

### src/test.sh
- Only pass ACT4_JOBS when explicitly set; let containers auto-scale
