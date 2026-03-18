# Jolt ZeroOS Boot Code for ACT4 ELFs Implementation Plan

## Executive Summary

> **Problem**: Jolt's prover circuit requires the ZeroOS boot sequence (~290 cycles) before user code. ACT4 test ELFs compiled with gcc lack this boot code, causing Stage 4 Sumcheck verification failure.
>
> **Solution**: Extract jolt's boot code as an object file, inject it via the linker script's `INPUT()` directive, and modify the ACT4 linker script to place the boot code before test code. The boot code's termination (`j .`) is replaced with a jump to `rvtest_entry_point` (the ACT4 test entry).
>
> **Technical approach**: The ACT4 `act` tool compiles tests via `gcc -T link.ld test.S`. We control `link.ld`. By adding `INPUT(/path/to/boot.o)` and a `.text.boot` section, the boot code is linked into every test ELF automatically — no changes to the `act` tool or Makefile needed.
>
> **Expected outcome**: ACT4 test ELFs prove and verify through jolt-prover. The dashboard shows Prove/Verify columns for jolt.

## Goals & Objectives

### Primary Goals
- ACT4 target suite tests (64 passing execution) prove and verify through jolt-prover
- Dashboard at localhost:8000 shows Prove and Verify results for jolt

### Secondary Objectives
- No changes to the ACT4 framework (`act` tool) required
- Boot code extraction is automated in Docker build
- The same approach can extend to native suite when needed

## Solution Overview

### Approach

Use the linker script `INPUT()` directive to inject a pre-compiled jolt boot code object file into every ACT4 test ELF at link time. The boot code runs first (initializing ZeroOS runtime), then jumps to the ACT4 test's entry point.

### Key Components

1. **`boot_wrapper.S`**: Assembly source that includes the jolt boot binary blob via `.incbin` and jumps to `rvtest_entry_point` instead of `j .`
2. **`link.ld`**: Modified to include `INPUT(boot.o)` and place `.text.boot` before `.text.init`
3. **Docker build**: Compiles the jolt template guest once, extracts boot.bin, assembles boot.o

### Data Flow

```
Docker build (one-time):
  jolt guest ELF → objcopy → boot.bin → gcc -c boot_wrapper.S → boot.o

Per-test (via act tool, automatic):
  test.S + link.ld (with INPUT(boot.o)) → gcc → test.elf (with boot code)
  test.elf → patch_elfs.py → test.elf (NOPs for data words)
  test.elf → cp -rL /elfs/ → host

Host (via act4-runner):
  jolt-emu test.elf → execution result
  jolt-prover prove test.elf --verify → proof + verification
```

### Expected Outcomes
- `jolt-prover prove <act4-test>.elf --verify` exits 0 for passing tests
- `./run test jolt` shows prove/verify stats in summary JSON
- Dashboard Prove and Verify columns populate for jolt

## Implementation Tasks

### Visual Dependency Tree

```
act4-configs/jolt/
├── jolt-rv64im/
│   ├── link.ld                    (Task #1: Add INPUT(boot.o) + .text.boot section)
│   └── rvmodel_macros.h           (already has j . halt)
├── jolt-rv64im-zicclsm/
│   ├── link.ld                    (Task #1: Same changes)
│   └── rvmodel_macros.h           (already has j . halt)
│
docker/jolt/
├── Dockerfile                     (Task #0: Build template guest, extract boot.o)
├── entrypoint.sh                  (Task #2: Copy boot.o to config dirs before act)
├── boot_wrapper.S                 (Task #0: Assembly wrapper with .incbin)
│
scripts/
└── demo-jolt-proving.sh           (Task #3: Update demo with proving verification)
```

### Execution Plan

#### Group A: Boot code artifacts (sequential — Docker build depends on these)

- [ ] **Task #0**: Create boot code extraction pipeline in Docker
  - **Files to create**: `docker/jolt/boot_wrapper.S`
  - **Files to modify**: `docker/jolt/Dockerfile`
  - **What to do in `boot_wrapper.S`**:
    ```asm
    .section .text.boot, "ax"
    .globl _start
    _start:
    .incbin "boot.bin", 0, 0x40        /* boot code up to j . */
    j rvtest_entry_point                /* 4 bytes: replaces j . (2B) + unimp (2B) */
    .incbin "boot.bin", 0x44           /* rest of boot library functions */
    ```
    - `boot.bin` is the raw .text section from a compiled jolt template guest
    - Bytes 0x00-0x3F: ZeroOS boot (gp/sp setup, __platform_bootstrap call)
    - Byte 0x40-0x41: original `j .` (c.j, 2 bytes) — replaced by our `j rvtest_entry_point`
    - Byte 0x42-0x43: original `unimp` padding — consumed by the 4-byte JAL
    - Byte 0x44+: library functions (heap init, zeroos runtime)
  - **What to do in `Dockerfile`** (after existing `RUN uv run make tests`):
    ```dockerfile
    # Build jolt template guest for boot code extraction
    # This produces a minimal jolt guest ELF with ZeroOS boot code
    COPY docker/jolt/boot_wrapper.S /act4/boot_wrapper.S
    RUN cd /tmp && \
        # Clone jolt and build minimal guest (needs jolt CLI)
        # OR: use a pre-built boot.bin checked into the repo
        # For now, use the boot.bin from the act4-test guest built on the host
    ```
    - **Practical approach**: Pre-build `boot.bin` on the host (from the act4-test guest ELF we already have), copy it into the Docker image, and assemble `boot.o` during Docker build.
    - Extraction: `objcopy -O binary -j .text <template_guest.elf> boot.bin`
    - Assembly: `riscv64-unknown-elf-gcc -c -march=rv64imac -mabi=lp64 boot_wrapper.S -o boot.o`
  - **Verification**: `riscv64-unknown-elf-objdump -d boot.o` should show .text.boot section with boot code + `j rvtest_entry_point`

