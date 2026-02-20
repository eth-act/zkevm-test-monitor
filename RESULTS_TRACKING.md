# ACT4 Test Results Tracking

## Current Results (2026-02-20)

| ZKVM | Native Suite | Target (rv64im-zicclsm) | Key Fix |
|------|-------------|------------------------|---------|
| **SP1** | **47/47** (was 5/47) | 0/72 (expected, RV32 only) | t0 syscall register + CSR patching |
| **Pico** | **47/47** (was 0/47) | 0/72 (expected, RV32 only) | t0 syscall register + CSR patching |
| **OpenVM** | **47/47** (was 0/47) | 0/72 (expected, RV32 only) | Data word + CSR patching |
| **Jolt** | **64/64** | 64/72 | Already working (just needed binary build) |
| **Zisk** | **38/64** (was 0/64) | 46/72 (was 0/72) | Linker script RAM placement |
| **Airbender** | 42/47 | 0/72 (RV32 only) | Unchanged (baseline) |

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
Fixed data section placement from 0x80007000 to 0xa0010000. Zisk requires writable data
in its RAM region (0xa0000000-0xc0000000). Copied layout from existing RISCOF linker
script at `riscof/plugins/zisk/env/link.ld`.

### 5. Zisk binary rebuild
Force-rebuilt via Docker (`FORCE=1 ./run build zisk`) to fix libsodium.so.26 mismatch
between Arch Linux host and Ubuntu 24.04 container.

## Remaining Issues

### Zisk: 26/64 timeout failures (exit code 137)
Tests hang and get killed after 5-minute timeout. Likely caused by CSR instructions in
test preamble creating infinite trap loops. The passing tests likely don't define
`rvtest_mtrap_routine` (which gates CSR emission). Needs deeper investigation.

### rv64im-zicclsm target failures for RV32 ZKVMs
SP1, Pico, OpenVM, and Airbender are 32-bit machines — 0/72 on the 64-bit target suite
is expected and correct.

## Files Modified

### riscv-arch-test/config/ (ACT4 configs)
- `sp1/sp1-rv32im/rvmodel_macros.h` — t0 syscall fix
- `sp1/sp1-rv64im-zicclsm/rvmodel_macros.h` — t0 syscall fix
- `pico/pico-rv32im/rvmodel_macros.h` — t0 syscall fix
- `pico/pico-rv64im-zicclsm/rvmodel_macros.h` — t0 syscall fix
- `zisk/zisk-rv64im/link.ld` — RAM placement fix
- `zisk/zisk-rv64im-zicclsm/link.ld` — RAM placement fix

### docker/act4-{sp1,pico,openvm}/
- `patch_elfs.py` — NEW: objdump-based ELF post-processor (data words + CSR + RVC flag)
- `Dockerfile` — Added COPY for patch_elfs.py
- `entrypoint.sh` — Call patch_elfs.py instead of inline Python
