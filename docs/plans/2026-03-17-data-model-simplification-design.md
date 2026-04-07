# Data Model Simplification Design

Date: 2026-03-17

## Goal

Separate data from rendering. Remove extra tests and old RISCOF tests. Make history
files the single source of truth with a client-side rendered frontend.

## Data Model

### History files (single source of truth)

Two files per ZKVM, append-only:
- `data/history/<zkvm>-act4-full.json` (renamed from `-act4`)
- `data/history/<zkvm>-act4-standard.json` (renamed from `-act4-target`)

Structure:
```json
{
  "zkvm": "sp1",
  "suite": "act4-full",
  "runs": [
    {
      "date": "2026-03-17",
      "commit": "abc123",
      "isa": "rv32im",
      "passed": 46,
      "failed": 1,
      "total": 47,
      "tests": [
        {"name": "I-ADD-01", "status": "pass"},
        {"name": "I-FENCE-01", "status": "fail"}
      ]
    }
  ]
}
```

For `act4-standard`, test entries also include `prove` and `verify` fields.

### Deleted data files
- `data/results.json` — redundant, frontend computes from history
- `data/commits/<zkvm>.txt` — commit stored in run entries
- `data/history/*-arch.json` — old RISCOF
- `data/history/*-extra.json` — extra tests

## Frontend

Two static HTML+JS files, no generation step:

- **`docs/index.html`** — Summary dashboard
  - Fetches `config.json` to discover ZKVMs
  - Fetches latest run from each history file
  - Summary table: ZKVM, ISA, commit, full/standard results, last run
  - Links to `zkvm.html?name=<zkvm>`

- **`docs/zkvm.html`** — Detail page (template)
  - Reads `?name=` query param
  - Shows latest run with per-test breakdown
  - Shows run history table

## Scripts

- **Delete `src/update.py`** — replaced by frontend JS
- **Delete `src/run_tests.py`** — legacy RISCOF runner
- **Modify `src/test.sh`** — append run entries directly to history files, stop calling update.py
- **Modify `src/build.sh`** — stop writing commit files
- **Modify `./run`** — remove `update` command

## Cleanup

Delete:
- Root HTML: `index.html`, `index-arch.html`, `index-extra.html`
- `docs/index-arch.html`, `docs/index-extra.html`, `docs/index-act4.html`
- `docs/act4/` directory
- `docs/zkvms/` directory
- `docs/reports/` directory
- `RESULTS_TRACKING.md`
