# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
zkvms/<zkvm>/           # Per-ZKVM: build.Dockerfile, act4.Dockerfile + entrypoint.sh,
                        #   isa-configs/<isa>/ (ACT4 configs), standards/ (eth-act standards platform)
src/                    # Scripts: build.sh, run-isa-tests.sh, run-eth-act-standards-tests.sh
src/runner/             # Host-side test runner (Rust) for both suites
src/shared/             # Shared utilities (patch_elfs.py)
tests/eth-act-standards/ # eth-act standards tests: C guests for the I/O, accelerator and memory interfaces and termination semantics
site/                   # Dashboard (GitHub Pages)
results/history/        # Historical pass/fail tracking (tracked)
out/                    # Local outputs (not tracked): bin/ binaries, <zkvm>/ ELFs and logs, commits/, deps/
riscv-arch-test/        # Symlink → /home/cody/riscv-arch-test (pinned tag: config.json .act4_version)
config.json             # ZKVM repo URLs and commit pins
```

## Commands

```bash
./run build sp1             # Build sp1 binary via Docker
./run isa-tests sp1         # Run the ISA tests (ACT4) for sp1
./run eth-act-standards-tests zisk  # Run the eth-act standards tests (execute only)
./run tests                 # Run both suites for all ZKVMs
./run all sp1               # Build + both suites
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove out/bin/ and out/
```

Limit CPU cores: `JOBS=8 ./run tests zisk`

## Adding a New ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `zkvms/<name>/build.Dockerfile` (builds and copies binary to `/usr/local/bin/<name>-binary`)
3. Create `zkvms/<name>/act4.Dockerfile` + `entrypoint.sh` (ACT4 ELF generation)
4. Create `zkvms/<name>/isa-configs/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`
5. Build: `./run build <name>`
6. Test: `./run isa-tests <name>`

## ACT4 Framework

Tests are self-checking ELFs: Sail runs at compile time to embed expected values, and
tests exit 0 (pass) or non-zero (fail). No signature extraction needed.

- Test Docker images: `zkvms/<zkvm>/act4.Dockerfile`
- DUT configs: `zkvms/<zkvm>/isa-configs/<isa>/`
- Shared ELF patcher: `src/shared/patch_elfs.py`

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
