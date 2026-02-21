# ACT4 vs RISCOF — FAQ

## Q1: Why did Zisk have 188 target tests while other ZKVMs have 72?

**Answer: Bug — now fixed.**

The target suite is a fixed common baseline: **RV64IM_Zicclsm** (I + M + Misalign = 72
tests), identical for all ZKVMs. It tests compliance with the shared profile that every
ZK-VM is expected to support.

Full-ISA extensions (F, D, C, A) are tested in the **native suite**, not the target
suite. Each ZKVM's native suite tests whatever its DUT config declares.

The Zisk entrypoint was incorrectly passing `I,M,F,D,...,Misalign` to the target run
instead of just `I,M,Misalign`. Fixed by scoping the target extensions down to match
all other ZKVMs.

Target breakdown (should be same for all ZKVMs):
| Extension | Tests |
|-----------|-------|
| I         | 51    |
| M         | 13    |
| Misalign  |  8    |
| **Total** | **72**|

---

## Q2: Zisk used to have ~600 target tests under RISCOF. ACT4 has far fewer. Why?

**Answer: Different framework, different counting methodology — not a regression.**

RISCOF's 673 tests were split across two ISAs and had many variants per instruction:

- **Both rv32 AND rv64**: ~half the tests were RV32 variants of the same instructions.
  ACT4 only runs the rv64 target.
- **Many test files per instruction**: RISCOF generated boundary-case variants as
  separate files (`fadd.d_b1-01.S`, `fadd.d_b2-01.S` … `fadd.d_b13-01.S`). ACT4
  generates one comprehensive self-checking ELF per instruction that covers all cases
  internally.
- **Different extension mapping**: RISCOF's `privilege/` category had ebreak, ecall,
  and misalign-exception tests. ACT4's `Misalign` tests cover different semantics
  (see Q3).

ACT4's 72-test baseline covers I+M+Misalign in rv64 only. The total is smaller but
the test quality and self-checking approach is stronger.

---

## Q3: Zisk used to fail some privilege/exception tests under RISCOF. ACT4 passes all. Is that a fix?

**Answer: No — those tests don't exist in ACT4. This is a coverage gap, not a fix.**

RISCOF's `privilege/` failures for Zisk were:
- `ebreak.S` — machine-mode breakpoint exception handling
- `ecall.S` — machine-mode environment call handling
- `misalign-ld-01.S` … `misalign-sw-01.S` (8 tests) — misaligned access *exception*
  handling: checks that the trap writes correct values to `mcause`/`mtval`

These test **M-mode exception infrastructure** that ZK-VMs typically don't implement in
the traditional RISC-V way. Zisk doesn't handle misaligned accesses by raising an
exception with machine-mode trap registers — it handles them transparently or not at all.

**ACT4's `Misalign` tests are semantically different.** They test the `Zicclsm`
profile: "does a misaligned load/store complete and return correct data?" — not "does
it raise a trap with correct mtval/mcause?" Zisk passes because it supports transparent
misaligned memory access.

The RISCOF ebreak/ecall/misalign-exception failures represent real Zisk limitations
(no M-mode trap handling). ACT4 simply doesn't test that behavior yet. If/when ACT4
adds privilege/exception tests, Zisk would likely fail them for the same reasons.
