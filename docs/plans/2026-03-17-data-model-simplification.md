# Data Model Simplification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the generate-static-HTML pipeline with append-only JSON history files and a client-side rendered dashboard.

**Architecture:** Tests append run entries (with per-test details) directly to history JSON files. Two static HTML pages (`index.html` and `zkvm.html`) fetch these JSON files at load time and render everything client-side. No generation step.

**Tech Stack:** Vanilla HTML/CSS/JS (no build tools), jq in bash for JSON manipulation.

---

### Task 1: Delete legacy data files

Remove RISCOF/extra history files and the redundant aggregated results file.

**Files:**
- Delete: `data/results.json`
- Delete: `data/history/airbender-arch.json`
- Delete: `data/history/airbender-extra.json`
- Delete: `data/history/jolt-arch.json`
- Delete: `data/history/jolt-extra.json`
- Delete: `data/history/openvm-arch.json`
- Delete: `data/history/openvm-extra.json`
- Delete: `data/history/pico-arch.json`
- Delete: `data/history/pico-extra.json`
- Delete: `data/history/r0vm-arch.json`
- Delete: `data/history/r0vm-extra.json`
- Delete: `data/history/sp1-arch.json`
- Delete: `data/history/sp1-extra.json`
- Delete: `data/history/zisk-arch.json`
- Delete: `data/history/zisk-extra.json`
- Delete: `data/commits/` (entire directory)

**Step 1: Delete files**

```bash
rm -f data/results.json
rm -f data/history/*-arch.json data/history/*-extra.json
rm -rf data/commits
```

**Step 2: Rename act4 → act4-full, act4-target → act4-standard**

```bash
cd data/history
for f in *-act4.json; do
  zkvm="${f%-act4.json}"
  mv "$f" "${zkvm}-act4-full.json"
done
for f in *-act4-target.json; do
  zkvm="${f%-act4-target.json}"
  mv "$f" "${zkvm}-act4-standard.json"
done
```

**Step 3: Update suite labels inside the renamed files**

```bash
cd data/history
for f in *-act4-full.json; do
  jq '.suite = "act4-full"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
for f in *-act4-standard.json; do
  jq '.suite = "act4-standard"' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
```

**Step 4: Verify**

```bash
ls data/history/
# Should show exactly 14 files: 7 *-act4-full.json + 7 *-act4-standard.json
ls data/commits 2>/dev/null
# Should fail: No such file or directory
```

**Step 5: Commit**

```bash
git add -A data/
git commit -m "chore: remove legacy data files, rename act4 suites"
```

---

### Task 2: Add per-test details to history file run entries

Currently `process_results()` in `test.sh` only stores aggregate counts. Update it to
embed the full per-test array from the results JSON into each run entry.

**Files:**
- Modify: `src/test.sh` (the `process_results` function, lines 31-116)

**Step 1: Rewrite process_results function**

Replace the entire `process_results()` function in `src/test.sh` with:

```bash
# process_results <zkvm> — reads summary/results JSON and updates history
process_results() {
  local ZKVM="$1"

  mkdir -p data/history
  TEST_MONITOR_COMMIT=$(git rev-parse HEAD 2>/dev/null | head -c 8 || echo "unknown")
  RUN_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Resolve commit: check Docker image first, then config.json
  ZKVM_COMMIT=$(docker run --rm --entrypoint cat "zkvm-${ZKVM}:latest" /commit.txt 2>/dev/null || \
    jq -r ".zkvms.${ZKVM}.commit // \"unknown\"" config.json 2>/dev/null || echo "unknown")

  for SUITE_TYPE in full standard; do
    if [ "$SUITE_TYPE" = "full" ]; then
      FILE_LABEL="full-isa"
      SUITE="act4-full"
    else
      FILE_LABEL="standard-isa"
      SUITE="act4-standard"
    fi

    SUMMARY_FILE="test-results/${ZKVM}/summary-act4-${FILE_LABEL}.json"
    RESULTS_FILE="test-results/${ZKVM}/results-act4-${FILE_LABEL}.json"

    if [ ! -f "$SUMMARY_FILE" ]; then
      if [ "$SUITE_TYPE" = "full" ]; then
        echo "  Warning: No summary generated for $ZKVM (container may have failed)"
      fi
      continue
    fi

    PASSED=$(jq '.passed' "$SUMMARY_FILE")
    FAILED=$(jq '.failed' "$SUMMARY_FILE")
    TOTAL=$(jq '.total' "$SUMMARY_FILE")

    # Build per-test array (empty array if results file missing)
    if [ -f "$RESULTS_FILE" ]; then
      TESTS_JSON=$(jq '.tests' "$RESULTS_FILE")
    else
      TESTS_JSON="[]"
    fi

    if [ "$FAILED" -eq 0 ]; then
      STATUS_EMOJI="+"
    else
      STATUS_EMOJI="x"
    fi

    echo "  ACT4 ${ZKVM} (${SUITE}): ${TOTAL} tests"
    echo "     ${STATUS_EMOJI} ${PASSED}/${TOTAL} passed"

    HISTORY_FILE="data/history/${ZKVM}-${SUITE}.json"

    # Build run entry as JSON
    RUN_ENTRY=$(jq -n \
      --arg date "$RUN_DATE" \
      --arg commit "$ZKVM_COMMIT" \
      --arg isa "$(jq -r ".zkvms.${ZKVM}.isa // \"unknown\"" config.json)" \
      --argjson passed "$PASSED" \
      --argjson failed "$FAILED" \
      --argjson total "$TOTAL" \
      --argjson tests "$TESTS_JSON" \
      '{date: $date, commit: $commit, isa: $isa, passed: $passed, failed: $failed, total: $total, tests: $tests}')

    if [ -f "$HISTORY_FILE" ]; then
      jq --argjson run "$RUN_ENTRY" '.runs += [$run]' \
        "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    else
      jq -n --arg zkvm "$ZKVM" --arg suite "$SUITE" --argjson run "$RUN_ENTRY" \
        '{zkvm: $zkvm, suite: $suite, runs: [$run]}' > "$HISTORY_FILE"
    fi
  done
}
```

