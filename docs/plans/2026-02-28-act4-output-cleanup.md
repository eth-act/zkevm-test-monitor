# ACT4 Output Cleanup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Redirect verbose ACT4 test output to a log file, rename result files to `results-act4-full-isa.json` / `results-act4-standard-isa.json`, remove the rvi20 experiment, and produce a clean summary.

**Architecture:** Each ZKVM's Docker entrypoint writes verbose output (make, compiler, test runner) unchanged — but `src/test.sh` redirects `docker run` stdout+stderr to `test-results/<zkvm>/act4.log`. After the container exits, `src/test.sh` reads the JSON files and prints the new-format summary. File names in both entrypoints and `src/update.py` are updated to match.

**Tech Stack:** Bash, Python 3, Docker, jq

---

## File Rename Map

| Old | New |
|-----|-----|
| `results-act4.json` | `results-act4-full-isa.json` |
| `summary-act4.json` | `summary-act4-full-isa.json` |
| `results-act4-target.json` | `results-act4-standard-isa.json` |
| `summary-act4-target.json` | `summary-act4-standard-isa.json` |

The internal suite keys in `update.py` data structures (`act4`, `act4-target`) are **not** renamed — only the on-disk file names change.

---

### Task 1: Rename output files in all 7 entrypoints

**Files to modify** (all have the same pattern):
- `docker/airbender/entrypoint.sh`
- `docker/jolt/entrypoint.sh`
- `docker/openvm/entrypoint.sh`
- `docker/pico/entrypoint.sh`
- `docker/r0vm/entrypoint.sh`
- `docker/sp1/entrypoint.sh`
- `docker/zisk/entrypoint.sh`

Each entrypoint has a `run_act4_suite` function with a `SUFFIX` parameter. The SUFFIX values `""` and `"-target"` are passed by the callers at the bottom and thread through to the output file names via `summary-act4${SUFFIX}.json` and `results-act4${SUFFIX}.json`. Do a direct string replacement in the function body.

**Step 1: In each entrypoint, replace both file name patterns**

Find (appears twice per file, once for summary, once for results):
```bash
"$RESULTS/summary-act4${SUFFIX}.json"
"$RESULTS/results-act4${SUFFIX}.json"
```

Replace with (map suffix to label):
```bash
"$RESULTS/summary-act4${SUFFIX:+${SUFFIX//-target/-standard-isa}}${SUFFIX:--full-isa}.json"
```

That's awkward. Instead, the cleanest approach is to add a `LABEL` variable derived from `SUFFIX` at the top of `run_act4_suite`, and use it in the file names:

```bash
run_act4_suite() {
    local CONFIG="$1"
    local CONFIG_NAME="$2"
    local EXTENSIONS="$3"
    local EXT_TXT="$4"
    local SUFFIX="$5"
    # Derive file label from suffix
    local FILE_LABEL
    if [ -z "$SUFFIX" ]; then
        FILE_LABEL="full-isa"
    else
        FILE_LABEL="standard-isa"
    fi
    # ... rest of function unchanged ...
    # Replace all: summary-act4${SUFFIX}.json → summary-act4-${FILE_LABEL}.json
    # Replace all: results-act4${SUFFIX}.json → results-act4-${FILE_LABEL}.json
```

Also update the inline Python inside `run_act4_suite` that writes the results file — it also hardcodes `results-act4${SUFFIX}.json`.

**Step 2: For `docker/zisk/entrypoint.sh` only — also remove the rvi20 suite call**

At the bottom of zisk's entrypoint, remove:
```bash
# ─── Run 3: RVI20 (rv64imafdc) ───
run_act4_suite \
    "config/zisk/zisk-rv64im-rvi20/test_config.yaml" \
    "zisk-rv64im-rvi20" \
    "..." \
    "..." \
    "-rvi20" || true
```

**Step 3: Commit**
```bash
git add docker/*/entrypoint.sh
git commit -m "chore: rename act4 result files to full-isa/standard-isa; drop zisk rvi20 suite"
```

---

### Task 2: Update `src/test.sh`

**Files:**
- Modify: `src/test.sh`

**Step 1: Redirect docker run to log file and remove `|| true`**

