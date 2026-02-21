# Parameterize GitHub Actions Workflow Runner Implementation Plan

## Executive Summary

### Problem Statement
The reusable workflow `build-and-test-zkvm.yml` currently has the `runs-on` field hardcoded in its job definition. This creates a problem when different ZKVMs have different runner requirements:
- **Zisk** requires self-hosted runners (`[self-hosted-ghr, size-xl-x64]`) due to resource-intensive operations that cause hangs on GitHub-hosted runners
- **Jolt** works fine with standard GitHub-hosted runners (`ubuntu-latest`)

Currently, any change to the runner configuration in the reusable workflow affects ALL caller workflows (both jolt and zisk), preventing per-ZKVM runner customization.

### Proposed Solution
Add a single optional `runner` input parameter to the reusable workflow that accepts a JSON-encoded array of runner labels. This allows:
1. Each caller workflow to specify its preferred runner configuration
2. A sensible default (`["ubuntu-latest"]`) for workflows that don't specify a runner
3. Minimal changes to maintain workflow readability and simplicity

### Technical Approach
- Add `runner` input to `build-and-test-zkvm.yml` with type `string` and default value `'["ubuntu-latest"]'`
- Use `fromJSON()` to parse the input in the `runs-on` field
- Update `nightly-zisk-update.yml` to pass custom runner configuration
- Leave `nightly-jolt-update.yml` unchanged (uses default)

### Expected Outcomes
- Zisk nightly updates run on self-hosted runners without hanging
- Jolt nightly updates continue using free GitHub-hosted runners
- Future ZKVMs can easily specify their preferred runner configuration
- Workflow remains clean, readable, and maintainable

## Goals & Objectives

### Primary Goals
- **Enable per-ZKVM runner configuration**: Allow each ZKVM to specify its optimal runner environment without affecting others
- **Maintain backward compatibility**: Existing workflows continue working without modification
- **Keep implementation minimal**: Single parameter addition with no complex logic

### Secondary Objectives
- **Improve workflow clarity**: Make runner configuration explicit and visible at the caller level
- **Enable future flexibility**: Support additional runner configurations as new ZKVMs are added
- **Document runner requirements**: Make it clear which ZKVMs need which runners

## Solution Overview

### Approach
Add an optional input parameter to the reusable workflow that controls the `runs-on` field. The parameter accepts a JSON-encoded array of runner labels, allowing both single runners and multi-label configurations (like self-hosted runners with size labels).

### Key Components

1. **Reusable Workflow Input**: Add `runner` parameter to `build-and-test-zkvm.yml`
   - Type: string
   - Required: false
   - Default: `'["ubuntu-latest"]'`
   - Format: JSON array of runner labels

2. **Runner Configuration Parsing**: Use `fromJSON()` in `runs-on` field
   - Parses the JSON string into an array
   - Supports both single runners and multi-label runners
   - Works with GitHub Actions' native runner selection

3. **Caller Configuration**: Update `nightly-zisk-update.yml` to specify self-hosted runner
   - Pass `runner: '["self-hosted-ghr", "size-xl-x64"]'`
   - Other callers omit the parameter to use default

### Data Flow
```
Caller Workflow (nightly-zisk-update.yml)
  └─> Passes: zkvm='zisk', runner='["self-hosted-ghr", "size-xl-x64"]'
      └─> Reusable Workflow (build-and-test-zkvm.yml)
          └─> fromJSON(inputs.runner) → [self-hosted-ghr, size-xl-x64]
              └─> Job runs on: Self-hosted runner with both labels

Caller Workflow (nightly-jolt-update.yml)
  └─> Passes: zkvm='jolt' (no runner specified)
      └─> Reusable Workflow (build-and-test-zkvm.yml)
          └─> fromJSON(inputs.runner) → [ubuntu-latest] (default)
              └─> Job runs on: GitHub-hosted ubuntu-latest
```

## Implementation Tasks

### CRITICAL IMPLEMENTATION RULES
1. **NO PLACEHOLDER CODE**: Every implementation must be production-ready. NEVER write "TODO", "in a real implementation", or similar placeholders unless explicitly requested by the user.
2. **CROSS-DIRECTORY TASKS**: Group related changes across directories into single tasks to ensure consistency. Never create isolated changes that require follow-up work in sibling directories.
3. **COMPLETE IMPLEMENTATIONS**: Each task must fully implement its feature including all consumers, type updates, and integration points.
4. **DETAILED SPECIFICATIONS**: Each task must include EXACTLY what to implement, including specific functions, types, and integration points to avoid "breaking change" confusion.
5. **CONTEXT AWARENESS**: Each task is part of a larger system - specify how it connects to other parts.

