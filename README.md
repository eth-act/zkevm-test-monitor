# ZKVM Test Monitor

A simplified, robust testing framework for Zero-Knowledge Virtual Machines (ZKVMs) using RISC-V compliance tests.

## Quick Start

```bash
# Build all ZKVMs
./run build all

# Test a specific ZKVM
./run test sp1

# View results
./run serve
# Open http://localhost:8000
```

## Overview

This repository provides automated RISC-V compliance testing for various ZKVM implementations using the [RISCOF](https://github.com/riscv-software-src/riscof/) framework. Tests are run differentially against the [Sail reference model](https://github.com/riscv/sail-riscv).

## Reproducing Results

Every test run is fully reproducible. Each ZKVM's history page shows:
- **Test Monitor Commit**: The exact version of this repository used
- **ZKVM Commit**: The specific ZKVM commit tested
- **ISA**: The instruction set tested (e.g., rv32im)
- **Results**: Pass/total ratio
- **Notes**: Optional notes about regressions, ISA changes, or other remarks

To reproduce any historical test result:
1. Check out the test monitor commit: `git checkout <test-monitor-commit>`
2. The ZKVM commit is automatically used from that version's `config.json`
3. Run: `./run test <zkvm>` to reproduce the exact test
4. View the dashboard at the specific commit on GitHub to see the original report

To add notes to history entries, edit `data/history/{zkvm}.json` and add a "notes" field to any run.

## Supported ZKVMs

- SP1
- Jolt
- OpenVM
- Risc0
- Zisk

Configuration for each ZKVM is in `config.json`.

## Commands

```bash
./run build [zkvm]   # Build ZKVM binaries (Docker-based)
./run test [zkvm]    # Run RISCOF compliance tests
./run update         # Regenerate dashboard HTML
./run all [zkvm]     # Build + test + update
./run verify         # Run integrity checks
./run serve          # Start local web server
./run clean          # Remove build artifacts
```

## Architecture

The system uses a minimal, robust architecture:

- `run` - Main entry point (bash)
- `config.json` - All ZKVM configurations
- `docker/build-*/` - Docker builds for each ZKVM
- `scripts/` - Core logic (build, test, update, verify)
- `data/results.json` - Test results (generated)
- `docs/index.html` - Static dashboard (generated)

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
3. **Test**: `./run test sp1` runs compliance tests
4. **View**: `./run serve` starts a web server with results

## Deployment

The dashboard automatically deploys to GitHub Pages when you push changes to the `docs/` folder:

```bash
# Test and update locally
./run test sp1
./run update

# Push to deploy
git add -A
git commit -m "Update test results"
git push
```

**GitHub Pages URL**: https://codygunton.github.io/zkevm-test-monitor/

**Setup** (first time only):
- Go to Settings → Pages → Source: GitHub Actions

## Requirements

- Docker
- Bash
- Python 3
- jq (for JSON processing)

## License

See LICENSE file.