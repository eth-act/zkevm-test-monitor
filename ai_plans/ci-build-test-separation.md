# CI Build/Test Separation Implementation Plan

## Executive Summary

### Problem Statement
The current CI pipeline for zisk nightly tasks runs in a single monolithic job where expensive Rust compilation and test execution happen sequentially. The test execution is artificially limited to single-threaded mode (`JOBS=1`), despite the RISCOF framework supporting parallelization. This creates a significant bottleneck where:
- Compilation is heavy and must be single-threaded
- Tests that could run in parallel are forced to run serially
- Total CI runtime is unnecessarily long

### Proposed Solution
Separate the build and test phases into two distinct GitHub Actions jobs:

1. **Build Job**: Compiles the `ziskemu` binary once using a single thread
2. **Test Job**: Downloads the compiled binary and runs tests in parallel using all available CPU cores

The compiled binary is passed between jobs using GitHub Actions artifacts, enabling:
- One expensive compilation step
- Parallel test execution across all available cores
- Natural speedup without architectural changes

### Technical Approach

```
Current (Sequential):
┌─────────────────────────────────────┐
│   Single Job (XL Runner)            │
│                                      │
│   1. Checkout                        │
│   2. Build (single-threaded)  ──────┼─── SLOW
│   3. Test (JOBS=1)            ──────┼─── SLOW
│   4. Commit results                  │
└─────────────────────────────────────┘
Total Time: T_build + T_test_serial

Proposed (Parallel):
┌──────────────────────┐
│   Build Job          │
│                      │
│   1. Checkout        │
│   2. Build binary    │
│   3. Upload artifact │
└──────────┬───────────┘
           │
           │ (artifact)
           ▼
┌──────────────────────┐
│   Test Job           │
│                      │
│   1. Download binary │
│   2. Test (JOBS=N)   │──── FAST (parallel)
│   3. Commit results  │
└──────────────────────┘
Total Time: T_build + (T_test_serial / N)
```

### Data Flow

```
[Checkout Repo]
      │
      ▼
[Build Docker Container]
      │
      ▼
[Extract ziskemu Binary] ────► [Upload as Artifact]
                                        │
                                        │ (GitHub Artifacts API)
                                        ▼
                              [Download in Test Job]
                                        │
                                        ▼
                              [Run RISCOF Tests in Parallel]
                                        │
                                        ▼
                              [Upload Results & Commit]
```

### Expected Outcomes
- **Faster CI runtime**: Tests run in parallel across available cores (speedup scales with core count)
- **Better resource utilization**: Test job uses all available CPU cores instead of just one
- **Same reliability**: No changes to RISCOF framework or test execution logic
- **Cleaner separation**: Build failures don't waste time on test setup, test failures don't require rebuilding
- **Artifact reuse potential**: Compiled binary could be reused for multiple test configurations in the future

## Goals & Objectives

### Primary Goals
- **Separate build and test phases** into distinct GitHub Actions jobs with clear boundaries
- **Enable parallel test execution** by removing the `JOBS=1` constraint and using `JOBS=$(nproc)` or equivalent
- **Maintain RISCOF compatibility** with zero changes to the RISCOF framework or plugin code

### Secondary Objectives
- **Improve CI runtime** by leveraging multi-core parallelization during test execution
- **Enable artifact reuse** for potential future use cases (debugging, multiple test configurations)
- **Cleaner failure isolation**: Build failures don't trigger test setup, test failures don't require rebuilds

## Solution Overview

### Approach
Refactor the monolithic `build-and-test-zkvm.yml` workflow into two separate jobs that communicate via GitHub Actions artifacts:

1. **Build Job**: Handles checkout, dependency installation, Docker build, and binary extraction. Uploads the compiled `ziskemu` binary as an artifact.
2. **Test Job**: Downloads the binary artifact, runs RISCOF tests with parallelization enabled (`JOBS=$(nproc)`), and handles result reporting and commits.

