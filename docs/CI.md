# Continuous Integration

## Workflows

### Nightly ZKVM Updates
**Files:**
- `.github/workflows/build-and-test-zkvm.yml` (reusable)
- `.github/workflows/nightly-jolt-update.yml`
- `.github/workflows/nightly-zisk-update.yml`

**Purpose:** Check for upstream updates, rebuild binaries, run full test suite, validate debug command
**Runtime:** ~5+ minutes per ZKVM

**Steps:**
1. Check for new commits in upstream ZKVM repository
2. Update config.json if new commit found
3. Build ZKVM binary
4. Run full RISCOF test suite (`./src/test.sh --arch <zkvm>`)
5. **Test debug command** (`./src/test_debug.sh <zkvm>`) ← validates debug command works
6. Update dashboard
7. Commit results to git
8. Create issue on failure

### Pages Deployment
**File:** `.github/workflows/deploy.yml`
**Trigger:** Changes to docs/ or data/results.json
**Purpose:** Deploy dashboard to GitHub Pages

## Test Results

Test results are generated during test runs and not tracked in git:

- `test-results/` - Created by `./run test --arch <zkvm>`
- Contains compiled test ELFs and execution results
- Used by debug command to re-run specific tests
- Cleaned between runs to ensure fresh results

## Local Testing

Before pushing changes:

```bash
# Test full suite
./run test --arch sp1

# Test debug command (requires test results)
./src/test_debug.sh sp1

# Or build tests without running
./run test --arch --build-only
```

## Debugging Failed Tests

```bash
# Run specific failing test with verbose output
./run debug --arch openvm div-01

# Logs saved to: debug-output/openvm/arch/div-01.log
```

## Validating Debug Command

The `src/test_debug.sh` script validates that the debug command works correctly:

```bash
# Test specific ZKVM (requires test results from ./run test)
./src/test_debug.sh sp1

# Test all ZKVMs
./src/test_debug.sh all
```

This is automatically run in nightly CI workflows after the full test suite completes.
