# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
zkvms/<zkvm>/           # Per-ZKVM: build.Dockerfile, act4.Dockerfile + entrypoint.sh,
                        #   isa-configs/<isa>/ (ACT4 configs)
src/                    # Scripts: build.sh, test.sh
src/act4-runner/        # Host-side ACT4 test runner (Rust)
src/shared/             # Shared utilities (patch_elfs.py)
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
./run all sp1               # Build + test
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove out/bin/ and out/
```

Limit CPU cores: `JOBS=8 ./run test zisk`

## ere path (default) and native path (`BACKEND=native`)

`./run test <openvm|sp1|zisk>` runs the ACT4 ELFs on the official
`ghcr.io/eth-act/ere` images of the ere revision that `src/act4-runner/Cargo.toml` pins
(`ere-dockerized`). ere builds and runs the zkVM; there is no local zkVM build.

- Needs Docker; `ACT4_MODE=full` (default) or `prove` also needs an NVIDIA GPU.
  `ACT4_MODE=execute` runs on the CPU images.
- Results: `out/<zkvm>/ere/` (including `details-act4-*.json`, the outcome and
  error of each test) and `results/history/<zkvm>-ere-act4-standard.json`.
- ere runs the Standard ISA suite (RV64IM_Zicclsm) only. The Full ISA suite runs on
  the native path.
- The site reads the suites listed in `config.json` `zkvms.<name>.ere.suites` from the
  ere history files.
- `BACKEND=native ./run test <zkvm>` builds the zkVM in this repository's containers from
  `config.json` (`./run build <zkvm>` first), for reproducing bugs and testing forks or
  branches. Native results go to `results/history/<zkvm>-act4-*.json`, which the site does not
  show for zkVMs that run through ere. LambdaVM is native only.

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