Key changes from current:
- Suite names are now `act4-full` and `act4-standard` (not `act4` / `act4-target`)
- Per-test array from `results-*.json` is embedded in each run entry
- Commit resolved from Docker image (no more `data/commits/` dependency)
- Date is ISO 8601 with time (not just YYYY-MM-DD)
- Removed `test_monitor_commit`, `notes` fields (not used by frontend)

**Step 2: Update zisk split pipeline suite labels**

In `src/test.sh`, the `run_zisk_split_pipeline` function passes `--suite act4` and `--suite act4-target` to the act4-runner. Update these:

- Line 237: change `--suite act4` to `--suite act4-full`
- Line 262: change `--suite act4-target` to `--suite act4-standard`

Also update the `--label` args to match:
- Line 238: keep `--label full-isa` (unchanged)
- Line 263: keep `--label standard-isa` (unchanged)

**Step 3: Verify test.sh syntax**

```bash
bash -n src/test.sh
# Expected: no output (valid syntax)
```

**Step 4: Commit**

```bash
git add src/test.sh
git commit -m "feat: embed per-test details in history files, rename suites"
```

---

### Task 3: Remove build.sh commit file writing

**Files:**
- Modify: `src/build.sh` (lines 77-80)

**Step 1: Remove commit file writing**

In `src/build.sh`, remove these lines (77-80):

```bash
  # Capture actual commit hash from the built image
  mkdir -p data/commits
  ACTUAL_COMMIT=$(docker run --rm --entrypoint cat zkvm-${ZKVM}:latest /commit.txt 2> /dev/null || echo "$COMMIT")
  echo "$ACTUAL_COMMIT" > "data/commits/${ZKVM}.txt"
  echo "  📝 Built from commit: ${ACTUAL_COMMIT:0:8}"
```

Replace with just a log line:

```bash
  ACTUAL_COMMIT=$(docker run --rm --entrypoint cat zkvm-${ZKVM}:latest /commit.txt 2>/dev/null || echo "$COMMIT")
  echo "  Built from commit: ${ACTUAL_COMMIT:0:8}"
```

**Step 2: Commit**

```bash
git add src/build.sh
git commit -m "chore: stop writing commit files from build.sh"
```

---

### Task 4: Delete generated HTML and legacy scripts

**Files:**
- Delete: `src/update.py`
- Delete: `src/run_tests.py`
- Delete: `index.html` (root)
- Delete: `index-arch.html` (root)
- Delete: `index-extra.html` (root)
- Delete: `docs/index.html`
- Delete: `docs/index-act4.html`
- Delete: `docs/index-arch.html`
- Delete: `docs/index-extra.html`
- Delete: `docs/act4/` (entire directory, 14 files)
- Delete: `docs/zkvms/` (entire directory, 7 files)
- Delete: `docs/reports/` (entire directory, 15 files)
- Delete: `RESULTS_TRACKING.md`

**Step 1: Delete files**

```bash
rm -f src/update.py src/run_tests.py
rm -f index.html index-arch.html index-extra.html
rm -f docs/index.html docs/index-act4.html docs/index-arch.html docs/index-extra.html
rm -rf docs/act4 docs/zkvms docs/reports
rm -f RESULTS_TRACKING.md
```

**Step 2: Verify docs/ is clean**

```bash
ls docs/
# Should show only: NIGHTLY_UPDATES.md  plans
```

**Step 3: Commit**

```bash
git add -A
git commit -m "chore: delete generated HTML, legacy scripts, and results tracking"
```