#### Group B: Linker script + entrypoint (parallel with boot.o verification)

- [ ] **Task #1**: Modify ACT4 linker scripts to include boot code
  - **Files**: `act4-configs/jolt/jolt-rv64im/link.ld`, `act4-configs/jolt/jolt-rv64im-zicclsm/link.ld`
  - **Changes**:
    ```ld
    OUTPUT_ARCH( "riscv" )
    ENTRY(_start)
    INPUT(boot.o)

    SECTIONS
    {
      . = 0x80000000;
      .text.boot : { *(.text.boot) }
      .text.init : { *(.text.init) }
      .text : { *(.text) }
      . = ALIGN(0x1000);
      .tohost : { *(.tohost) }
      . = ALIGN(0x1000);
      .data : { *(.data) }
      .data.string : { *(.data.string) }
      . = ALIGN(0x1000);
      .bss : { *(.bss) }
      _end = .;
    }
    ```
  - **Key details**:
    - `INPUT(boot.o)` pulls in the boot object file at link time
    - `ENTRY(_start)` points to the boot code's `_start` (in .text.boot)
    - `.text.boot` comes first, then `.text.init` (ACT4 boot), then `.text` (test code)
    - The boot code's `j rvtest_entry_point` resolves to the ACT4 entry point label
    - `rvtest_entry_point` is defined in `test_setup.h` (in .text.init section)
  - **Note**: `INPUT(boot.o)` uses a relative path — boot.o must be in the linker's search path (current directory or -L path). The entrypoint.sh must copy boot.o to the right location.

- [ ] **Task #2**: Modify Docker entrypoint to deploy boot.o before compilation
  - **File**: `docker/jolt/entrypoint.sh`
  - **Changes**: Before calling `uv run act`, copy `boot.o` to the config directory (where link.ld lives):
    ```bash
    # Deploy boot.o to config directories so INPUT(boot.o) in link.ld resolves
    cp /act4/boot.o /act4/config/jolt/jolt-rv64im/boot.o
    cp /act4/boot.o /act4/config/jolt/jolt-rv64im-zicclsm/boot.o
    ```
  - **Context**: The `act` tool runs gcc with `-T<absolute_path_to_link.ld>`. The linker searches for `INPUT()` files relative to the linker script's directory. Since `link.ld` and `boot.o` are in the same directory, it resolves.

#### Group C: Integration test (after A + B)

- [ ] **Task #3**: Test full pipeline
  - Rebuild Docker image: `docker build -t jolt:latest -f docker/jolt/Dockerfile .`
  - Regenerate ELFs: `FORCE=1 ./run test jolt`
  - Verify execution results match (64/72 target, ~116/119 native)
  - Verify proving: check `test-results/jolt/summary-act4-standard-isa.json` for proved/verified counts
  - Run demo: `scripts/demo-jolt-proving.sh`

---

## Implementation Workflow

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Sync Tasks**: Create TodoWrite tasks matching the checkboxes above
3. **Execute & Update**: For each task, mark in_progress → completed
4. **Maintain Sync**: Keep this file and TodoWrite synchronized

### Critical Rules
- boot.bin must be extracted from a jolt guest ELF built with the exact same jolt version
- The `j rvtest_entry_point` in boot_wrapper.S replaces 4 bytes (0x40-0x43) in the original boot code
- The original bytes at 0x40-0x43 are: `a001` (c.j 0 = j .) + `0000` (unimp padding)
- The replacement `j rvtest_entry_point` is a 4-byte JAL x0 instruction, resolved at link time
- Test code starts at 0x80000000 + boot_code_size (approximately 0x800019c0)
- All address references in test code are PC-relative (auipc+addi), so they work at any address

### Progress Tracking
The checkboxes above are the authoritative status of each task.
