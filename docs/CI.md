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
5. **Test debug command** (`./run test-debug <zkvm>`) ← validates debug command works
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
# Test debug command locally
./run test-debug

# Validate workflow syntax (requires act or GitHub CLI)
act -l  # List workflows
act pull_request  # Simulate PR
```