Current (lines 67–73):
```bash
echo "Running tests for $ZKVM..."
docker run --rm \
  ${CPUSET_ARG} \
  ${JOBS_ARG} \
  -v "$PWD/binaries/${ZKVM}-binary:/dut/${ZKVM}-binary" \
  -v "$PWD/act4-configs/${ZKVM}:/act4/config/${ZKVM}" \
  -v "$PWD/test-results/${ZKVM}:/results" \
  "${ZKVM}:latest" || true
```

Replace with:
```bash
LOG_FILE="test-results/${ZKVM}/act4.log"
echo "Running tests for $ZKVM... (log: $LOG_FILE)"
docker run --rm \
  ${CPUSET_ARG} \
  ${JOBS_ARG} \
  -v "$PWD/binaries/${ZKVM}-binary:/dut/${ZKVM}-binary" \
  -v "$PWD/act4-configs/${ZKVM}:/act4/config/${ZKVM}" \
  -v "$PWD/test-results/${ZKVM}:/results" \
  "${ZKVM}:latest" > "$LOG_FILE" 2>&1 || {
  echo "  ❌ Container failed for $ZKVM — check $LOG_FILE"
  continue
}
```

Note: `continue` skips to the next ZKVM in the `for` loop instead of silently proceeding with missing JSON.

**Step 2: Update the suffix loop to drop rvi20 and use new file names**

Current (line 81):
```bash
for ACT4_SUFFIX in "" "-target" "-rvi20"; do
  SUMMARY_FILE="test-results/${ZKVM}/summary-act4${ACT4_SUFFIX}.json"
  RESULTS_FILE="test-results/${ZKVM}/results-act4${ACT4_SUFFIX}.json"
  LABEL="ACT4${ACT4_SUFFIX:+ (${ACT4_SUFFIX#-})}"
```

Replace with:
```bash
for ACT4_SUFFIX in "" "-target"; do
  if [ -z "$ACT4_SUFFIX" ]; then
    FILE_LABEL="full-isa"
    SUITE_LABEL="full ISA"
    ISA="rv32im"
    SUITE="act4"
  else
    FILE_LABEL="standard-isa"
    SUITE_LABEL="standard ISA"
    ISA="rv64im_zicclsm"
    SUITE="act4-target"
  fi
  SUMMARY_FILE="test-results/${ZKVM}/summary-act4-${FILE_LABEL}.json"
  RESULTS_FILE="test-results/${ZKVM}/results-act4-${FILE_LABEL}.json"
```

**Step 3: Update the summary output block**

Current (lines 102–109):
```bash
PASSED=$(jq '.passed' "$SUMMARY_FILE")
...
if [ -f "$RESULTS_FILE" ]; then
  TEST_COUNT=$(jq '.tests | length' "$RESULTS_FILE")
  echo "  📋 ${LABEL} per-test results: ${TEST_COUNT} tests in results-act4${ACT4_SUFFIX}.json"
fi
echo "  ✅ ${LABEL} ${ZKVM}: ${PASSED}/${TOTAL} passed"
```

Replace with:
```bash
PASSED=$(jq '.passed' "$SUMMARY_FILE")
FAILED=$(jq '.failed' "$SUMMARY_FILE")
TOTAL=$(jq '.total' "$SUMMARY_FILE")

if [ -f "$RESULTS_FILE" ]; then
  TEST_COUNT=$(jq '.tests | length' "$RESULTS_FILE")
else
  TEST_COUNT="$TOTAL"
fi

if [ "$FAILED" -eq 0 ]; then
  STATUS_EMOJI="✅"
else
  STATUS_EMOJI="❌"
fi

echo "  📋 ACT4 ${ZKVM} (${SUITE_LABEL}): ${TEST_COUNT} tests in results-act4-${FILE_LABEL}.json"
echo "     ${STATUS_EMOJI} ${PASSED}/${TOTAL} passed"
```

**Step 4: Update the history write block**

The SUITE and ISA variables are now set in the loop header (Step 2). Remove the old `if [ "$ACT4_SUFFIX" = ... ]` ISA/SUITE assignment block (lines 87–93) since it's now handled above.

Also update the `HISTORY_FILE` reference — it uses `${ZKVM}-${SUITE}.json` which is still correct (history files keep their old names `act4` / `act4-target`, not renamed).

**Step 5: Commit**
```bash
git add src/test.sh
git commit -m "feat: redirect act4 docker output to log file; clean summary format"
```

---

### Task 3: Update `src/update.py`

**Files:**
- Modify: `src/update.py`

