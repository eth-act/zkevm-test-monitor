# ZKVM Upstream Staleness Report

_Generated 2026-04-07_

| ZKVM | Fork? | Upstream | Our Base Commit | Commits Behind | New Releases |
|------|-------|----------|-----------------|----------------|--------------|
| **sp1** | Yes → `succinctlabs/sp1` | main | `3a1ff32f` (v6.0.2) | 43 | None after v6.0.2 |
| **jolt** | Yes → `a16z/jolt` | main | `2e05fe88` | 63 | None (last: v0.3.0-alpha, Oct 2025) |
| **openvm** | No | `openvm-org/openvm` | `bf11b4a5` | 2 | v2.0.0-alpha (2026-02-17) |
| **r0vm** | Yes → `risc0/risc0` | main | `6470cece` | 12 | None after v3.0.5 |
| **zisk** | No | `0xPolygonHermez/zisk` | `aacf0a73` (v0.15.0) | 22 | v0.16.0, v0.16.1 |
| **pico** | Yes → `brevis-network/pico` | main | `f8617c9c` | 0 | None (last: v1.3.0) |
| **airbender** | Yes → `matter-labs/zksync-airbender` | dev | `769ec2e3` | 26 | None (last: v0.5.2, Dec 2025) |

## Notes

**Zisk** — most actionable upgrade: pinned at v0.15.0, upstream is at v0.16.1 (22 commits, 2 releases). Note: v0.16.0 removed the `--witness-lib` flag currently used in our entrypoint.

**OpenVM** — v2.0.0-alpha released 6 days after our pin; only 2 upstream commits to integrate, but it's a major version bump.

**Jolt** — largest raw drift (63 commits) but no formal release since v0.3.0-alpha (Oct 2025). Our fork adds a `jolt-prover` CLI and halt-macro changes.

**Airbender** — tracks the upstream `dev` branch (not `main`); 26 dev commits since our last sync (2026-02-17). Our fork adds ACT4 test support on the `riscof-dev` branch.

**SP1** — 43 commits behind post-v6.0.2; no new release tag yet.

**r0vm** — 12 commits behind merge-base; our fork adds `--test-elf` / `--execute-only` flags and makes `ExecutorImpl::from_kernel_elf` public.

**Pico** — fully current; upstream has not moved since our fork base (2026-02-12).
