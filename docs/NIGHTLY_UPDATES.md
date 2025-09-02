# Nightly Jolt ZKVM Updates

This repository includes an automated GitHub Actions workflow that performs nightly updates of the Jolt ZKVM to the latest commit.

## How It Works

The workflow runs daily at 3:00 AM UTC and:

1. **Checks for updates** - Fetches the latest commit hash from the Jolt repository
2. **Updates configuration** - Updates `config.json` with the new commit hash if needed
3. **Builds Jolt** - Runs the build process using the existing Docker infrastructure
4. **Tests Jolt** - Runs RISCOF compliance tests
5. **Updates dashboard** - Regenerates the HTML dashboard with new results
6. **Commits changes** - Commits and pushes all updates back to the repository

## Workflow File

The workflow is defined in `.github/workflows/nightly-jolt-update.yml`.

## Manual Triggering

You can manually trigger the workflow from the GitHub Actions tab:

1. Go to the **Actions** tab in GitHub
2. Select **Nightly Jolt ZKVM Update**
3. Click **Run workflow**

This is useful for:
- Testing the workflow
- Forcing an immediate update
- Re-running after fixing issues

## Error Handling

The workflow includes robust error handling:

- **Build failures** are recorded but don't stop the process
- **Test failures** are recorded but don't prevent dashboard updates  
- **Failed runs** automatically create GitHub issues for tracking
- **Status summaries** are posted to the workflow run page

## Testing Locally

Before the workflow runs, you can test the update logic locally:

```bash
# Test the update logic
./scripts/test-jolt-update.sh

# Manually perform a Jolt update
CURRENT_COMMIT=$(jq -r '.zkvms.jolt.commit' config.json)
LATEST_COMMIT=$(git ls-remote $(jq -r '.zkvms.jolt.repo_url' config.json) HEAD | cut -f1 | head -c8)

if [ "$CURRENT_COMMIT" != "$LATEST_COMMIT" ]; then
    echo "Update available: $CURRENT_COMMIT -> $LATEST_COMMIT"
    
    # Update config
    jq --arg commit "$LATEST_COMMIT" '.zkvms.jolt.commit = $commit' config.json > config.json.tmp
    mv config.json.tmp config.json
    
    # Build and test
    FORCE=1 ./run all jolt
fi
```

## Monitoring

The workflow provides several ways to monitor its status:

1. **GitHub Actions tab** - View workflow run history and logs
2. **Commit messages** - Automated commits include build/test status
3. **GitHub Issues** - Failed runs create issues automatically  
4. **Dashboard** - Updated with latest results and commit hashes

## Configuration

The workflow behavior can be customized by modifying the YAML file:

- **Schedule**: Change the `cron` expression to run at different times
- **Target ZKVM**: Currently hardcoded to Jolt, but could be parameterized
- **Build timeout**: Docker builds have default timeouts that can be extended
- **Error handling**: Adjust which failures are considered critical

## Current Status

- **Jolt Repository**: `https://github.com/codygunton/jolt`
- **Current Commit**: Check `config.json` or the dashboard
- **Build Command**: `cargo build --release -p tracer --bin jolt-emu`
- **Binary Path**: `target/release/jolt-emu`

## Troubleshooting

### Common Issues

1. **Build failures**
   - Check Docker daemon status
   - Verify Dockerfile exists at `docker/build-jolt/Dockerfile`
   - Check for Rust/Cargo issues in the Jolt repository

2. **Test failures**  
   - Verify RISCOF plugin exists at `riscof/plugins/jolt/`
   - Check binary permissions and execution
   - Look for RISC-V compliance test issues

3. **Permission errors**
   - Ensure the workflow has `contents: write` permission
   - Check that GitHub token has push access

4. **Network issues**
   - Verify access to external repositories
   - Check for rate limiting on git operations

### Debugging

To debug issues:

1. Check the **Actions** tab for detailed logs
2. Look for automatically created **Issues** for failed runs
3. Run the test script locally: `./scripts/test-jolt-update.sh`
4. Check individual components: `./run build jolt`, `./run test jolt`

### Manual Recovery

If the workflow fails and needs manual intervention:

```bash
# 1. Pull latest changes
git pull origin main

# 2. Check current state
./scripts/test-jolt-update.sh

# 3. Force rebuild if needed
FORCE=1 ./run build jolt

# 4. Run tests
./run test jolt

# 5. Update dashboard  
./run update

# 6. Commit manually if needed
git add .
git commit -m "manual: fix Jolt update issues"
git push origin main
```