# Jolt ACT4 Failures Analysis

## Current failures (ACT4 native suite: 116/119)

| Failing test | Extension | Description |
|---|---|---|
| `Zalrsc-sc.d-00` | Zalrsc (A) | Store-conditional doubleword |
| `Zalrsc-sc.w-00` | Zalrsc (A) | Store-conditional word |
| `Zca-c.slli-00` | Zca (C) | Compressed shift-left-logical-immediate |

All three are within the rv64imac scope that Jolt claims to support.

---

## sc.d / sc.w — genuinely new coverage

The old RISCOF A suite had **18 tests, all AMO operations** (`amoadd`, `amoand`, `amomax`, etc.).
It had **zero LR/SC tests**. The entire Zalrsc sub-extension was untested by RISCOF.

ACT4 adds four LR/SC tests: `lr.d`, `lr.w`, `sc.d`, `sc.w`. The `lr` variants pass; only `sc` fails.

This is not a regression — Jolt's SC implementation was likely always broken, it just was never tested.

---

## c.slli-00 — new variant of an existing test

RISCOF had `cslli-01.S` which passed. ACT4 has a different test program `c.slli-00` which tests
edge cases including large shift amounts (e.g. `c.slli x1, 33`) and a wider range of register
combinations that RISCOF's single test didn't cover.

---

## Old RISCOF test counts (rv64imac, 124/124 passed)

| Extension | RISCOF tests | Notes |
|---|---|---|
| A | 18 | AMO only — no LR/SC |
| C | 34 | cslli-01 passed |
| I | 51 | |
| M | 13 | |
| privilege | 8 | |

---

## Target suite failures (act4-target: 8/16 — separate issue)

The 8 Misalign target suite failures are unrelated to the above. They test hardware-handled
misaligned loads/stores (Zicclsm profile). Jolt declares Zicclsm but does not appear to
hardware-handle misaligned accesses. This may be an intentional limitation.
