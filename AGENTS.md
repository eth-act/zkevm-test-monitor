# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
zkvms/<zkvm>/           # Per-ZKVM: build.Dockerfile, act4.Dockerfile + entrypoint.sh,
                        #   isa-configs/<isa>/ (ACT4 configs), standards/ (act-extra platform)
src/                    # Scripts: build.sh, test.sh
src/act4-runner/        # Host-side ACT4 test runner (Rust)
src/shared/             # Shared utilities (patch_elfs.py)
tests/extra/            # act-extra: C guests for the EIP-8025 I/O, accelerator and memory interfaces
site/                   # Dashboard (GitHub Pages)
results/history/        # Historical pass/fail tracking (tracked)
out/                    # Local outputs (not tracked): bin/ binaries, <zkvm>/ ELFs and logs, commits/
riscv-arch-test/        # Symlink → /home/cody/riscv-arch-test (pinned tag: config.json .act4_version)
config.json             # ZKVM repo URLs and commit pins
```

## Commands

```bash
./run build sp1             # Build sp1 binary via Docker
./run test sp1              # Run ACT4 compliance tests for sp1
./run test                  # Run ACT4 tests for all ZKVMs
./run extra zisk            # Run only the act-extra EIP-8025 interface suite (execute only)
./run all sp1               # Build + test
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove out/bin/ and out/
```

Limit CPU cores: `JOBS=8 ./run test zisk`

## Adding a New ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `zkvms/<name>/build.Dockerfile` (builds and copies binary to `/usr/local/bin/<name>-binary`)
3. Create `zkvms/<name>/act4.Dockerfile` + `entrypoint.sh` (ACT4 ELF generation)
4. Create `zkvms/<name>/isa-configs/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`
5. Build: `./run build <name>`
6. Test: `./run test <name>`

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