The test job depends on the build job (`needs: build`) ensuring sequential execution at the job level while enabling parallelization within the test execution.

### Key Components

1. **Job Separation**: Split single `update` job into `build` and `test` jobs in `.github/workflows/build-and-test-zkvm.yml`
2. **Artifact Management**: Add artifact upload/download steps using `actions/upload-artifact@v4` and `actions/download-artifact@v4`
3. **Parallelization Configuration**: Update `src/test.sh` to accept dynamic `JOBS` parameter and default to available CPU count
4. **Workflow Orchestration**: Configure job dependencies and runner selection for optimal resource usage

### Architecture Diagram

```
┌────────────────────────────────────────────────────────────┐
│  nightly-zisk-update.yml (trigger)                         │
│  - schedule: cron '30 3 * * *'                             │
│  - calls: build-and-test-zkvm.yml                          │
└────────────────┬───────────────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────────────────┐
│  build-and-test-zkvm.yml (reusable workflow)               │
│                                                             │
│  ┌──────────────────────────────────────────────┐         │
│  │  Job: build                                  │         │
│  │  - checkout                                   │         │
│  │  - install dependencies                       │         │
│  │  - docker build (cargo build --release)       │         │
│  │  - extract binary to binaries/zisk-binary     │         │
│  │  - actions/upload-artifact@v4                 │         │
│  └────────────────┬─────────────────────────────┘         │
│                   │                                         │
│                   │ (needs: build)                          │
│                   ▼                                         │
│  ┌──────────────────────────────────────────────┐         │
│  │  Job: test                                   │         │
│  │  - actions/download-artifact@v4               │         │
│  │  - make binary executable                     │         │
│  │  - JOBS=$(nproc) ./src/test.sh --arch zisk   │         │
│  │  - commit results                             │         │
│  │  - create issue on failure                    │         │
│  └──────────────────────────────────────────────┘         │
└────────────────────────────────────────────────────────────┘
```

### Expected Outcomes
- CI runtime reduces from `T_build + T_test_serial` to `T_build + (T_test_serial / N_cores)`
- Test job utilizes all available CPU cores on the XL runner
- Build and test failures are isolated (easier debugging)
- No changes to RISCOF framework or test methodology
- Compiled binary is reusable for future optimizations

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. **NO PLACEHOLDER CODE**: Every implementation must be production-ready. NEVER write "TODO", "in a real implementation", or similar placeholders unless explicitly requested by the user.
2. **CROSS-DIRECTORY TASKS**: Group related changes across directories into single tasks to ensure consistency. Never create isolated changes that require follow-up work in sibling directories.
3. **COMPLETE IMPLEMENTATIONS**: Each task must fully implement its feature including all consumers, type updates, and integration points.
4. **DETAILED SPECIFICATIONS**: Each task must include EXACTLY what to implement, including specific functions, types, and integration points to avoid "breaking change" confusion.
5. **CONTEXT AWARENESS**: Each task is part of a larger system - specify how it connects to other parts.
6. **MAKE BREAKING CHANGES**: Unless explicitly requested by the user, you MUST make breaking changes when necessary.

### Visual Dependency Tree

```
.github/workflows/
├── build-and-test-zkvm.yml (Task #1: Split into build + test jobs)
│   ├── job: build (Task #1)
│   │   ├── Upload artifact step (Task #1)
│   │   └── Outputs binary artifact
│   │
│   └── job: test (needs: build) (Task #1)
│       ├── Download artifact step (Task #1)
│       └── Uses updated test.sh (from Task #0)
│
src/
└── test.sh (Task #0: Add dynamic JOBS parameter support)
```

### Execution Plan

