# SP1/Pico ACT4 I-jalr-00 Failure Analysis

## Summary

SP1 and Pico both fail 2 of 47 native ACT4 tests: `I-fence-00` and `I-jalr-00`.

SP1 passed RISCOF's `jalr-01.S` and `misalign1-jalr-01.S` because the RISCOF tests
were run against an older SP1 (v5) which used the interpreter — the interpreter has
the correct `& ~1`. The bug is in the x86 JIT backend, a v6-only feature. This is
not a RISCOF test gap; `misalign1-jalr-01.S` correctly detected the same missing mask
in r0vm (RISC0) when it was present there.

---

## I-fence-00

SP1 returns `Unimplemented` for the FENCE instruction. Trivial — SP1 simply doesn't
implement FENCE.

---

## I-jalr-00

**Root cause**: SP1's JALR implementation does not clear bit 0 of the computed target
address, violating the RISC-V specification.

### SP1 executor bug

**Introduced**: The x86 JIT native executor is a v6-only feature (the `crates/core/jit/`
crate does not exist in v5). The entire JIT was written without `& ~1` from day one:

- `7a541299ad` — "feat: native executor 32bit" by n, 2025-08-11: initial 32-bit JIT,
  jalr already missing bit-0 clearing (used `Rd`/`DWORD` for 32-bit ops).
- `a43e7d91ab` — "feat: port Transpiler to 64bit (#699)" by Brandon Wu, 2025-08-14:
  ported to 64-bit (`Rq`/`QWORD`), jalr code copied verbatim — still no `& ~1`.
- Merged into upstream `dev` via "chore: merge multilinear_v6 (#2580)", 2026-02-18.
- Still unfixed on `upstream/dev` as of the latest commit.

This is not a regression — the bug has been present since the JIT's inception.

The bug exists in SP1's **x86 JIT backend**, which is the execution path used by
`--mode node` (the default for ACT4 tests). Both `execute_node` and `execute_minimal`
use `MinimalExecutor`, which transpiles RISC-V to x86 JIT code via `TranspilerBackend`.

**Buggy JIT** — `crates/core/jit/src/backends/x86/instruction_impl.rs:809-843` (in `~/sp1`):
```rust
fn jalr(&mut self, rd: RiscRegister, rs1: RiscRegister, imm: u64) {
    // ...
    self.emit_risc_operand_load(rs1.into(), TEMP_A);
    dynasm! {
        self;
        .arch x64;
        add Rq(TEMP_A), imm as i32;
        mov QWORD [Rq(CONTEXT) + PC_OFFSET], Rq(TEMP_A)  // BUG: missing & ~1
    }
    // ...
}
```

**Correct interpreter** — `crates/core/executor/src/vm.rs:440`:
```rust
let next_pc = ((b_record.value as i64).wrapping_add(imm_se) as u64) & !1_u64;  // correct
```

**Correct portable minimal** — `crates/core/executor/src/minimal/arch/portable/mod.rs:793`:
```rust
*next_pc = (base.wrapping_add(imm_offset_se) as u64) & !1_u64;  // correct
```

The RISC-V spec requires `next_pc = (rs1 + imm) & ~1`. The JIT omits `& ~1`.
The interpreter and portable minimal implementations are correct, but neither is
used in the `--mode node` execution path.

**Historical note**: An older SP1 version (in `/tmp/sp1-clean`) also had this bug in
`crates/core/executor/src/executor.rs:1686` with `b.wrapping_add(c)` missing `& !1`.
The interpreter has since been fixed, but the JIT backend was not.

### Triggering test case

`cp_offset_lsbs_test_97` in `I-jalr-00.S` (around line 1627):
```asm
# Testcase: rs1 LSB=0, imm LSB=1
LA(x6, jalrlsb_01)   # x6 = &jalrlsb_01  (4-byte aligned, LSB=0)
addi x6, x6, 0       # rs1 LSB stays 0
jalr x30, x6, 1      # imm LSB = 1
                      # correct target = (&jalrlsb_01 + 1) & ~1 = &jalrlsb_01
                      # SP1 target = &jalrlsb_01 + 1  (ODD -- bug!)
```

### Cascade of failures

