# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
binaries/               # Built ZK-VM executables (e.g., sp1-binary)
docker/<zkvm>/          # Per-ZKVM ACT4 test Docker setup (Dockerfile + entrypoint.sh)
docker/build-<zkvm>/    # Per-ZKVM binary build Dockerfiles
docker/shared/          # Shared utilities (patch_elfs.py)
eth-act-standards-tests/ # eth-act standards tests: C guests for the I/O, accelerator and memory interfaces
act4-configs/           # Per-ZKVM ACT4 ISA/platform configs
riscv-arch-test/        # Symlink → /home/cody/riscv-arch-test (act4 branch)
config.json             # ZKVM repo URLs and commit pins
src/build.sh            # Docker build logic
src/run-isa-tests.sh    # ISA test (ACT4) pipeline
src/run-eth-act-standards-tests.sh  # eth-act standards test pipeline
test-results/           # Per-ZKVM test output
data/history/           # Historical pass/fail tracking
```

## Commands

```bash
./run build sp1             # Build sp1 binary via Docker
./run isa-tests sp1         # Run the ISA tests (ACT4) for sp1
./run eth-act-standards-tests zisk  # Run the eth-act standards tests (execute only)
./run tests                 # Run both suites for all ZKVMs
./run all sp1               # Build + both suites
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove binaries/ and test-results/
```

Limit CPU cores: `JOBS=8 ./run tests zisk`

## Adding a New ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `docker/build-<name>/Dockerfile` (builds and copies binary to `/usr/local/bin/<name>-binary`)
3. Create `docker/<name>/Dockerfile` + `entrypoint.sh` (ACT4 test runner)
4. Create `act4-configs/<name>/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`
5. Build: `./run build <name>`
6. Test: `./run isa-tests <name>`

## ACT4 Framework

Tests are self-checking ELFs: Sail runs at compile time to embed expected values, and
tests exit 0 (pass) or non-zero (fail). No signature extraction needed.

- Test Docker images: `docker/<zkvm>/Dockerfile`
- DUT configs: `act4-configs/<zkvm>/<isa>/`
- Shared ELF patcher: `docker/shared/patch_elfs.py`

## config.json Structure

```json
{
  "zkvms": {
    "<name>": {
      "repo_url": "https://github.com/...",
      "commit": "<branch-or-hash>",
      "binary_name": "<name>-binary",
      ...
    }
  }
}
```

Current ZKVMs: `sp1`, `openvm`, `zisk`, `lambdavm`
