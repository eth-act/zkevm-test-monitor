# zkevm-test-monitor

RISC-V compliance testing zkVMs using the the [ACT4](https://github.com/riscv-non-isa/riscv-arch-test/tree/act4) framework.

**Dashboard:** https://codygunton.github.io/zkevm-test-monitor/

Tests are self-checking ELFs: the Sail reference model runs at compile time to embed expected values, and tests exit 0 (pass) or non-zero (fail).

## Supported ZK-VMs

| ZK-VM | ISA | Repo |
|-------|-----|------|
| SP1 | RV64IM | [succinctlabs/sp1](https://github.com/succinctlabs/sp1) |
| Jolt | RV64IMAC | [a16z/jolt](https://github.com/a16z/jolt) |
| OpenVM | RV32IM | [openvm-org/openvm](https://github.com/openvm-org/openvm) |
| r0vm | RV32IM | [risc0/risc0](https://github.com/risc0/risc0) |
| Zisk | RV64IMFDAC | [0xPolygonHermez/zisk](https://github.com/0xPolygonHermez/zisk) |
| Pico | RV32IM | [brevis-network/pico](https://github.com/brevis-network/pico) |
| Airbender | RV32IM | [matter-labs/zksync-airbender](https://github.com/matter-labs/zksync-airbender) |

## Usage

```bash
./run build sp1          # Build binary via Docker
./run test sp1           # Run ACT4 tests
./run test sp1 jolt      # Test multiple
./run test               # Test all
./run all sp1            # Build + test
./run serve              # Dashboard at localhost:8000
./run clean              # Remove artifacts
```

### Environment variables

```bash
JOBS=8 ./run test zisk              # Limit CPU cores
ACT4_JOBS=N ./run test zisk         # Override parallel jobs inside container
FORCE=1 ./run test zisk             # Regenerate ELFs from scratch
ZISK_MODE=execute ./run test zisk   # Execution only (no proving); also: prove, full (default)
GPU=1 ./run build zisk              # Build with GPU support
GPU=1 ./run test zisk               # Prove with GPU
```

## Adding a ZK-VM

1. Add entry to `config.json`
2. Create `docker/build-<name>/Dockerfile`
3. Create `docker/<name>/Dockerfile` + `entrypoint.sh`
4. Create `act4-configs/<name>/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`

## Project layout

```
run                     Entry point
config.json             ZK-VM repo URLs and commit pins
src/                    Build and test scripts
docker/<zkvm>/          Per-ZK-VM ACT4 test Docker setup
docker/build-<zkvm>/    Per-ZK-VM binary build Dockerfiles
docker/shared/          Shared utilities (patch_elfs.py)
act4-configs/           Per-ZK-VM ACT4 ISA/platform configs
act4-runner/            Host-side test runner (Rust, used for proving)
docs/                   Dashboard (generated)
data/history/           Historical pass/fail tracking
scripts/                Utility scripts
notes/                  Reference documents and notes
```

## Requirements

- Docker
- Bash

## License

Dual-licensed under [Apache 2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT).
