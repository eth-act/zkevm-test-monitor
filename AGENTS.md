# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
zkvms/<zkvm>/           # Per-ZKVM: build.Dockerfile, act4.Dockerfile + isa-tests-entrypoint.sh,
                        #   isa-configs/<isa>/ (ACT4 configs), standards/ (eth-act standards platform)
src/                    # Scripts: build.sh, run-isa-tests.sh, run-eth-act-standards-tests.sh
src/runner/             # Host-side test runner (Rust) for both suites
src/shared/             # Shared utilities (patch_elfs.py)
tests/eth-act-standards/ # eth-act standards tests: C guests for the I/O, accelerator and memory interfaces
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
./run eth-act-standards-tests zisk  # Run the eth-act standards tests (through ere; BACKEND=native: execute only)
./run tests                 # Run both suites for all ZKVMs
./run all sp1               # Build + both suites
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove out/bin/ and out/
```

Limit CPU cores: `JOBS=8 ./run tests zisk`

## ere path (default) and native path (`BACKEND=native`)

`./run isa-tests <openvm|sp1|zisk>` runs the Standard ISA suite (RV64IM_Zicclsm) on the
official `ghcr.io/eth-act/ere` images of the ere revision that `src/runner/Cargo.toml`
pins (`ere-dockerized`). ere builds and runs the zkVM. It then runs the Full ISA suite on
the native path, execute only (`./run build <zkvm>` first).

- Needs Docker; `ACT4_MODE=full` (default) or `prove` also needs an NVIDIA GPU.
  `ACT4_MODE=execute` runs on the CPU images.
- Results: `out/<zkvm>/ere/` (including `details-act4-*.json`, the outcome and
  error of each test) and `results/history/<zkvm>-ere-act4-standard.json`.
- The site reads the suites listed in `config.json` `zkvms.<name>.ere.suites` from the
  ere history files.
- `BACKEND=native ./run isa-tests <zkvm>` builds the zkVM in this repository's containers from
  `config.json` (`./run build <zkvm>` first), for reproducing bugs and testing forks or
  branches. Native results go to `results/history/<zkvm>-act4-*.json`. For zkVMs that run
  through ere, the site shows only the native Full ISA results.
  LambdaVM is native only.

## Adding a New ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `zkvms/<name>/build.Dockerfile` (builds and copies binary to `/usr/local/bin/<name>-binary`)
3. Create `zkvms/<name>/act4.Dockerfile` + `isa-tests-entrypoint.sh` (ACT4 ELF generation for the ISA tests)
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