There are three places that read old file names:

**Step 1: Fix the summary file loop (line 310)**

Current:
```python
for suite in ['arch', 'extra', 'act4', 'act4-target']:
    summary_file = Path(f'test-results/{zkvm}/summary-{suite}.json')
```

`summary-act4.json` and `summary-act4-target.json` no longer exist — they are now `summary-act4-full-isa.json` and `summary-act4-standard-isa.json`. Update the mapping:

```python
suite_summary_files = {
    'arch': f'test-results/{zkvm}/summary-arch.json',
    'extra': f'test-results/{zkvm}/summary-extra.json',
    'act4': f'test-results/{zkvm}/summary-act4-full-isa.json',
    'act4-target': f'test-results/{zkvm}/summary-act4-standard-isa.json',
}
for suite, summary_path in suite_summary_files.items():
    summary_file = Path(summary_path)
```

(Keep the existing arch fallback logic that follows.)

**Step 2: Fix the per-test results loader (line 387)**

Current:
```python
for suffix, suite_key in [('', 'act4'), ('-target', 'act4-target')]:
    act4_results_file = Path(f'test-results/{zkvm}/results-act4{suffix}.json')
```

Replace with:
```python
for file_label, suite_key in [('full-isa', 'act4'), ('standard-isa', 'act4-target')]:
    act4_results_file = Path(f'test-results/{zkvm}/results-act4-{file_label}.json')
```

**Step 3: Commit**
```bash
git add src/update.py
git commit -m "chore: update update.py to read renamed act4 result files"
```

---

### Task 4: Delete rvi20 artifacts

**Step 1: Remove the rvi20 act4-config directory**
```bash
rm -rf act4-configs/zisk/zisk-rv64im-rvi20
```

**Step 2: Remove the rvi20 history file**
```bash
rm data/history/zisk-act4-rvi20.json
```

**Step 3: Remove stale test-results files** (these will be regenerated on next run, but clean up the old names)
```bash
rm -f test-results/zisk/results-act4-rvi20.json
rm -f test-results/zisk/summary-act4-rvi20.json
```

**Step 4: Commit**
```bash
git add -u act4-configs/ data/history/ test-results/zisk/
git commit -m "chore: remove zisk rvi20 experiment artifacts"
```

---

### Task 5: Rename existing test-results files on disk

The existing `test-results/*/results-act4.json` etc. are stale under the old names. Rename them so `./run update` works without needing a fresh test run.

**Step 1:**
```bash
for zkvm in airbender jolt openvm pico r0vm sp1 zisk; do
  dir="test-results/$zkvm"
  [ -f "$dir/results-act4.json" ]        && mv "$dir/results-act4.json"        "$dir/results-act4-full-isa.json"
  [ -f "$dir/summary-act4.json" ]        && mv "$dir/summary-act4.json"        "$dir/summary-act4-full-isa.json"
  [ -f "$dir/results-act4-target.json" ] && mv "$dir/results-act4-target.json" "$dir/results-act4-standard-isa.json"
  [ -f "$dir/summary-act4-target.json" ] && mv "$dir/summary-act4-target.json" "$dir/summary-act4-standard-isa.json"
done
```

**Step 2: Verify `./run update` runs without errors**
```bash
./run update
```
Expected: no Python FileNotFoundError, dashboard regenerates successfully.

**Step 3: Commit** (test-results/ is gitignored, so this is just a local state fix — no commit needed)

---

### Task 6: Smoke test

**Step 1: Run a single ZKVM test end-to-end**
```bash
./run test r0vm
```

Expected output (no verbose noise, only):
```
🔨 Building Docker image for r0vm...
Running tests for r0vm... (log: test-results/r0vm/act4.log)
  📋 ACT4 r0vm (full ISA): 47 tests in results-act4-full-isa.json
     ✅ 47/47 passed
  📋 ACT4 r0vm (standard ISA): 72 tests in results-act4-standard-isa.json
     ❌ 0/72 passed
```

Verbose log available at:
```bash
cat test-results/r0vm/act4.log
```

**Step 2: Verify new files exist**
```bash
ls test-results/r0vm/
# Should include: act4.log, results-act4-full-isa.json, summary-act4-full-isa.json,
#                 results-act4-standard-isa.json, summary-act4-standard-isa.json
```

**Step 3: Commit any final fixups**