### Visual Dependency Tree

```
.github/workflows/
├── build-and-test-zkvm.yml (Task #0: Add runner input parameter)
│   ├── Adds: runner input with default value
│   └── Changes: runs-on field to use fromJSON()
│
├── nightly-zisk-update.yml (Task #1: Configure self-hosted runner)
│   └── Adds: runner parameter to workflow call
│
└── nightly-jolt-update.yml (No changes - uses default)
```

### Execution Plan

#### Group A: Foundation (Must be sequential due to caller dependency)

- [x] **Task #0**: Add runner input parameter to reusable workflow
  - **File**: `.github/workflows/build-and-test-zkvm.yml`
  - **Location**: `on.workflow_call.inputs` section (after existing `zkvm` input)
  - **Changes**:
    1. Add new input parameter:
       ```yaml
       runner:
         type: string
         required: false
         default: '["ubuntu-latest"]'
         description: 'Runner labels as JSON array (e.g., ["ubuntu-latest"] or ["self-hosted-ghr", "size-xl-x64"])'
       ```
    2. Update `runs-on` field in `jobs.update`:
       ```yaml
       runs-on: ${{ fromJSON(inputs.runner) }}
       ```
  - **Current state**: Line 18 has `runs-on: ubuntu-latest` (or `[self-hosted-ghr, size-xl-x64]` in current branch)
  - **New state**: `runs-on: ${{ fromJSON(inputs.runner) }}`
  - **Context**: This makes the runner configurable while maintaining backward compatibility through the default value
  - **Validation**:
    - Default value must be valid JSON array format
    - fromJSON() correctly parses both single and multi-label arrays
  - **Integration**: All caller workflows can now optionally specify their runner preference

- [x] **Task #1**: Configure zisk workflow to use self-hosted runner
  - **File**: `.github/workflows/nightly-zisk-update.yml`
  - **Location**: `jobs.update-zisk.with` section (after `zkvm: zisk`)
  - **Changes**:
    1. Add runner parameter to workflow call:
       ```yaml
       jobs:
         update-zisk:
           uses: ./.github/workflows/build-and-test-zkvm.yml
           with:
             zkvm: zisk
             runner: '["self-hosted-ghr", "size-xl-x64"]'
       ```
  - **Current state**: Only passes `zkvm: zisk` parameter
  - **New state**: Passes both `zkvm` and `runner` parameters
  - **Context**: Specifies that zisk requires self-hosted runners with size-xl-x64 label to avoid workflow hangs
  - **Validation**: Runner labels must match available self-hosted runner configuration
  - **Integration**: Uses the new runner parameter added in Task #0
  - **Note**: The jolt workflow (nightly-jolt-update.yml) requires NO changes - it will use the default ubuntu-latest runner

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
- Tasks should be run sequentially in this case (Task #1 depends on Task #0)

### Progress Tracking
The checkboxes above represent the authoritative status of each task. Keep them updated as you work.

---

## Testing & Validation

After implementation, validate by:

1. **Test zisk workflow**: Manually trigger `nightly-zisk-update.yml` workflow_dispatch
   - Verify it runs on self-hosted runner (check workflow run logs for runner label)
   - Confirm build and test complete without hanging

2. **Test jolt workflow**: Manually trigger `nightly-jolt-update.yml` workflow_dispatch
   - Verify it runs on ubuntu-latest (check workflow run logs)
   - Confirm existing behavior unchanged

3. **Verify backward compatibility**: Check that the default value works correctly
   - Any workflow calling build-and-test-zkvm.yml without specifying runner should use ubuntu-latest

## Notes

- **JSON format requirement**: Runner labels must be passed as JSON arrays even for single runners (e.g., `'["ubuntu-latest"]'` not just `'ubuntu-latest'`)
- **Self-hosted runner availability**: The self-hosted runner with labels `self-hosted-ghr` and `size-xl-x64` must be configured and online before zisk workflow can use it
- **Branch merge consideration**: This change should be compatible with both current branch (fix-zisk-action-hang-2) and main branch
