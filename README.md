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

The test system automatically handles the RISCOF framework:

1. **Automatic Setup**: On first run, the test script will:
   - Clone the RISCOF repository (configured in `config.json`)
   - Build the RISCOF Docker image
   - Use plugins from `riscof/plugins/` for each ZKVM

2. **Local Development**: To use your own RISCOF fork:
   ```bash
   # Option 1: Update config.json with your repo
   # Edit config.json -> riscof.repo_url and riscof.commit
   
   # Option 2: Use existing local clone
   rm -rf riscof  # Remove auto-cloned version
   ln -s /path/to/your/riscof/repo riscof
   ```

3. **Plugin Structure**: RISCOF plugins for each ZKVM should be at:
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