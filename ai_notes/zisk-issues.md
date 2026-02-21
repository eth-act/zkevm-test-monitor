# Zisk Known Issues

## Issue 1: 65 ACT4 F/D test failures ✅ RESOLVED

**Status**: Resolved via `patch_elfs.py --zisk` workaround (2026-02-21)
**Impact was**: 65 ACT4 F/D test failures (17 F + 48 D), all exit code 101
**Discovered**: 2026-02-20 | **Resolved**: 2026-02-21

### Summary

All 65 failures are caused by a **Zisk memory model bug** interacting with the ACT4
failure-reporting code. The FP operations themselves are **correct** — all self-check
comparisons pass. Zisk maps `.text.init` as execute-only, and the ACT4 failure handler
reads instruction bytes from `.text.init` to generate error output. That read triggers a
Rust panic in `mem.rs`, causing exit 101.

### Root cause

The ACT4 framework (`signature.h`) includes a failure handler that, when a comparison
fails, decodes the failing instruction by reading its bytes from `.text.init`:

```asm
# failedtest_saveresults
lhu x6, -14(x5)   # x5 = return addr into .text.init
lhu x7, -16(x5)   # negative offsets reach back to the failing instruction
```

Zisk panics on this read:
```
Mem::read() section not found for addr: 8000025e with width: 2
```

Because Zisk maps `.text.init` as execute-only (no read permission), and the RISC-V spec
does not prohibit loading from the code segment with `lhu`.

### Evidence

Binary patching of `D-fclass.s-00.elf` confirmed:

| Patch | Exit code | Meaning |
|-------|-----------|---------|
| Original | 101 | Panics in failure handler |
| Replace each `jal failedtest` callsite with `li a0, N; ecall` | 0 | All 14 comparisons pass |
| Replace `failedtest_saveregs` with `ecall` (immediate exit) | 0 | All comparisons pass, handler never crashes |
| Replace `failedtest_saveregs` with NOPs (fall through to `lhu`) | 101 | Still crashes |

All 14 self-check comparisons in `D-fclass.s-00` succeed when the failure handler is
bypassed. Zisk's FP is correct for this test.

### What was investigated and ruled out

- **fcsr reads 0**: DISPROVED. RISCOF signatures prove fcsr works correctly after FP ops.
- **NaN-boxing output broken**: DISPROVED. `flw`, `fadd.s`, `fsgnj.s`, `fcvt.s.w` all
  produce correct NaN-boxed results.
- **Subtle NaN-boxing (single bit wrong)**: DISPROVED. `fclass.s` correctly returns 512
  (canonical NaN) for values like `0xffffefff00000000`.
- **`fsflagsi` broken**: DISPROVED. Standalone test passes.
- **Register scrambling breaks FP**: DISPROVED. Full `rvtest_init` scramble + fclass.s
  test passes.
- **FLEN=64 for F tests**: Confirmed FLEN is per-test-file REQUIRED_EXTENSIONS, same in
  both RISCOF and ACT4.

### ACT4 failure pattern (now explained)

All failing tests have failure handlers that read from `.text.init`. Passing tests either
don't use `RVTEST_SIGUPD_F` (no failure handler) or produce correct results so the
handler is never reached.

### ACT4 results (2026-02-20)

| Extension | Passed | Failed | Total |
|-----------|--------|--------|-------|
| I | 51 | 0 | 51 |
| M | 13 | 0 | 13 |
| F | 25 | 17 | 42 |
| D | 26 | 48 | 74 |
| Misalign | 8 | 0 | 8 |

### Resolution (2026-02-21)

**Workaround implemented** (Option C variant): `docker/shared/patch_elfs.py --zisk`
replaces the first instruction of `failedtest_saveresults` with `jal x0, failedtest_terminate`.

Simple lhu NOPs were insufficient — the subsequent `ld` instructions use stale register
values from the NOPped lhus to compute load addresses, cascading the crash. Replacing
the entire function entry with a direct JAL to the terminate routine (exit 1) skips
all the instruction-decoding logic cleanly.

Result: 180/180 native ✅, 188/188 target ✅. Zisk's FP operations are all correct.

**Long-term fix**: File a bug with the Zisk team — load instructions should be able to
read from the code segment. This is a Zisk spec-compliance issue, not an ACT4 issue.

---

## Issue 2: Missing A/C extension tests in ACT4 results

**Status**: Open (infrastructure)
**Impact**: 59 available test files produce 0 results
**Discovered**: 2026-02-20

### Description

The Zisk UDB config declares A (Zaamo, Zalrsc) and C (Zca, Zcd) extensions. The Dockerfile
pre-generates test sources with `EXTENSIONS=I,M,F,D,Zca,Zcf,Zcd,Zaamo,Zalrsc,Misalign` and
the entrypoint passes the same list to `--extensions`. However, zero A/C tests appear in
results.

Available test files in `riscv-arch-test/tests/rv64i/`:
- Zca: 33 tests
- Zaamo: 18 tests
- Zalrsc: 4 tests
- Zcd: 4 tests
- Zcf: 0 tests (empty directory)

Likely cause: the `act` tool may not be generating Makefiles for these sub-extensions, or
the `extensions.txt` pre-generation (which uses umbrella names A, C) doesn't match what the
framework expects.
