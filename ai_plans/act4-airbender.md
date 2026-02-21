# ACT4 Airbender Implementation Plan

## Executive Summary

**Problem**: The RISC-V architectural compliance tests have migrated from RISCOF (deprecated) to
ACT4, a new Makefile+Python framework. ACT4 generates self-checking ELFs — Sail reference values
are baked in at compile time — and the DUT simply executes them and reports pass/fail via exit
code. Our current test harness is entirely RISCOF-based: it uses a Python plugin system,
signature comparison, and a RISCOF Docker image. None of this is compatible with ACT4.

**Solution**: Add an `--act4` flag to `./run test` (and `./run all`) that exercises a new,
parallel test pipeline for Airbender. This is the first step toward migrating all ZKVMs to ACT4.
The RISCOF pipeline stays untouched.

**Technical approach** — three parts in parallel:

1. **Airbender CLI** (in `zksync-airbender`): Add a `run-for-act <elf>` subcommand that loads
   an ELF directly (all PT_LOAD segments), runs it on the VM, detects HTIF `tohost` writes for
   pass/fail termination, and exits with the appropriate code. No objcopy, no signature files.

2. **ACT4 config** (in `riscv-arch-test`): Create `config/airbender/airbender-rv32im/` — the
   six config files that tell the ACT4 framework how to compile self-checking ELFs for Airbender
   (UDB YAML, `rvmodel_macros.h`, linker script, `sail.json`, `rvtest_config.h`,
   `test_config.yaml`).

3. **New Docker framework** (in `zkevm-test-monitor`): A fresh `docker/act4-airbender/`
   container that installs the RISC-V toolchain, Sail, and the ACT4 tooling; bakes in the
   pre-generated test sources; and runs `make elfs` + `run_tests.py` against the mounted
   Airbender binary at test time.

**Data flow**:

```
./run test --act4 airbender
      │
      ▼
src/test.sh  ──────────────────────────────────────────────────────┐
  (--act4 branch)                                                    │
      │                                                              │
      ▼                                                              ▼
docker run act4-airbender:latest                         binaries/airbender-binary
  │  mount: /dut/airbender-binary                         (built from riscof-dev,
  │  mount: /results/                                      now with run-for-act cmd)
  │
  ▼  inside container:
  1. uv run act config/airbender/airbender-rv32im/test_config.yaml
       └─ Generates Makefiles; calls Sail to compute expected values
  2. make -C work compile
       └─ Produces self-checking ELFs in work/airbender-rv32im/elfs/
  3. ./run_tests.py "/dut/airbender-binary run-for-act" work/airbender-rv32im/elfs/
       │  (appends ELF path to command per test)
       │
       ▼  per test:
       airbender-binary run-for-act I/add-01.elf
         └─ Load ELF segments → run VM → poll tohost
              tohost == 1  →  exit(0)   PASS
              tohost != 0  →  exit(1)   FAIL
              cycle limit  →  exit(2)   TIMEOUT
  4. Parse run_tests.py output → write /results/summary-act4.json
      │
      ▼
src/test.sh reads summary → dashboard update
```

**Expected outcomes**:
- `./run test --act4 airbender` completes end-to-end and produces pass/fail counts
- Results appear in the dashboard alongside RISCOF results
- Establishes the template Docker + config pattern for adding other ZKVMs to ACT4 later

---

## Goals & Objectives

### Primary Goals
- `./run test --act4 airbender` runs ACT4 I and M extension tests against the local Airbender
  binary and reports results
- Tests run inside Docker for reproducibility, matching the pattern of the existing RISCOF
  pipeline

### Secondary Objectives
- RISCOF pipeline is untouched — both can coexist
- ACT4 config and Docker pattern are reusable as a template for other ZKVMs
- Results feed the existing dashboard in the same JSON format

---

## Solution Overview

### Key Components

1. **`riscv_transpiler/src/act.rs`** (new file in zksync-airbender): ELF loading and HTIF-based
   test execution. Loads all ELF PT_LOAD segments into the VM's 1 GB address space, locates the
   `tohost` symbol, runs the VM in polling chunks, and returns an exit code.

2. **`tools/cli/src/main.rs`** (modified in zksync-airbender): Adds `RunForAct` command that
   takes a single positional ELF path argument (compatible with `run_tests.py`'s calling
   convention) and calls into the new `act.rs` module, then `std::process::exit`s with the
   result.

