# ZKVM Test Monitor

A simplified, robust testing framework for Zero-Knowledge Virtual Machines (ZKVMs) using RISC-V compliance tests.

## Quick Start

```bash
# Build all ZKVMs
./run build all

# Run architecture tests on a specific ZKVM
./run test --arch sp1

# Run extra tests on all ZKVMs
./run test --extra

# View results
./run serve
# Open http://localhost:8000
```

## Overview

This repository provides automated RISC-V compliance testing for various ZKVM implementations using the [RISCOF](https://github.com/riscv-software-src/riscof/) framework. Tests are run differentially against the [Sail reference model](https://github.com/riscv/sail-riscv).

Two test suites are available:
- **Architecture Tests**: Official [RISC-V Architecture Tests](https://github.com/riscv-non-isa/riscv-arch-test) v3.9.1
- **Extra Tests**: Additional tests to address gaps; useful also for experimentation

## Reproducing Results

Every test run is fully reproducible. Each ZKVM's history page shows:
- **ZKVM Commit**: The specific ZKVM commit tested
- **ISA**: The instruction set tested (e.g., rv32im)
- **Results**: Pass/total ratio
- **Notes**: Optional notes about regressions, ISA changes, or other remarks

To reproduce any historical test result:
1. Check out this repository at the desired point in history
2. The ZKVM commit is automatically used from that version's `config.json`
3. Run: `./run test --arch <zkvm>` or `./run test --extra <zkvm>` to reproduce the exact test
4. View the dashboard at the specific commit on GitHub to see the original report

To add notes to history entries, edit `data/history/{zkvm}-{suite}.json` and add a "notes" field to any run.

## Supported ZKVMs

Currently testing:
- **SP1** - Succinct Labs' zkVM
- **Jolt** - a16z's lookup-based zkVM
- **OpenVM** - Modular zkVM framework
- **Risc0** - RISC Zero's zkVM
- **Zisk** - Polygon's zkVM (RV64IMA)

Additional ZKVMs with limited support:
- **Airbender** - zkSync's zkVM
- **Pico** - Experimental zkVM

Configuration for each ZKVM is in `config.json`.

## Test Suites

### Architecture Tests (`--arch`)
Official RISC-V compliance tests from [riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) v3.9.1. These tests verify basic ISA compliance for instructions like ADD, SUB, etc.

### Extra Tests (`--extra`)
Custom tests located in `extra-tests/` for:
- Edge cases not covered by standard tests
- Specific bug reproductions
- Differential testing scenarios
- Trap and exception handling

## Commands

```bash
./run build [zkvm]                # Build ZKVM binaries (Docker-based)
./run test --arch [zkvm]          # Run architecture compliance tests
./run test --extra [zkvm]         # Run extra differential tests
./run update                      # Regenerate dashboard HTML
./run all --arch [zkvm]           # Build + test (arch) + update
./run all --extra [zkvm]          # Build + test (extra) + update
./run serve                       # Start local web server
./run clean                       # Remove build artifacts
```

## Architecture

The system uses a minimal, robust architecture:

- `run` - Main entry point (bash)
- `config.json` - All ZKVM configurations
- `src/` - Core logic (build, test, update scripts)
- `docker/build-*/` - Docker builds for each ZKVM
- `riscof/` - RISCOF framework and plugins
- `extra-tests/` - Custom test suite for edge cases
- `data/` - Test results and history (generated)
- `docs/` - Static dashboard HTML (generated)

## RISCOF Integration

The test system uses the integrated RISCOF framework:

1. **Built-in Setup**: RISCOF is included as part of this repository:
   - Build the RISCOF Docker image on first run
   - Use plugins from `riscof/plugins/` for each ZKVM

2. **Local Development**: RISCOF is located at `./riscof/` in this repository:
   - Modify plugins directly in `riscof/plugins/[zkvm-name]/`
   - Update the Docker environment in `riscof/Dockerfile`
   - No external dependencies or configuration needed

3. **Plugin Structure**: RISCOF plugins for each ZKVM are located at:
   ```
   riscof/plugins/
   ├── sp1/
   │   ├── riscof_sp1.py
   │   ├── sp1_isa.yaml
   │   ├── sp1_platform.yaml
   │   └── env/link.ld
   ├── jolt/
   │   └── (same structure)
   └── ...
   ```

See the [RISCOF plugin documentation](https://riscof.readthedocs.io/) for details.

## Development Workflow

1. **Configure**: Edit `config.json` to set ZKVM repositories and commits
2. **Build**: `./run build sp1` builds the SP1 binary
3. **Test**: `./run test --arch sp1` runs architecture compliance tests
4. **Test Extra**: `./run test --extra sp1` runs custom edge case tests
5. **View**: `./run serve` starts a web server with results

## Deployment

The dashboard automatically deploys to GitHub Pages when you push changes to the `docs/` folder:

```bash
# Test and update locally
./run test --arch sp1
./run update

# Push to deploy
git add -A
git commit -m "Update test results"
git push
```

**GitHub Pages URL**: https://codygunton.github.io/zkevm-test-monitor/

**Setup** (first time only):
- Go to Settings → Pages → Source: GitHub Actions

## Nightly CI Updates

Some ZKVMs (Jolt, Zisk) have automated nightly updates via GitHub Actions:
- Runs daily to check for new commits
- Automatically builds and tests the latest version
- Updates the dashboard with results
- Creates issues on failures

See `.github/workflows/nightly-*.yml` for configurations.

## Requirements

- Docker
- Bash
- Python 3
- jq (for JSON processing)

## License

See LICENSE file.
