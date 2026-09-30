# zkevm-test-monitor

Compliance testing for zkVMs with two test suites:

- **ISA tests:** RISC-V ISA compliance, with the [ACT4](https://github.com/riscv/riscv-arch-test) framework (release [4.1.0](https://github.com/riscv/riscv-arch-test/releases/tag/4.1.0)).
- **eth-act standards tests:** the [eth-act zkEVM standards](https://github.com/eth-act/zkevm-standards) for guest interfaces (I/O, cryptographic accelerators, memory operations), which EIP-8025 readiness uses, with small C programs in [`tests/eth-act-standards/`](tests/eth-act-standards/README.md).

**Dashboard:** https://eth-act.github.io/zkevm-test-monitor/

## Test pipelines

Both pipelines build test ELFs in Docker and run them on the host with one Rust runner
([`src/runner/`](src/runner/)), through a backend per zkVM and suite. They differ
in where the tests come from, what they link against, and how a test passes. (ACT4 zkVMs without
a split pipeline in `src/run-isa-tests.sh` still run their tests inside Docker.)

### ISA tests (ACT4)

```mermaid
flowchart LR
    subgraph docker["Docker: zkvms/&lt;zkvm&gt;/act4.Dockerfile"]
        tests["riscv-arch-test<br/>at act4_commit"] --> act["act + Sail<br/>reference model"]
        cfg["zkvms/&lt;zkvm&gt;/isa-configs/<br/>ISA, link.ld, rvmodel_macros.h"] --> act
        act --> elfs["self-checking ELFs<br/>(patch_elfs.py where needed)"]
    end
    elfs --> native["native suite<br/>(full ISA, execute)"]
    elfs --> target["target suite<br/>(standard ISA)"]
    subgraph host["Host: runner (ISA backends)"]
        native --> emu["zkVM emulator"]
        target --> emu
        target --> prove["prove + verify<br/>(ACT4_MODE=full)"]
    end
    emu --> verdict{"exit 0?<br/>proof verifies?"}
    prove --> verdict
    verdict --> hist["results/history/&lt;zkvm&gt;-act4-{full,standard}.json"]
    hist --> dash["dashboard: Full ISA, Standard ISA columns"]
```

- The Sail reference model runs at compile time and embeds the expected values, so each ELF
  checks itself. At the end, it writes `PASS` or `FAIL` to public output 0 and exits 0 on pass
  and non-zero on fail.
- There are two ways to run these tests:
  - **ere path** (the default): OpenVM, SP1 and ZisK run on the official
    [eth-act/ere](https://github.com/eth-act/ere) images of the ere revision that
    `src/runner/Cargo.toml` pins. ere builds and runs the zkVM; there is no local zkVM build.
    It runs the Standard ISA suite (RV64IM_Zicclsm); the Full ISA suite then runs on the
    native path, execute only.
  - **native path** (`BACKEND=native`): builds each zkVM in this repository's containers from
    `config.json` and runs both suites. Use it to reproduce bugs and to test forks or branches.
    LambdaVM always runs here.
- In `ACT4_MODE=prove` or `full`, a target test must also prove, and in `full` also verify.
- `./run isa-tests <zkvm>` runs this pipeline. `FORCE=1` regenerates the ELFs.

### eth-act standards tests (guest interfaces)

```mermaid
flowchart LR
    subgraph image["Docker: zkvms/&lt;zkvm&gt;/standards/"]
        vendor["zkVM C library<br/>at the version eth-act/ere pins"]
        exe["zkVM executor<br/>(same version)"]
    end
    subgraph act["Docker: zkvms/&lt;zkvm&gt;/act4.Dockerfile"]
        src["tests/eth-act-standards/{io,accelerators,memory}/*.c<br/>+ zkvm_io.h, zkvm_accelerators.h<br/>(eth-act/zkevm-standards, pinned in config.json)"] --> build["act: ACT4 C tests<br/>(build-guests.sh)"]
        build --> elfs["guest ELFs<br/>+ .input / .expected / .outcome"]
    end
    vendor --> build
    elfs --> runner["Host: runner<br/>(ere, or the standards backends<br/>with BACKEND=native)"]
    exe --> runner
    runner --> verdict{"ACT4 verdict,<br/>output == .expected,<br/>or .outcome (fail [code])"}
    verdict --> hist["results/history/&lt;zkvm&gt;-eth-act-standards.json"]
    hist --> dash["dashboard: Execution, Prove, Verify columns"]
```

- Each test is a small C program that uses only the standard headers. ACT4 builds it as a C
  test, with the zkVM's ISA config, and links it against the zkVM's own static library, the way
  an EIP-8025 guest does.
- A self-checking program ends through the zkVM's ACT4 halt macros, which write `PASS` or
  `FAIL` to public output 0, so the runner reads its verdict as for an ISA test. A program that
  ends before `rvtest_pass()` writes no `PASS` and fails. An I/O write program must write its `.expected` public output. A
  program with the `.outcome` `fail` must terminate abnormally (the NULL-pointer tests). With
  `fail <code>`, the zkVM must also report that error code. A host error (for example, an executor usage or I/O error) never
  passes a test. The runner gives each program its `.input` file.
- The suite runs for ZisK, SP1 and OpenVM through ere by default: on the official ere image of
  the revision that `src/runner/Cargo.toml` pins, with execute, prove and verify
  (`ACT4_MODE`, default `full`; prove and full need an NVIDIA GPU). A test that expects an
  abnormal termination has no valid proof, so it is only executed. `BACKEND=native` runs the
  suite on the host executors instead, execute only. Each standards test image pins its own
  zkVM version (the version that ere pins), independent of `config.json`. See
  [`tests/eth-act-standards/README.md`](tests/eth-act-standards/README.md).
- `./run eth-act-standards-tests <zkvm>` runs this pipeline. `./run tests <zkvm>` runs both
  pipelines.

## Supported ZK-VMs

| ZK-VM | ISA | Repo | ere path |
|-------|-----|------|----------|
| SP1 | RV64IM | [succinctlabs/sp1](https://github.com/succinctlabs/sp1) | yes |
| OpenVM | RV64IM_Zicclsm | [openvm-org/openvm](https://github.com/openvm-org/openvm) | yes |
| ZisK | RV64IMFDAC_Zicclsm | [0xPolygonHermez/zisk](https://github.com/0xPolygonHermez/zisk) | yes |
| LambdaVM | RV64IM_Zicclsm | [yetanotherco/lambda_vm](https://github.com/yetanotherco/lambda_vm) | no |

## Usage

```bash
./run build sp1          # Build binary via Docker
./run isa-tests sp1                  # Run the ISA tests
./run eth-act-standards-tests sp1    # Run the eth-act standards tests (zisk, sp1, openvm)
./run tests sp1 openvm               # Run both suites for two zkVMs
./run tests                          # Run both suites for all zkVMs
./run all sp1                        # Build + both suites
./run elfs sp1                       # Generate the ISA test ELFs only
BACKEND=native ./run isa-tests sp1   # Build and run both ISA suites locally
./run serve                          # Dashboard at localhost:9586
./run clean              # Remove artifacts
```

### Environment variables

```bash
JOBS=8 ./run tests zisk                 # Limit CPU cores
ACT4_JOBS=N ./run isa-tests zisk        # Override parallel jobs inside container
FORCE=1 ./run isa-tests zisk            # Regenerate ISA test ELFs from scratch
ACT4_MODE=execute ./run isa-tests zisk  # Execution only (no proving); also: prove, full (default)
GPU=1 ./run build zisk              # Build with GPU support
GPU=1 ./run isa-tests zisk              # Prove with GPU
BACKEND=native ./run isa-tests zisk     # native path (ere is the default)
```

## Adding a ZK-VM

1. Add entry to `config.json`
2. Create `zkvms/<name>/build.Dockerfile`
3. Create `zkvms/<name>/act4.Dockerfile` + `entrypoint.sh`
4. Create `zkvms/<name>/isa-configs/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`
5. Optional: `zkvms/<name>/standards/` for the eth-act standards tests (see
   [`tests/eth-act-standards/README.md`](tests/eth-act-standards/README.md))

## Project layout

```
run                       Entry point
config.json               ZK-VM repo URLs and commit pins (zkVMs, ACT4, zkevm-standards)
src/                      Build and test scripts
src/runner/               Host-side test runner (Rust) for both suites, and the ere
                          backend with `--features ere`
src/shared/               Shared utilities (patch_elfs.py)
zkvms/<zkvm>/             Everything specific to one ZK-VM:
  build.Dockerfile          binary build
  act4.Dockerfile           ACT4 image (+ entrypoint.sh)
  isa-configs/<isa>/        ACT4 ISA/platform configs
  standards/                eth-act standards platform: C library, executor, link.ld
tests/eth-act-standards/  eth-act standards tests: C guests, headers, vector tools
site/                     Dashboard (GitHub Pages)
results/history/          Historical pass/fail tracking (read by the dashboard)
out/                      Local outputs, not tracked: bin/, <zkvm>/ ELFs and logs,
                          commits/, deps/
```

## Requirements

- Docker
- Bash, jq
- Rust (cargo), for the host-side test runner
- If GPU proving: an NVIDIA GPU (`ACT4_MODE=prove` or `full`)

## License

Dual-licensed under [Apache 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT).