3. **`config/airbender/airbender-rv32im/`** (new directory in riscv-arch-test): Six files
   describing Airbender to the ACT4 framework. The linker script places code at `0x0100_0000`
   (Airbender's entry point) and `tohost` at `0x0100_1000`. `rvmodel_macros.h` uses the
   standard HTIF tohost/fromhost termination pattern. `sail.json` describes Airbender's memory
   map to the Sail reference model used at ELF compile time.

4. **`docker/act4-airbender/`** (new directory in zkevm-test-monitor): Dockerfile and
   entrypoint that install all dependencies, bake in the riscv-arch-test source at a specific
   commit with tests pre-generated (`make tests` already run), and at runtime compile ELFs with
   the Airbender config, run them, and produce a `summary-act4.json`.

5. **`run` + `src/test.sh`** (modified in zkevm-test-monitor): `--act4` flag added to `test`
   and `all` subcommands; `test.sh` routes to the new Docker container when `--act4` is set.

---

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. The `run-for-act` command must accept the ELF as a **positional argument** (not `--elf`), because `run_tests.py` appends the ELF path directly: `[*cmd, str(elf_path)]`.
2. `std::process::exit(code)` must be called at the end of `run-for-act` — returning normally from `main` won't work since we need to propagate exit code 2 for timeouts.
3. The ACT4 Docker container is entirely separate from the RISCOF container (`riscof:latest`). Do not modify anything in `riscof/`.
4. `sail.json` memory regions must cover the full Airbender address space (`0x0` to `0x3FFF_FFFF`) so Sail can execute tests that use `.tohost` at `0x0100_1000` and data at `0x0100_2000+`.
5. The UDB YAML must include `Sm` so the ACT4 framework generates M-mode test scaffolding. Airbender runs as if it were always in M-mode (no privilege transitions actually occur in I/M tests).

### Visual Dependency Tree

```
zksync-airbender/
├── riscv_transpiler/
│   ├── src/
│   │   ├── act.rs        (Task A: New — ELF loader + HTIF execution + exit code)
│   │   └── lib.rs        (Task A: Add `pub mod act;`)
│   └── Cargo.toml        (Task A: No new deps needed — object crate already present)
└── tools/cli/src/
    └── main.rs            (Task A: Add RunForAct command + run_for_act_binary fn)

riscv-arch-test/
└── config/airbender/airbender-rv32im/
    ├── test_config.yaml      (Task B: Framework config — name, compiler, sail exe, udb path)
    ├── airbender-rv32im.yaml (Task B: UDB config — RV32IM + Sm, no F/D/C/A/V)
    ├── rvmodel_macros.h      (Task B: HTIF tohost/fromhost HALT_PASS/HALT_FAIL macros)
    ├── rvtest_config.h       (Task B: No PMPs, no FP, no vector, ACCESS_FAULT_ADDRESS)
    ├── link.ld               (Task B: Base 0x01000000, tohost at 0x01001000)
    └── sail.json             (Task B: Sail memory map covering Airbender address space)

zkevm-test-monitor/
├── docker/act4-airbender/
│   ├── Dockerfile          (Task C: Ubuntu 24.04, toolchain, Sail, uv, pre-baked tests)
│   └── entrypoint.sh       (Task C: make elfs + run_tests.py + write summary-act4.json)
├── src/test.sh              (Task D: --act4 branch → docker run act4-airbender)
└── run                      (Task D: --act4 flag in test/all subcommands)
```

### Execution Plan

---

#### Group A: Core implementation (Tasks A and B — run fully in parallel)

---

- [x] **Task A**: Add `run-for-act` command to Airbender

  **Repo**: `/home/cody/zksync-airbender`

  **Files**:
  - Create: `riscv_transpiler/src/act.rs`
  - Modify: `riscv_transpiler/src/lib.rs` (add `pub mod act;`)
  - Modify: `tools/cli/src/main.rs` (add command + handler)

  **`riscv_transpiler/src/act.rs`** — implement the following:

  ```rust
  use crate::ir::{preprocess_bytecode, FullMachineDecoderConfig, Instruction};
  use crate::vm::{DelegationsCounters, RamWithRomRegion, Register, SimpleTape, State, VM};
  use common_constants::rom::ROM_SECOND_WORD_BITS;
  use object::{Object, ObjectSection, ObjectSegment, ObjectSymbol};

  const ROM_SECOND_WORD_BITS: usize = common_constants::rom::ROM_SECOND_WORD_BITS;

  /// Exit codes returned by run_elf_for_act
  /// 0 = HALT_PASS (tohost == 1)
  /// 1 = HALT_FAIL (tohost == 3 or any nonzero value != 1)
  /// 2 = cycle limit exhausted without tohost signal

  pub fn run_elf_for_act(elf_data: &[u8], max_cycles: usize) -> i32 {
      let (words, entry_point_u32, tohost_addr) = load_elf_to_words(elf_data);
      let tohost_word_idx = (tohost_addr / 4) as usize;

      // Build instruction tape
      let instructions: Vec<Instruction> =
          preprocess_bytecode::<FullMachineDecoderConfig>(&words);
      let tape = SimpleTape::new(&instructions);

      // Build RAM backing (same word array)
      let ram_words = words.len().max(1 << 28); // at least 1GB / 4
      let mut backing = vec![Register { value: 0, timestamp: 0 }; ram_words];
      for (i, &w) in words.iter().enumerate() {
          backing[i].value = w;
      }
      let mut ram = RamWithRomRegion::<ROM_SECOND_WORD_BITS> { backing };

      let mut state = State::initial_with_counters(DelegationsCounters::default());
      state.pc = entry_point_u32;

      const POLL_CHUNK: usize = 100_000;
      let mut remaining = max_cycles;

      loop {
          let chunk = remaining.min(POLL_CHUNK);
          VM::<DelegationsCounters>::run_basic_unrolled(
              &mut state, &mut ram, &mut (), &tape, chunk, &mut (),
          );
          remaining = remaining.saturating_sub(chunk);

          let tohost_val = ram.backing[tohost_word_idx].value;
          if tohost_val == 1 {
              return 0; // RVMODEL_HALT_PASS
          } else if tohost_val != 0 {
              return 1; // RVMODEL_HALT_FAIL
          }
          if remaining == 0 {
              eprintln!("act: cycle limit ({max_cycles}) exhausted");
              return 2;
          }
      }
  }

  /// Load ELF PT_LOAD segments into a flat word array.
  /// Returns (word_array, entry_point, tohost_symbol_address).
  fn load_elf_to_words(elf_data: &[u8]) -> (Vec<u32>, u32, u32) {
      let elf = object::File::parse(elf_data).expect("act: failed to parse ELF");

      // Find highest virtual address to size the array
      let max_addr = elf
          .segments()
          .filter(|s| s.file_range().is_some())
          .map(|s| s.address() + s.size())
          .max()
          .unwrap_or(0) as usize;

      // Round up to next 4-byte word boundary
      let num_words = (max_addr + 3) / 4;
      let mut words = vec![0u32; num_words];

      // Load each loadable segment
      for segment in elf.segments() {
          if let Ok(data) = segment.data() {
              if data.is_empty() { continue; }
              let addr = segment.address() as usize;
              let word_start = addr / 4;
              // Convert bytes to words (little-endian)
              let padded_len = (data.len() + 3) / 4 * 4;
              let mut padded = data.to_vec();
              padded.resize(padded_len, 0);
              for (i, chunk) in padded.chunks_exact(4).enumerate() {
                  if word_start + i < words.len() {
                      words[word_start + i] = u32::from_le_bytes(chunk.try_into().unwrap());
                  }
              }
          }
      }

      // Entry point from ELF header
      let entry_point = elf.entry() as u32;

      // Find tohost symbol
      let tohost_addr = elf
          .symbols()
          .find(|s| s.name() == Ok("tohost"))
          .map(|s| s.address() as u32)
          .expect("act: ELF has no 'tohost' symbol — check linker script");

      (words, entry_point, tohost_addr)
  }
  ```

  **`riscv_transpiler/src/lib.rs`**: Add `pub mod act;` alongside existing module declarations.

  **`tools/cli/src/main.rs`** — add to Commands enum:
  ```rust
  /// Run a self-checking ACT4 ELF and exit with its pass/fail code.
  /// ELF path is a positional argument for compatibility with run_tests.py.
  RunForAct {
      /// Path to self-checking ELF produced by the ACT4 framework
      elf: String,
      /// Maximum number of RISC-V cycles before timeout (exit code 2)
      #[arg(long, default_value = "10000000")]
      cycles: usize,
  },
  ```

  Add to the `match command` block:
  ```rust
  Commands::RunForAct { elf, cycles } => {
      let elf_data = fs::read(elf).expect("Failed to read ELF file");
      let exit_code = riscv_transpiler::act::run_elf_for_act(&elf_data, *cycles);
      std::process::exit(exit_code);
  }
  ```

  **Verify build**: `cargo build --profile test-release -p cli` in zksync-airbender must succeed.

  **Quick smoke test**:
  ```bash
  # From zksync-airbender root, after building:
  # The binary runs with a passing/failing test should exit 0/1
  ./target/test-release/cli run-for-act --help
  ```

---

- [x] **Task B**: Create ACT4 config for Airbender in riscv-arch-test

  **Repo**: `/home/cody/riscv-arch-test`

  **Create directory**: `config/airbender/airbender-rv32im/`

  ---

  **`test_config.yaml`**:
  ```yaml
  name: airbender-rv32im
  compiler_exe: riscv64-unknown-elf-gcc
  objdump_exe: riscv64-unknown-elf-objdump
  ref_model_exe: sail_riscv_sim
  udb_config: airbender-rv32im.yaml
  linker_script: link.ld
  dut_include_dir: .
  ```

  ---

  **`airbender-rv32im.yaml`** (UDB config — RV32IM + Sm, no F/D/C/A/V):
  ```yaml
  # yaml-language-server: $schema=../../../external/riscv-unified-db/spec/schemas/config_schema.json
  ---
  $schema: config_schema.json#
  kind: architecture configuration
  type: fully configured
  name: airbender-rv32im
  description: ZKsync Airbender RV32IM ZK-VM

  implemented_extensions:
    - { name: I,       version: "= 2.1" }
    - { name: M,       version: "= 2.0" }
    - { name: Zicsr,   version: "= 2.0" }
    - { name: Sm,      version: "= 1.12.0" }

  params:
    # M params
    MUTABLE_MISA_M: false
    # Sm params
    MXLEN: 32
    PRECISE_SYNCHRONOUS_EXCEPTIONS: true
    TRAP_ON_ECALL_FROM_M: true
    TRAP_ON_EBREAK: true
    MARCHID_IMPLEMENTED: false
    MIMPID_IMPLEMENTED: false
    VENDOR_ID_BANK: 0x0
    VENDOR_ID_OFFSET: 0x0
    MISALIGNED_LDST: true
    MISALIGNED_LDST_EXCEPTION_PRIORITY: low
    MISALIGNED_MAX_ATOMICITY_GRANULE_SIZE: 4
    MISALIGNED_SPLIT_STRATEGY: sequential_bytes
    TRAP_ON_ILLEGAL_WLRL: false
    TRAP_ON_UNIMPLEMENTED_INSTRUCTION: true
    TRAP_ON_RESERVED_INSTRUCTION: true
    TRAP_ON_UNIMPLEMENTED_CSR: true
    REPORT_VA_IN_MTVAL_ON_BREAKPOINT: false
    REPORT_VA_IN_MTVAL_ON_LOAD_MISALIGNED: false
    REPORT_VA_IN_MTVAL_ON_STORE_AMO_MISALIGNED: false
    REPORT_VA_IN_MTVAL_ON_INSTRUCTION_MISALIGNED: false
    REPORT_VA_IN_MTVAL_ON_LOAD_ACCESS_FAULT: false
    REPORT_VA_IN_MTVAL_ON_STORE_AMO_ACCESS_FAULT: false
    REPORT_VA_IN_MTVAL_ON_INSTRUCTION_ACCESS_FAULT: false
    REPORT_ENCODING_IN_MTVAL_ON_ILLEGAL_INSTRUCTION: false
    MTVAL_WIDTH: 32
    CONFIG_PTR_ADDRESS: 0
    PMA_GRANULARITY: 3
    PHYS_ADDR_WIDTH: 32
    M_MODE_ENDIANNESS: little
    MISA_CSR_IMPLEMENTED: false
    MTVEC_ACCESS: rw
    MTVEC_MODES: [0]
    MTVEC_BASE_ALIGNMENT_DIRECT: 4
    MTVEC_ILLEGAL_WRITE_BEHAVIOR: retain
    COUNTINHIBIT_EN: [false, false, false, false, false, false, false, false,
                      false, false, false, false, false, false, false, false,
                      false, false, false, false, false, false, false, false,
                      false, false, false, false, false, false, false, false]
  ```

  ---

  **`rvmodel_macros.h`** (HTIF tohost/fromhost — identical pattern to Sail/Spike):
  ```c
  // rvmodel_macros.h for ZKsync Airbender (RV32IM ZK-VM)
  // Uses HTIF tohost/fromhost for test termination.
  // SPDX-License-Identifier: BSD-3-Clause

  #ifndef _COMPLIANCE_MODEL_H
  #define _COMPLIANCE_MODEL_H

  #define RVMODEL_DATA_SECTION \
          .pushsection .tohost,"aw",@progbits;                \
          .align 8; .global tohost; tohost: .dword 0;         \
          .align 8; .global fromhost; fromhost: .dword 0;     \
          .popsection

  ##### STARTUP #####
  #define RVMODEL_BOOT

  ##### TERMINATION #####

  // Write 1 to tohost → PASS (airbender run-for-act exits 0)
  #define RVMODEL_HALT_PASS  \
    li x1, 1                ;\
    la t0, tohost           ;\
    write_tohost_pass:      ;\
      sw x1, 0(t0)          ;\
      sw x0, 4(t0)          ;\
      j write_tohost_pass   ;\

  // Write 3 to tohost → FAIL (airbender run-for-act exits 1)
  #define RVMODEL_HALT_FAIL  \
    li x1, 3                ;\
    la t0, tohost           ;\
    write_tohost_fail:      ;\
      sw x1, 0(t0)          ;\
      sw x0, 4(t0)          ;\
      j write_tohost_fail   ;\

  ##### IO #####

  // No console hardware in Airbender; IO macros are no-ops.
  // Failure diagnostics from the test framework will not be printed,
  // but pass/fail is still correctly signaled via tohost.
  #define RVMODEL_IO_INIT(_R1, _R2, _R3)
  #define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)

  ##### Access Fault #####
  #define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000

  ##### Machine Timer #####
  // Airbender has no CLINT; timer CSRs unimplemented.
  #define RVMODEL_MTIME_ADDRESS    0x02004000
  #define RVMODEL_MTIMECMP_ADDRESS 0x02000000

  ##### Machine Interrupts #####
  #define RVMODEL_SET_MEXT_INT
  #define RVMODEL_CLR_MEXT_INT
  #define RVMODEL_SET_MSW_INT
  #define RVMODEL_CLR_MSW_INT

  ##### Supervisor Interrupts #####
  #define RVMODEL_SET_SEXT_INT
  #define RVMODEL_CLR_SEXT_INT
  #define RVMODEL_SET_SSW_INT
  #define RVMODEL_CLR_SSW_INT

  #endif // _COMPLIANCE_MODEL_H
  ```

  ---

  **`rvtest_config.h`**:
  ```c
  // rvtest_config.h for ZKsync Airbender
  // No FP, no vector, no PMP, no timer CSR.
  // SPDX-License-Identifier: BSD-3-Clause

  #ifndef _RVTEST_CONFIG_H
  #define _RVTEST_CONFIG_H

  // Address that causes access faults (not mapped)
  #define RVMODEL_ACCESS_FAULT_ADDRESS  0x00000000

  // PMP configuration (none)
  #define RVMODEL_PMP_GRAIN   0
  #define RVMODEL_NUM_PMPS    0

  // Extension support flags
  // FP not supported
  // Vector not supported
  // Atomic not supported (no A extension)

  // Timer: not implemented
  #define TIME_CSR_IMPLEMENTED 0

  #endif // _RVTEST_CONFIG_H
  ```

  ---

  **`link.ld`** (base `0x0100_0000` — Airbender's entry point):
  ```ld
  OUTPUT_ARCH( "riscv" )
  ENTRY(rvtest_entry_point)

  SECTIONS
  {
    . = 0x01000000;
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

  ---

  **`sail.json`** (Sail reference model config — RV32IM, covers Airbender's address space):
  ```json
  {
    "base": {
      "xlen": 32,
      "E": false,
      "writable_misa": false,
      "writable_fiom": false,
      "writable_hpm_counters": { "len": 32, "value": "0x0" },
      "xtval_nonzero": {
        "illegal_instruction": false,
        "software_breakpoint": false,
        "instruction_address_misaligned": false,
        "load_address_misaligned": false,
        "store_amo_address_misaligned": false,
        "instruction_access_fault": false,
        "load_access_fault": false,
        "store_amo_access_fault": false
      },
      "reserved_behavior": {
        "amocas_odd_register": "AMOCAS_Illegal",
        "fcsr_rm": "Fcsr_RM_Illegal",
        "pmpcfg_write_only": "PMP_ClearPermissions",
        "xenvcfg_cbie": "Xenvcfg_ClearPermissions",
        "rv32zdinx_odd_register": "Zdinx_Illegal"
      }
    },
    "memory": {
      "pmp": {
        "grain": 0,
        "count": 0,
        "usable_count": 0,
        "tor_supported": false,
        "na4_supported": false,
        "napot_supported": false
      },
      "misaligned": {
        "supported": true,
        "byte_by_byte": true,
        "order_decreasing": false,
        "allowed_within_exp": 12
      },
      "translation": { "dirty_update": false },
      "dtb_address": { "len": 64, "value": "0x0" },
      "regions": [
        {
          "base": { "len": 64, "value": "0x0" },
          "size": { "len": 64, "value": "0x40000000" },
          "attributes": {
            "cacheable": true,
            "coherent": true,
            "executable": true,
            "readable": true,
            "writable": true,
            "read_idempotent": true,
            "write_idempotent": true,
            "misaligned_fault": "NoFault",
            "reservability": "RsrvNone",
            "supports_cbo_zero": false
          },
          "include_in_device_tree": false
        }
      ]
    },
    "platform": {
      "vendorid": 0,
      "archid": 0,
      "impid": 0,
      "hartid": 0,
      "cache_block_size_exp": 6,
      "reservation_set_size_exp": 6,
      "clint": { "base": 33554432, "size": 65536 },
      "clock_frequency": 1000000000,
      "instructions_per_tick": 100,
      "wfi_is_nop": true
    },
    "extensions": {
      "M": { "supported": true },
      "A": { "supported": false },
      "F": { "supported": false },
      "D": { "supported": false },
      "V": { "support_level": "Disabled", "vlen_exp": 7, "elen_exp": 6, "vl_use_ceil": false }
    }
  }
  ```

---

#### Group B: Integration (Tasks C and D — run fully in parallel, after Group A)

---

- [x] **Task C**: Create ACT4 Airbender Docker framework

  **Repo**: `/home/cody/zkevm-test-monitor`

  **Create**: `docker/act4-airbender/Dockerfile` and `docker/act4-airbender/entrypoint.sh`

  ---

  **`docker/act4-airbender/Dockerfile`**:
  ```dockerfile
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
      && rm -rf /var/lib/apt/lists/*

  # Install uv (Python package manager used by riscv-arch-test)
  RUN curl -LsSf https://astral.sh/uv/install.sh | sh
  ENV PATH="/root/.local/bin:${PATH}"

  # Install RISC-V GCC toolchain
  ENV RISCV_TOOLCHAIN_VERSION=2025.08.08
  RUN curl -L https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_TOOLCHAIN_VERSION}/riscv64-elf-ubuntu-24.04-gcc-nightly-${RISCV_TOOLCHAIN_VERSION}-nightly.tar.xz | \
      tar -xJ -C /opt/ && \
      mv /opt/riscv /opt/riscv64
  ENV PATH="/opt/riscv64/bin:${PATH}"

  # Install Sail RISC-V simulator
  RUN curl -L https://github.com/riscv/sail-riscv/releases/download/0.7/sail_riscv-Linux-x86_64.tar.gz | \
      tar -xz -C /opt/ && \
      mv /opt/sail_riscv-Linux-x86_64 /opt/sail-riscv
  ENV PATH="/opt/sail-riscv/bin:${PATH}"

  # Clone riscv-arch-test at a specific act4 commit and pre-generate tests
  # (make tests is slow and only depends on the repo, not on the DUT)
  ARG ARCH_TEST_COMMIT=act4
  WORKDIR /act4
  RUN git clone --branch act4 --single-branch \
          https://github.com/riscv-non-isa/riscv-arch-test.git . && \
      git checkout ${ARCH_TEST_COMMIT} && \
      git rev-parse HEAD > /act4/arch_test_commit.txt

  # Initialize UDB submodule (needed for UDB validation during make elfs)
  RUN git submodule update --init external/riscv-unified-db

  # Pre-generate assembly test sources — this is slow but only needs to run once at image build time
  RUN uv run make tests

  # Copy Airbender-specific config into the image
  # (Will be updated when the config directory exists in the repo)
  # At runtime, the config is already in the cloned repo if the commit includes it;
  # otherwise override via volume mount.

  # Create mount points
  RUN mkdir -p /dut /results

  COPY entrypoint.sh /act4/entrypoint.sh
  RUN chmod +x /act4/entrypoint.sh

  ENTRYPOINT ["/act4/entrypoint.sh"]
  ```

  **Note on the config**: Once Task B is merged to the riscv-arch-test repo and the commit is
  updated in the Dockerfile, the config will be baked in via the `git clone`. During development,
  mount the local config directory:
  ```bash
  -v "$PWD/riscv-arch-test/config/airbender:/act4/config/airbender"
  ```

  ---

  **`docker/act4-airbender/entrypoint.sh`**:
  ```bash
  #!/bin/bash
  set -eu

  # Expected mounts:
  #   /dut/airbender-binary  — the Airbender CLI binary
  #   /results/              — output directory for summary JSON

  DUT=/dut/airbender-binary
  RESULTS=/results
  CONFIG=config/airbender/airbender-rv32im/test_config.yaml
  WORKDIR=/act4/work

  if [ ! -x "$DUT" ]; then
      echo "Error: No executable found at $DUT"
      exit 1
  fi

  cd /act4

  # Step 1: Generate Makefiles + compile self-checking ELFs
  # This runs Sail internally to compute expected values and bake them into the ELFs.
  echo "Generating Makefiles for airbender-rv32im..."
  uv run act "$CONFIG" \
      --workdir "$WORKDIR" \
      --test-dir tests \
      --extensions I,M

  echo "Compiling self-checking ELFs..."
  make -C "$WORKDIR" compile

  ELF_DIR="$WORKDIR/airbender-rv32im/elfs"
  if [ ! -d "$ELF_DIR" ] || [ -z "$(ls "$ELF_DIR"/*.elf 2>/dev/null)" ]; then
      echo "Error: No ELFs found in $ELF_DIR"
      exit 1
  fi

  # Step 2: Run ELFs with the Airbender binary
  echo "Running tests with airbender..."
  JOBS="${ACT4_JOBS:-$(nproc)}"

  # run_tests.py exits 0 if all pass, 1 if any fail
  # Capture output for parsing
  RUN_OUTPUT=$(uv run ./run_tests.py "$DUT run-for-act" "$ELF_DIR" -j "$JOBS" 2>&1) || true
  echo "$RUN_OUTPUT"

  # Step 3: Parse results from run_tests.py output
  # Output format: "All N tests passed." OR "M out of N tests failed."
  TOTAL=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ tests? (passed|failed)' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo "0")
  FAILED=$(echo "$RUN_OUTPUT" | grep -oE '[0-9]+ out of' | grep -oE '[0-9]+' | head -1 || echo "0")
  PASSED=$((TOTAL - FAILED))

  # Write summary JSON (matches format expected by src/update.py)
  mkdir -p "$RESULTS"
  cat > "$RESULTS/summary-act4.json" << EOF
  {
    "zkvm": "airbender",
    "suite": "act4",
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "passed": $PASSED,
    "failed": $FAILED,
    "total": $TOTAL
  }
  EOF

  echo "Results: $PASSED/$TOTAL passed"
  echo "Summary written to $RESULTS/summary-act4.json"
  ```

---

- [x] **Task D**: Add `--act4` flag to `./run` and `src/test.sh`

  **Repo**: `/home/cody/zkevm-test-monitor`

  **Files**:
  - Modify: `run`
  - Modify: `src/test.sh`

  ---

  **`run`** — update the `test` and `all` cases to accept `--act4` alongside `--arch`/`--extra`.

  Change the validation regex in `test)` and `all)` from:
  ```bash
  if ! echo "$@" | grep -E '(--(arch|extra))' > /dev/null; then
  ```
  to:
  ```bash
  if ! echo "$@" | grep -E '(--(arch|extra|act4))' > /dev/null; then
  ```

  Update the SUITE_TYPE extraction loop in both `test)` and `all)` to include:
  ```bash
  elif [[ "$arg" == "--act4" ]]; then
      SUITE_TYPE="act4"
  ```

  Update the usage/help text to document `--act4`:
  ```
  test [--arch|--extra|--act4] [--build-only] [zkvm]
                                         - Run tests (suite required)
  ```
  And in the examples:
  ```
  ./run test --act4 airbender          # Test airbender with ACT4 suite
  ```

  ---

  **`src/test.sh`** — add `--act4` as a valid TEST_SUITE and add the ACT4 execution branch.

  1. Add `--act4)` to the flag parsing loop (alongside `--arch` and `--extra`):
     ```bash
     --act4)
       TEST_SUITE="act4"
       shift
       ;;
     ```

  2. Update the validation check to accept `act4`:
     ```bash
     if [ -z "$TEST_SUITE" ]; then
       echo "❌ Error: Must specify --arch, --extra, or --act4"
     ```

  3. Before the ZKVM loop, add a branch for act4 that builds the Docker image and runs it:
     ```bash
     # Handle ACT4 test suite (currently airbender-only)
     if [ "$TEST_SUITE" = "act4" ]; then
       echo "🔨 Building ACT4 Docker image..."
       docker build -t act4-airbender:latest docker/act4-airbender/ || {
         echo "❌ Failed to build ACT4 Docker image"
         exit 1
       }

       for ZKVM in $ZKVMS; do
         if [ "$ZKVM" != "airbender" ]; then
           echo "  ⚠️  ACT4 suite currently only supports airbender, skipping $ZKVM"
           continue
         fi

         if [ ! -f "binaries/${ZKVM}-binary" ]; then
           echo "  ⚠️  No binary found for $ZKVM, skipping"
           continue
         fi

         echo "Running ACT4 tests for $ZKVM..."
         mkdir -p test-results/${ZKVM}

         CPUSET_ARG=""
         if [ -n "$JOBS" ]; then
           LAST_CORE=$((JOBS - 1))
           CPUSET_ARG="--cpuset-cpus=0-${LAST_CORE}"
         fi

         docker run --rm \
           ${CPUSET_ARG} \
           -e ACT4_JOBS=${JOBS:-$(nproc)} \
           -v "$PWD/binaries/${ZKVM}-binary:/dut/airbender-binary" \
           -v "$PWD/test-results/${ZKVM}:/results" \
           act4-airbender:latest || true

         # Record history
         if [ -f "test-results/${ZKVM}/summary-act4.json" ]; then
           PASSED=$(jq '.passed' "test-results/${ZKVM}/summary-act4.json")
           TOTAL=$(jq '.total' "test-results/${ZKVM}/summary-act4.json")
           echo "  ✅ ACT4 ${ZKVM}: ${PASSED}/${TOTAL} passed"

           mkdir -p data/history
           HISTORY_FILE="data/history/${ZKVM}-act4.json"
           TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
           ZKVM_COMMIT=$(cat "data/commits/${ZKVM}.txt" 2>/dev/null || echo "unknown")
           RUN_DATE=$(date -u +"%Y-%m-%d")
           FAILED=$(jq '.failed' "test-results/${ZKVM}/summary-act4.json")

           if [ -f "$HISTORY_FILE" ]; then
             jq --arg date "$RUN_DATE" \
               --arg monitor "$TEST_MONITOR_COMMIT" \
               --arg zkvm "$ZKVM_COMMIT" \
               --argjson passed "$PASSED" \
               --argjson total "$TOTAL" \
               '.runs += [{"date": $date, "test_monitor_commit": $monitor,
                           "zkvm_commit": $zkvm, "isa": "rv32im", "suite": "act4",
                           "passed": $passed, "total": $total, "notes": ""}]' \
               "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
           else
             cat > "$HISTORY_FILE" << HISTORY
  {
    "zkvm": "${ZKVM}",
    "suite": "act4",
    "runs": [{
      "date": "${RUN_DATE}",
      "test_monitor_commit": "${TEST_MONITOR_COMMIT}",
      "zkvm_commit": "${ZKVM_COMMIT}",
      "isa": "rv32im",
      "suite": "act4",
      "passed": ${PASSED},
      "total": ${TOTAL},
      "notes": ""
    }]
  }
  HISTORY
           fi
         else
           echo "  ⚠️  No summary generated for $ZKVM"
         fi
       done
       exit 0
     fi
     ```

  4. The rest of `test.sh` (the RISCOF branch) is unchanged and only reached when
     `TEST_SUITE` is `arch` or `extra`.

---

#### Group C: Rebuild and smoke test (after Groups A and B)

- [x] **Task E**: Rebuild Airbender binary and verify end-to-end

  **Steps** (sequential):

  1. Build updated binary locally:
     ```bash
     cd /home/cody/zksync-airbender
     cargo build --profile test-release -p cli
     cp target/test-release/cli /home/cody/zkevm-test-monitor/binaries/airbender-binary
     ```

  2. Verify the new command exists:
     ```bash
     ./binaries/airbender-binary run-for-act --help
     ```

  3. Build the ACT4 Docker image (may take 20-30 min first time due to toolchain + Sail download
     and `make tests`):
     ```bash
     cd /home/cody/zkevm-test-monitor
     docker build -t act4-airbender:latest docker/act4-airbender/
     ```

  4. If the Airbender config (Task B) hasn't been pushed to the riscv-arch-test remote yet,
     mount it during the first run:
     ```bash
     docker run --rm \
       -v "$PWD/binaries/airbender-binary:/dut/airbender-binary" \
       -v "$PWD/riscv-arch-test/config/airbender:/act4/config/airbender" \
       -v "$PWD/test-results/airbender:/results" \
       act4-airbender:latest
     ```

  5. Full end-to-end via `./run`:
     ```bash
     ./run test --act4 airbender
     ```

  6. Verify `test-results/airbender/summary-act4.json` is generated with sensible pass/fail
     counts (expect ~90%+ of I-extension tests to pass; M-extension tests for div/rem/mulh may
     fail — that's expected and informative).

---

## Known Limitations and Expected Failures

- **M extension**: `div`, `rem`, `mulh`, `mulhsu` are not implemented in Airbender. Those tests
  will exit 1. This is expected and informative — it documents Airbender's compliance gaps.

- **Privilege architecture**: `RVTEST_CODE_END` calls `RVTEST_GOTO_MMODE` which likely issues
  CSR writes or an `ecall`. Airbender processes these as NOP-like or undefined behavior. For
  pure integer (I/M) tests that don't trap, this is unlikely to cause false failures, but monitor
  test results for unexpected failures on simple instructions.

- **No console output on failure**: `RVMODEL_IO_WRITE_STR` is defined as a no-op. When a test
  fails, the detailed diagnostic string (failing instruction, expected vs actual value) is not
  printed. Pass/fail is still correctly signaled via `tohost`. To see diagnostics,
  `RVMODEL_IO_WRITE_STR` would need a Airbender-specific implementation.

- **Sail version pinning**: The Dockerfile downloads Sail 0.7. If ACT4 requires a different
  version, update `sail_riscv-Linux-x86_64.tar.gz` URL accordingly.

- **`make tests` at image build time**: The first Docker image build takes ~20-30 minutes. The
  result is baked in at the act4 commit. Update `ARCH_TEST_COMMIT` build arg when the repo
  advances and rebuilding is needed.

---

## Implementation Workflow

### Required Process
1. **Load Plan**: Read this entire plan before starting
2. **Create Tasks**: Create TodoWrite tasks matching the checkboxes
3. **Execute & Update**: For each task:
   - Mark TodoWrite `in_progress` when starting
   - Update checkbox `[ ]` → `[x]` when complete
   - Mark TodoWrite `completed` when done
4. **Run in parallel**: Tasks A and B have no dependencies on each other — run them concurrently.
   Tasks C and D have no dependencies on each other — run them concurrently after A+B complete.

### Critical Rules
- This plan file is the source of truth for progress
- Never mark a task complete with failing builds or broken tests
- Task E is a validation gate — only mark complete after `./run test --act4 airbender` succeeds