#### Group A: Foundation (Execute in parallel)
- [ ] **Task #0**: Update test.sh to support dynamic JOBS parameter
  - **File**: `src/test.sh`
  - **Current state**: Hardcoded `JOBS=1` on line 107
  - **Changes required**:
    1. Add parameter parsing for `--jobs` or `-j` flag
    2. Default to `$(nproc)` if not specified
    3. Preserve ability to set `JOBS=1` for backwards compatibility
  - **Implementation**:
    ```bash
    # Add near top of script (after other parameter parsing)
    JOBS="${JOBS:-$(nproc)}"  # Default to number of CPU cores

    # Support --jobs flag
    while [[ $# -gt 0 ]]; do
      case $1 in
        --jobs|-j)
          JOBS="$2"
          shift 2
          ;;
        # ... existing cases ...
      esac
    done

    # Line 107 changes from:
    # JOBS=1 ./src/test.sh --arch ${ZKVM}
    # To:
    # JOBS=${JOBS} ./src/test.sh --arch ${ZKVM}
    ```
  - **Exports**: Updated `test.sh` that respects `JOBS` environment variable
  - **Context**: This allows the test job to control parallelization without modifying RISCOF
  - **Testing**: Verify `JOBS=1` still works, `JOBS=4` works, and default `JOBS=$(nproc)` works
  - **Integration**: Used by Task #1 test job

#### Group B: Job Separation (Execute after Group A)
- [ ] **Task #1**: Refactor build-and-test-zkvm.yml to separate build and test jobs
  - **File**: `.github/workflows/build-and-test-zkvm.yml`
  - **Current state**: Single monolithic `update` job with 15 sequential steps
  - **Changes required**:
    1. Split `update` job into `build` and `test` jobs
    2. Add artifact upload/download steps
    3. Configure job dependencies (`test` needs `build`)
    4. Distribute steps between jobs appropriately

  - **Implementation details**:

    **Job: build**
    - Runner: Use `inputs.runner` (self-hosted XL)
    - Steps to include:
      1. Checkout repository
      2. Configure git
      3. Install dependencies (`libomp-dev` for zisk)
      4. Get latest commit
      5. Update config.json
      6. Set up Docker Buildx
      7. Build ZKVM (lines 86-97 from current workflow)
      8. **NEW**: Upload artifact step
        ```yaml
        - name: Upload compiled binary
          uses: actions/upload-artifact@v4
          with:
            name: zkvm-${{ inputs.zkvm }}-binary
            path: binaries/${{ inputs.zkvm }}-binary
            retention-days: 1
            if-no-files-found: error
        ```
    - Output: Compiled binary uploaded as artifact
    - Failure handling: Job fails if build fails (no `continue-on-error`)

    **Job: test**
    - Depends on: `needs: build`
    - Runner: Use `inputs.runner` (self-hosted XL)
    - Steps to include:
      1. Checkout repository (needed for test scripts and RISCOF config)
      2. Install dependencies (test.sh dependencies)
      3. **NEW**: Download artifact step
        ```yaml
        - name: Download compiled binary
          uses: actions/download-artifact@v4
          with:
            name: zkvm-${{ inputs.zkvm }}-binary
            path: binaries/

        - name: Make binary executable
          run: chmod +x binaries/${{ inputs.zkvm }}-binary
        ```
      4. Test ZKVM (lines 99-109 from current workflow)
        - **CRITICAL CHANGE**: Remove `JOBS=1` prefix
        - **NEW**: Set `JOBS=$(nproc)` or allow default from Task #0
        ```yaml
        - name: Test ZKVM
          run: |
            JOBS=$(nproc) ./src/test.sh --arch ${{ inputs.zkvm }}
          continue-on-error: true
        ```
      5. Test Debug Command (lines 111-125)
      6. Record test failure (lines 127-133)
      7. Update dashboard (lines 135-142)
      8. Commit and push changes (lines 144-159)
      9. Fail job if tests failed (lines 161-166)
      10. Create issue on failure (lines 168-202)
      11. Post job summary (lines 204-235)
    - Output: Test results committed to repo, issues created on failure
    - Failure handling: Preserve existing `continue-on-error` and conditional failure logic

  - **Job dependency configuration**:
    ```yaml
    jobs:
      build:
        runs-on: ${{ inputs.runner }}
        steps:
          # ... build steps ...

      test:
        needs: build
        runs-on: ${{ inputs.runner }}
        steps:
          # ... test steps ...
    ```

  - **Artifact naming**: Use `zkvm-${{ inputs.zkvm }}-binary` to support both zisk and jolt

  - **Retention**: Set to 1 day (artifacts only needed for duration of workflow run)

  - **Error handling**:
    - Build job: Fail immediately if build fails (no artifact to test)
    - Test job: Preserve existing `continue-on-error: true` on test step to allow result recording

  - **Git operations**: Move all commit/push/issue creation to test job (matches current behavior)

  - **Exports**: Updated workflow with two-job structure
  - **Context**: This is the core change that enables build/test separation and parallelization
  - **Integration**: Called by `nightly-zisk-update.yml` and `nightly-jolt-update.yml`
  - **Testing**:
    - Verify build job completes and uploads artifact
    - Verify test job downloads artifact correctly
    - Verify binary is executable in test job
    - Verify parallel test execution works
    - Verify failure handling (build failure, test failure) works as expected
    - Test with both zisk and jolt workflows