---

### Task 5: Update ./run script

Remove the `update` command and the `uv run` calls to `update.py`.

**Files:**
- Modify: `run` (lines 19, 24-25, 32, 76-80)

**Step 1: Edit run script**

Remove `uv run --with pyyaml src/update.py` from `test)` and `all)` cases. Remove the `update)` case entirely. Update help text.

New `run` file contents:

```bash
#!/bin/bash
# run - Main entry point for ZKVM testing

set -e

CMD=${1:-help}
shift || true

case "$CMD" in
    build)
        echo "Building ZKVMs: ${@:-all}"
        ./src/build.sh "$@"
        ;;

    test)
        DISPLAY_TARGETS="${@:-all}"
        echo "Testing ZKVMs: ${DISPLAY_TARGETS}"
        ./src/test.sh "$@"
        ;;

    all)
        DISPLAY_TARGETS="${@:-all}"
        echo "Building and testing: ${DISPLAY_TARGETS}"
        ./src/build.sh "$@"
        ./src/test.sh "$@"
        ;;

    serve)
        echo "Server at http://localhost:8000/"
        echo "   Press Ctrl+C to stop"
        cd docs && python3 -m http.server 8000 --bind 127.0.0.1
        ;;

    clean)
        TARGETS="${@:-all}"
        if [ "$TARGETS" = "all" ]; then
            echo "Cleaning all artifacts"
            ZKVMS=""
            for dir in test-results/*/; do
                [ -d "$dir" ] && ZKVMS="$ZKVMS $(basename "$dir")"
            done
        else
            echo "Cleaning artifacts for: $TARGETS"
            ZKVMS="$TARGETS"
        fi
        for zkvm in $ZKVMS; do
            if [ -d "test-results/$zkvm/elfs" ]; then
                docker run --rm -v "$PWD/test-results/$zkvm/elfs:/elfs" ubuntu:24.04 rm -rf /elfs/native /elfs/target 2>/dev/null || true
            fi
            rm -rf "test-results/$zkvm"
            rm -f "binaries/${zkvm}-binary"
            if [ "$zkvm" = "zisk" ]; then
                rm -f binaries/cargo-zisk binaries/cargo-zisk-cuda binaries/libzisk_witness.so
                rm -rf binaries/zisk-lib
            fi
        done
        if [ "$TARGETS" = "all" ]; then
            rm -f act4-runner/target/release/act4-runner
        fi
        ;;

    *)
        cat << EOF
Usage: ./run COMMAND [OPTIONS]

Commands:
  build [zkvm ...]          Build ZKVM binaries
  test [zkvm ...]           Run ACT4 compliance tests
  all [zkvm ...]            Build + test
  serve                     Start local web server at localhost:8000
  clean [zkvm ...]          Remove build artifacts (all or specific ZKVMs)

Environment Variables:
  JOBS=N                    Limit to N CPU cores
  ACT4_JOBS=N               Override parallel test jobs inside container
  FORCE=1                   Force regeneration of ELFs / rebuild of binaries
  ZISK_MODE=execute|prove|full   Zisk test mode (default: full)
  ZISK_GPU=1                    Build/use GPU variants for Zisk proving

Examples:
  ./run build sp1
  ./run test sp1 jolt
  ./run test                          # test all ZKVMs
  ./run all
  JOBS=8 ./run test zisk
  ZISK_MODE=execute ./run test zisk   # zisk emulation only (no proving)
  ZISK_GPU=1 ./run build zisk         # build with GPU support
  ZISK_GPU=1 ./run test zisk          # use GPU for proving
  FORCE=1 ./run test zisk             # regenerate ELFs from scratch
EOF
        ;;
esac
```

**Step 2: Verify syntax**

```bash
bash -n run
```

**Step 3: Commit**

```bash
git add run
git commit -m "chore: remove update command and update.py calls from run script"
```

---

### Task 6: Build the summary dashboard (docs/index.html)

A single static HTML file with embedded JS that fetches config.json and history files,
then renders a summary table.

**Files:**
- Create: `docs/index.html`

**Step 1: Write docs/index.html**

The page should:
1. Fetch `../config.json` to get the list of ZKVMs and their `repo_url` + `isa`
2. For each ZKVM, fetch `../data/history/<zkvm>-act4-full.json` and `../data/history/<zkvm>-act4-standard.json`
3. Read the last entry from each `.runs` array
4. Render a table matching the current layout:
   - Columns: ZKVM | Commit | Full ISA (ISA, Execution) | Standard ISA (Execution, Prove, Verify) | Last Run
   - ZKVM name links to `zkvm.html?name=<zkvm>`
   - Commit links to `<repo_url>/commit/<commit>`
   - Results show `passed/total` with green (all pass) or red (any fail) styling
   - Prove/Verify columns show counts from per-test data if available, dash otherwise