1. SP1 sets PC = `&jalrlsb_01 + 1` (odd). `program.fetch()` computes
   `(pc - pc_base) / 4` (integer division), so it silently fetches the instruction
   at the word-aligned address. **The correct instruction executes** — only the stored
   `self.state.pc` is wrong.

2. **Jump-taken SIGUPD passes** — the `addi x3, x3, 2` at `jalrlsb_01` is fetched and
   executes, giving the correct value. Sail's reference matches. No failure here.

3. **Return-address SIGUPD fails** — `auipc x3, 0` uses the odd PC, producing a value
   1 higher than Sail's reference. `sub x30, x30, x3` is off by 1. SIGUPD mismatch.

4. `jal t0, failedtest_x5_x4` at the odd PC: encoded imm was compiled assuming even PC.
   `next_pc = odd_PC + imm = 0x20003d50 + 1 = 0x20003d51` (odd entry into handler!).

5. In `failedtest_x5_x4` at `0x20003d50`:
   ```
   auipc tp, 0x4       ; tp = PC + 0x4000 = 0x20003d51 + 0x4000 = 0x20007d51
   addi tp, tp, 688    ; tp = 0x20007d51 + 0x2b0 = 0x20008001  (should be 0x20008000)
   sw t0, 40(tp)       ; addr = 0x20008001 + 40 = 0x20008029  (should be 0x20008028)
   ```

6. **Simple mode** raises `InvalidMemoryAccess(SW, 0x20008029)` — misaligned word store.
   **Trace mode** silently accepts the misaligned write; test exits with code 1.

### Also affected

`cp_offset_lsbs_test_98` (`rs1 LSB=1, imm LSB=0`): same class of bug — computed target
is odd, SP1 doesn't clear it. But test_97 triggers the hard crash first (in simple mode),
so test_98 is never reached.

`cp_offset_lsbs_test_99` (`rs1 LSB=1, imm LSB=1`): computed target = `odd + (-1)` = even.
LSB clearing would give the same result, so SP1 accidentally passes this one.

---

## Why SP1 passed RISCOF but fails ACT4

The RISCOF jalr tests (`jalr-01.S`, `misalign1-jalr-01.S`) are **not flawed** — they
correctly detected the same missing `& ~1` bug in r0vm (RISC0) when it was present.

SP1 passed RISCOF because the RISCOF tests were run against SP1 v5, which used the
**interpreter** execution path. The interpreter correctly implements `& !1_u64`
(see `vm.rs:440` above). The bug is only in the **x86 JIT backend**, which is a
v6-only feature introduced 2025-08-11. When we upgraded to SP1 v6 for ACT4 testing,
the default execution path (`--mode node`) switched to the JIT, exposing the bug.

---

## Pico: same bug, independent codebase

Pico is **not** derived from SP1 — no SP1 dependency in Cargo.toml/Cargo.lock. The only
Succinct-related crate is `rrs-succinct` (a RISC-V ISS library, not SP1 itself).

Pico has the same missing `& !1` bug written independently in two places:

**Emulator** — `vm/src/emulator/riscv/emulator/instruction.rs:300`:
```rust
next_pc = b.wrapping_add(c);  // BUG: missing `& !1`
```

**AOT codegen** — `aot-codegen/src/instruction_translator.rs:180`:
```rust
let target = base.wrapping_add(#imm);  // BUG: missing `& !1`
emu.pc = target;
```

Both present since the initial commit `45e74cc` ("pico init commit") by Alan Li,
2025-02-11.

---

## Other ZKVMs

Under full-isa, **only SP1 and Pico** fail jalr. All others pass:
airbender, jolt, openvm, r0vm, zisk — all correctly implement `(rs1 + imm) & ~1`.

OpenVM's standard-isa suite (rv64im) shows 0/72 but that's an infrastructure issue
(OpenVM is RV32-native; the rv64 suite is unsupported), not a jalr bug.

---

## Verdict

SP1 and Pico independently have the same JALR LSB-clearing bug. SP1 passed RISCOF
because the old version (v5) used the correct interpreter; the buggy JIT is v6-only.
Pico was not tested under RISCOF. The RISCOF `misalign1-jalr-01.S` test is sound —
it correctly caught the same bug in r0vm when it was present there.