---

## Implementation Workflow

This plan file serves as the authoritative checklist for implementation. When implementing:

### Required Process
1. **Load Plan**: Read this entire plan file before starting
2. **Sync Tasks**: Create TodoWrite tasks matching the checkboxes below
3. **Execute & Update**: For each task:
   - Mark TodoWrite as `in_progress` when starting
   - Update checkbox `[ ]` to `[x]` when completing
   - Mark TodoWrite as `completed` when done
4. **Maintain Sync**: Keep this file and TodoWrite synchronized throughout

### Critical Rules
- This plan file is the source of truth for progress
- Update checkboxes in real-time as work progresses
- Never lose synchronization between plan file and TodoWrite
- Mark tasks complete only when fully implemented (no placeholders)
- Tasks should be run in parallel where possible using subtasks to avoid context bloat

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.

## Testing & Validation

After implementation, verify:

1. **Build job works independently**:
   - Trigger workflow manually
   - Verify build completes successfully
   - Check artifact is uploaded to GitHub Actions artifacts

2. **Test job receives artifact**:
   - Verify artifact downloads correctly
   - Check binary has execute permissions
   - Confirm binary path matches expected location

3. **Parallel execution works**:
   - Monitor test execution logs
   - Verify `JOBS=N` where N > 1 (check with `nproc` output in logs)
   - Confirm tests run in parallel (RISCOF will show parallel make jobs)

4. **Failure scenarios**:
   - Trigger build failure (e.g., invalid commit) → verify build job fails, test job skipped
   - Trigger test failure (e.g., known failing test) → verify test job records failure correctly
   - Verify issue creation still works on failures

5. **Backwards compatibility**:
   - Jolt workflow still works (uses same reusable workflow)
   - Manual `JOBS=1` override still works if needed
   - All existing failure reporting mechanisms intact

6. **Performance validation**:
   - Compare CI runtime before and after
   - Verify speedup is meaningful (target: test phase faster by factor of N_cores)
   - Check resource utilization on self-hosted runner

## Rollback Plan

If issues arise:
1. Revert changes to `.github/workflows/build-and-test-zkvm.yml`
2. Revert changes to `src/test.sh`
3. Original workflow remains in git history for easy restoration
4. No data loss risk (commits happen in test job same as before)

## Future Enhancements

After successful implementation, consider:
- **Matrix strategy**: Split tests into multiple parallel jobs (e.g., by ISA extension)
- **Artifact caching**: Cache compiled binary across workflow runs if commit hasn't changed
- **Multiple test configurations**: Use single build artifact for arch + extra test suites
- **Resource optimization**: Use smaller runner for test job if build is the bottleneck