5. Keep the same visual style (clean monospace, light background, white card)

The file will be around 200-300 lines of HTML/CSS/JS. Reuse the existing CSS from the
current `docs/index.html` (the styles in lines 6-125). The JS replaces what `update.py`
was doing server-side.

Key JS logic:
```javascript
async function loadDashboard() {
  const config = await fetch('../config.json').then(r => r.json());
  const zkvms = Object.keys(config.zkvms).sort();

  const rows = await Promise.all(zkvms.map(async (name) => {
    const fullHistory = await fetch(`../data/history/${name}-act4-full.json`).then(r => r.json()).catch(() => null);
    const stdHistory = await fetch(`../data/history/${name}-act4-standard.json`).then(r => r.json()).catch(() => null);
    const fullRun = fullHistory?.runs?.at(-1);
    const stdRun = stdHistory?.runs?.at(-1);
    return { name, config: config.zkvms[name], fullRun, stdRun };
  }));

  // Render table from rows...
}
```

For prove/verify counts from standard ISA per-test data:
```javascript
function countProveVerify(tests) {
  if (!tests) return { prove: null, verify: null };
  const proved = tests.filter(t => t.prove_status === 'success').length;
  const verified = tests.filter(t => t.verify_status === 'success').length;
  const total = tests.length;
  return { prove: `${proved}/${total}`, verify: `${verified}/${total}` };
}
```

**Step 2: Test locally**

```bash
./run serve
# Open http://localhost:8000/ — should show the summary table with data from history files
```

**Step 3: Commit**

```bash
git add docs/index.html
git commit -m "feat: client-side rendered summary dashboard"
```

---

### Task 7: Build the detail page (docs/zkvm.html)

A single template page that reads `?name=<zkvm>` and renders detail + history.

**Files:**
- Create: `docs/zkvm.html`

**Step 1: Write docs/zkvm.html**

The page should:
1. Read `name` from URL query params
2. Fetch `../config.json` for repo_url and ISA
3. Fetch both history files for that ZKVM
4. Render two sections:

**Latest Run section** (for each suite: act4-full, act4-standard):
- Header with suite name, date, commit
- Per-test table: Test Name | Extension | Status | (Prove | Verify for standard only)
- Status: green checkmark for pass, red X for fail
- Prove/verify: success/fail/skip badges

**History section:**
- Table of all runs (newest first): Date | Commit | Passed | Failed | Total
- One table per suite

Same visual style as index.html.

Key JS:
```javascript
const params = new URLSearchParams(window.location.search);
const name = params.get('name');
if (!name) { document.body.innerHTML = '<p>Missing ?name= parameter</p>'; return; }
document.title = `${name.toUpperCase()} - ZKVM Test Monitor`;
```

**Step 2: Test locally**

```bash
./run serve
# Open http://localhost:8000/zkvm.html?name=sp1
# Should show SP1 detail page with per-test results and history
```

**Step 3: Commit**

```bash
git add docs/zkvm.html
git commit -m "feat: client-side rendered ZKVM detail page"
```

---

### Task 8: Update CLAUDE.md and HACK_TRACKING.md

Update project documentation to reflect the new data model.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `HACK_TRACKING.md` (if it references old files)

**Step 1: Update CLAUDE.md**

Key changes:
- Remove `./run update` from Commands section
- Update Key Directories: remove references to `data/results.json`, `data/commits/`
- Update dashboard description: "static HTML+JS that fetches JSON at load time"
- Remove "update" from `./run all` description (now just "Build + test")

**Step 2: Commit**

```bash
git add CLAUDE.md HACK_TRACKING.md
git commit -m "docs: update project docs for new data model"
```

---

### Task 9: Final verification

**Step 1: Verify serve works end-to-end**

```bash
./run serve
# Check: http://localhost:8000/ — summary table loads from JSON
# Check: http://localhost:8000/zkvm.html?name=zisk — detail page loads
# Check: http://localhost:8000/zkvm.html?name=sp1 — another ZKVM
# Check: clicking ZKVM names navigates correctly
# Check: commit links go to correct GitHub URLs
```

**Step 2: Verify test pipeline still works (dry run)**

```bash
# Check test.sh syntax
bash -n src/test.sh

# Check run script syntax
bash -n run

# Verify history files are valid JSON
for f in data/history/*.json; do jq empty "$f" && echo "OK: $f"; done
```

**Step 3: Verify no stale references**

```bash
# Check for references to deleted files
grep -r "update.py\|run_tests.py\|results\.json\|data/commits\|index-arch\|index-extra" \
  src/ run CLAUDE.md --include="*.sh" --include="*.md" 2>/dev/null || echo "Clean"
```

**Step 4: Final commit if any fixes needed**

```bash
git add -A
git status
# Only commit if there are changes
```
