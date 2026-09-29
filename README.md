# zkevm-test-monitor

RISC-V compliance testing zkVMs using the [ACT4](https://github.com/riscv/riscv-arch-test) framework (release [4.1.0](https://github.com/riscv/riscv-arch-test/releases/tag/4.1.0)).

**Dashboard:** https://eth-act.github.io/zkevm-test-monitor/

Tests are self-checking ELFs: the Sail reference model runs at compile time to embed expected values. At the end, each test writes `PASS` or `FAIL` to public output 0 and exits 0 (pass) or non-zero (fail).

There are two ways to run the tests:

- **ere path** (`BACKEND=ere`): OpenVM, SP1 and ZisK run on the official [eth-act/ere](https://github.com/eth-act/ere) images of the ere revision that `src/act4-runner/Cargo.toml` pins. ere builds and runs the zkVM; there is no local zkVM build. It runs the Standard ISA suite (RV64IM_Zicclsm) only.
- **native path** (`BACKEND=native`, the default): builds each zkVM in this repository's containers from `config.json` and runs both suites. Use it to reproduce bugs and to test forks or branches.

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
./run test sp1           # Run ACT4 tests
./run test sp1 zisk      # Test multiple
./run test               # Test all
./run all sp1            # Build + test
./run elfs sp1           # Generate the test ELFs only
BACKEND=ere ./run test sp1   # Run the Standard ISA suite through ere
./run serve              # Dashboard at localhost:9586
./run clean              # Remove artifacts
```

### Environment variables

```bash
JOBS=8 ./run test zisk              # Limit CPU cores
ACT4_JOBS=N ./run test zisk         # Override parallel jobs inside container
FORCE=1 ./run test zisk             # Regenerate ELFs from scratch
ACT4_MODE=execute ./run test zisk   # Execution only (no proving); also: prove, full (default)
GPU=1 ./run build zisk              # Build with GPU support
GPU=1 ./run test zisk               # Prove with GPU
BACKEND=ere ./run test zisk         # ere path (native is the default)
```

## Adding a ZK-VM

1. Add entry to `config.json`
2. Create `zkvms/<name>/build.Dockerfile`
3. Create `zkvms/<name>/act4.Dockerfile` + `entrypoint.sh`
4. Create `zkvms/<name>/isa-configs/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`

## Project layout

```
run                       Entry point
config.json               ZK-VM repo URLs and commit pins (zkVMs, ACT4)
src/                      Build and test scripts
src/act4-runner/          Host-side test runner (Rust): the zkVM CLIs, and the ere
                          backend with `--features ere`
src/shared/               Shared utilities (patch_elfs.py)
zkvms/<zkvm>/             Everything specific to one ZK-VM:
  build.Dockerfile          binary build
  act4.Dockerfile           ACT4 image (+ entrypoint.sh)
  isa-configs/<isa>/        ACT4 ISA/platform configs
site/                     Dashboard (GitHub Pages)
results/history/          Historical pass/fail tracking (read by the dashboard)
out/                      Local outputs, not tracked: bin/, <zkvm>/ ELFs and logs,
                          commits/
```

## Requirements

- Docker
- Bash, jq
- Rust (cargo), for the host-side test runner
- An NVIDIA GPU for proving (`ACT4_MODE=prove` or `full`)

## License

Dual-licensed under [Apache 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT).
