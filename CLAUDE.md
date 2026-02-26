# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs ACT4 architectural
compliance tests, and serves a results dashboard.

## Key Directories

```
binaries/               # Built ZK-VM executables (e.g., airbender-binary)
docker/<zkvm>/          # Per-ZKVM ACT4 test Docker setup (Dockerfile + entrypoint.sh)
docker/build-<zkvm>/    # Per-ZKVM binary build Dockerfiles
docker/shared/          # Shared utilities (patch_elfs.py)
act4-configs/           # Per-ZKVM ACT4 ISA/platform configs
riscv-arch-test/        # Symlink → /home/cody/riscv-arch-test (act4 branch)
zksync-airbender/       # Symlink → /home/cody/zksync-airbender (riscof-dev branch)
config.json             # ZKVM repo URLs and commit pins
src/build.sh            # Docker build logic
src/test.sh             # ACT4 test runner
test-results/           # Per-ZKVM test output
data/history/           # Historical pass/fail tracking
```

## Commands

```bash
./run build airbender       # Build airbender binary via Docker
./run test airbender        # Run ACT4 compliance tests for airbender
./run test                  # Run ACT4 tests for all ZKVMs
./run all airbender         # Build + test + update dashboard
./run update                # Regenerate dashboard HTML
./run serve                 # Serve dashboard at localhost:8000
./run clean                 # Remove binaries/ and test-results/
```

Limit CPU cores: `JOBS=8 ./run test zisk`

## Building Airbender Locally (Faster Iteration)

The airbender repo is symlinked at `zksync-airbender/` → `/home/cody/zksync-airbender`.
Branch: `riscof-dev` (adds ACT4 compliance test support).

### Build
```bash
cd zksync-airbender
cargo build --profile test-release -p cli
```
- Output: `target/test-release/cli`
- Profile `test-release`: opt-level=2, no LTO, high parallelism — much faster than `--release`
- Requires nightly Rust (pinned in `rust-toolchain.toml`)

### Deploy to binaries/
```bash
cp zksync-airbender/target/test-release/cli binaries/airbender-binary
```

### Then run tests without rebuilding
```bash
./run test airbender
```

### Full local workflow for quick iteration
```bash
# 1. Edit airbender source
# 2. Rebuild
cd zksync-airbender && cargo build --profile test-release -p cli && cd ..
# 3. Deploy
cp zksync-airbender/target/test-release/cli binaries/airbender-binary
# 4. Test
./run test airbender
```

## Adding a New ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `docker/build-<name>/Dockerfile` (builds and copies binary to `/usr/local/bin/<name>-binary`)
3. Create `docker/<name>/Dockerfile` + `entrypoint.sh` (ACT4 test runner)
4. Create `act4-configs/<name>/<isa>/` with `test_config.yaml`, `sail.json`, `link.ld`, `rvmodel_macros.h`
5. Build: `./run build <name>`
6. Test: `./run test <name>`

## ACT4 Framework

Tests are self-checking ELFs: Sail runs at compile time to embed expected values, and
tests exit 0 (pass) or non-zero (fail). No signature extraction needed.

- Test Docker images: `docker/<zkvm>/Dockerfile`
- DUT configs: `act4-configs/<zkvm>/<isa>/`
- Shared ELF patcher: `docker/shared/patch_elfs.py`

## Airbender CLI Reference

```bash
# Run a flat binary through the transpiler VM
binaries/airbender-binary run-with-transpiler \
  --bin my.bin \
  --entry-point 0x1000000 \
  --tohost-addr 0x1010000 \
  --cycles 32000000
```

ISA: RV32IM only. Entry point: `0x0100_0000`, tohost: `0x0101_0000`.

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

Current ZKVMs: `sp1`, `jolt`, `openvm`, `r0vm`, `zisk`, `pico`, `airbender`
