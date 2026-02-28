# SP1/Pico ACT4 I-jalr-00 Failure Analysis

## Summary

SP1 and Pico both fail 2 of 47 native ACT4 tests: `I-fence-00` and `I-jalr-00`.
Both passed `jalr-01.S` and `misalign1-jalr-01.S` in RISCOF. This is new coverage,
not a regression.

---

## I-fence-00

SP1 returns `Unimplemented` for the FENCE instruction. Trivial — SP1 simply doesn't
implement FENCE.

---

## I-jalr-00

**Root cause**: SP1's JALR implementation does not clear bit 0 of the computed target
address, violating the RISC-V specification.

### SP1 executor bug

`crates/core/executor/src/executor.rs:1686` (in `/tmp/sp1-clean`):
```rust
Opcode::JALR => {
    let (rd, rs1, imm) = instruction.i_type();
    let (b, c) = (self.rr_cpu(rs1, MemoryAccessPosition::B), imm);
    let a = self.state.pc + 4;
    self.rw_cpu(rd, a);
    let next_pc = b.wrapping_add(c);  // BUG: missing `& !1`
    (a, b, c, next_pc)
}
```

The RISC-V spec requires `next_pc = (rs1 + imm) & ~1`. SP1 omits `& !1`.

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

## Why RISCOF didn't catch this

### `jalr-01.S` — LSB never set in any test case

RISCOF's `TEST_JALR_OP` macro with `adj=0` always pre-adjusts rs1 so that
`rs1 + imm` lands exactly on the 4-byte-aligned label `3f`. Even `inst_2` with `imm=1`
uses `LA(rs1, 3f - 1)`, making the computed target `3f` (even). The LSB is never set,
so SP1's missing LSB clearing has no effect.

### `misalign1-jalr-01.S` — `andi ~3` accidentally absorbs the bug

The one test case is `TEST_JALR_OP(x2, x11, x10, -0x21, x1, 0, 1)` with `adj=1`.
The macro expands (for `adj & 1 == 1`) to:

```asm
5: auipc x11, 0
   LA(x10, 3f + 0x21)          ; x10 = 3f + 0x21
   jalr x11, -0x20(x10)         ; target = (3f + 0x21) - 0x20 = 3f + 1  (ODD)
   nop / xori ... / j 4f        ; not-taken path
3: xori x11, x11, 0x3           ; taken path
   j 4f
4: LA(x2, 5b)                   ; x2 = &label_5 via auipc+addi
   andi x2, x2, ~3              ; ← mask lower 2 bits
   sub x11, x11, x2
   RVTEST_SIGUPD(x1, x11, 0)
```

Tracing SP1 through this:

1. JALR sets `next_pc = 3f + 1` (odd, no LSB clearing)
2. `fetch(3f+1)`: `(3f+1 - base)/4 = (3f - base)/4` (integer division) → fetches
   instruction **at 3f** (the correct one). Executes normally.
3. Odd PC propagates: `j 4f` executes at odd PC, jumps to `4f + 1`.
4. At `4f+1`: LA's `auipc` computes `&5b + 1` (off by 1 because PC is odd).
5. **`andi x2, x2, ~3`** masks bits 1:0: `(&5b + 1) & ~3 = &5b` (since `&5b` is
   4-byte aligned, bit 0 = 0, so `+1` then `& ~3` gives back `&5b`).
6. `sub x11, x11, x2` produces the **exact same result as a conformant implementation**.
7. Signature matches Sail → **PASS** — but for the wrong reason.

The `andi ~3` is part of RISCOF's position-independence technique (normalising the return
address relative to the instruction's PC). It accidentally absorbs SP1's off-by-1 error
whenever the label address is 4-byte aligned.

### ACT4 catches it

ACT4's `cp_offset_lsbs_test_97` uses a direct `beq` comparison against Sail's
precomputed expected value. There is no `andi ~3` step. The off-by-1 in the normalised
return address is directly visible:

```asm
auipc x3, 0          ; x3 = SP1's odd PC (off by 1)
sub x30, x30, x3     ; x30 is off by 1 from Sail's reference
RVTEST_SIGUPD(...)   ; beq fails → jal to failedtest → crash
```

---

## Verdict

SP1/Pico have always had this JALR LSB-clearing bug. RISCOF's test design (signature
comparison + `andi ~3` normalisation) inadvertently masked it. ACT4's `cp_offset_lsbs`
tests are genuinely new coverage exposing a real non-conformance.

| | RISCOF | ACT4 |
|---|---|---|
| JALR with odd target | Never tested (always pre-aligns to 4-byte boundary) | Explicitly tested (`cp_offset_lsbs` tests 97–99) |
| `misalign1-jalr` with odd target | Tests it, but `andi ~3` accidentally cancels SP1's off-by-1 PC error | N/A |
| Check method | Byte-for-byte signature comparison | Direct `beq` against Sail reference |
