# zkevm-test-monitor

RISC-V ZK-VM compliance test monitor. Builds ZK-VM binaries, runs architectural compliance
tests, and serves a results dashboard.

## Key Directories

```
binaries/               # Built ZK-VM executables (e.g., airbender-binary)
riscof/                 # RISCOF test framework (Docker, current)
riscof/plugins/         # Per-ZKVM RISCOF plugins
riscv-arch-test/        # Symlink → /home/cody/riscv-arch-test (act4 branch)
zksync-airbender/       # Symlink → /home/cody/zksync-airbender (riscof-dev branch)
config.json             # ZKVM repo URLs and commit pins
src/build.sh            # Docker build logic
src/test.sh             # RISCOF test runner
test-results/           # Per-ZKVM test output and HTML reports
data/history/           # Historical pass/fail tracking
```

## Commands

```bash
./run build airbender               # Build airbender binary via Docker
./run test --arch airbender         # Run RISCOF arch tests for airbender
./run test --extra airbender        # Run extra tests
./run all --arch airbender          # Build + test + update dashboard
./run test --arch                   # Test all ZKVMs
./run test --arch --build-only      # Compile tests only (no execution)
./run update                        # Regenerate dashboard HTML
./run serve                         # Serve dashboard at localhost:8000
./run clean                         # Remove binaries/ and test-results/
```

Limit CPU cores: `JOBS=8 ./run test --arch airbender`

## Building Airbender Locally (Faster Iteration)

The airbender repo is symlinked at `zksync-airbender/` → `/home/cody/zksync-airbender`.
Branch: `riscof-dev` (adds RISCOF compliance test integration).

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
./run test --arch airbender
```
`src/test.sh` checks for `binaries/airbender-binary` before attempting a Docker build, so
the locally built binary is used directly.

### Full local workflow for quick iteration
```bash
# 1. Edit airbender source
# 2. Rebuild
cd zksync-airbender && cargo build --profile test-release -p cli && cd ..
# 3. Deploy
cp zksync-airbender/target/test-release/cli binaries/airbender-binary
# 4. Test
./run test --arch airbender
```

## Adding/Updating a ZKVM

1. Add entry to `config.json` with `repo_url`, `commit`, `binary_name`
2. Create `docker/build-<name>/Dockerfile` (copies binary to `/usr/local/bin/<binary_name>`)
3. Create `riscof/plugins/<name>/` with plugin Python file, ISA/platform YAML, env/
4. Build: `./run build <name>`
5. Test: `./run test --arch <name>`

## RISCOF Framework (Current)

- Runs as a Docker container built from `riscof/Dockerfile`
- Installs `riscof==1.25.3`, RISC-V toolchain, Sail reference model
- Test flow: compile `.S` → objcopy to binary → run DUT → compare signatures vs Sail
- Plugin path: `riscof/plugins/<name>/riscof_<name>.py`

## ACT4 Framework (Planned Migration)

The RISC-V arch tests have moved to ACT4 on the `act4` branch (currently checked out in
`riscv-arch-test/`). ACT4 uses self-checking ELFs instead of signature comparison.

See `ai_notes/act4-migration.md` for:
- Full comparison of RISCOF vs ACT4
- What config files ACT4 needs per DUT
- What Airbender CLI changes are required
- Proposed implementation path

## Airbender CLI Reference

```bash
# Run a flat binary
binaries/airbender-binary run --bin my.bin --cycles 100000

# Run for RISCOF (extracts begin_signature..end_signature from ELF)
binaries/airbender-binary run-for-riscof \
  --bin my.bin \
  --elf my.elf \
  --signatures my.sig \
  --cycles 100000
```

ISA: RV32IM only. Entry point: `0x0100_0000`.

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
