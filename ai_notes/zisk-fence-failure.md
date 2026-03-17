# Zisk FENCE Test Failure Analysis

## Summary

Zisk fails the ACT4 `I-fence-00` test because its RISC-V decoder rejects
reserved FENCE encodings that the spec requires to execute as NOPs. The old
RISCOF `fence-01.S` test only used a single standard `fence` instruction and
passed. ACT4 added test cases for reserved/hint FENCE encodings, exposing a
bug in Zisk's overly strict decoder.

## The Failure

```
$ ziskemu --elf I-fence-00.elf
Emu::run() finished with error at step=588 pc=0x8000024c
```

Disassembly at the failing PC:

```
80000248:  8330000f    fence.tso

8000024c <I_fence_cg_cp_custom_fence_reserved_fences>:
8000024c:  0331000f    .word 0x0331000f    # fence with nonzero rs1
80000250:  0330008f    .word 0x0330008f    # fence with nonzero rd
80000254:  1330000f    .word 0x1330000f    # fence with reserved fm
...
```

The first reserved encoding (`0x0331000f`) is where ziskemu halts with an error.

## Root Cause: Overly Strict Decoder Mask

In `riscv/src/riscv_interpreter.rs`, function `riscv_get_instruction_32`:

```rust
} else if i.t == *"F" {
    i.funct3 = (inst & 0x7000) >> 12;
    if i.funct3 == 0 {
        if (inst & 0xF00F8F80) != 0 {
            i.inst = "reserved".to_string();
        } else {
            i.pred = (inst & 0x0F000000) >> 24;
            i.succ = (inst & 0x00F00000) >> 20;
            i.inst = "fence".to_string();
        }
    }
```

The mask `0xF00F8F80` requires these fields to be zero:

| Field | Bits    | Mask bits    | What the mask enforces        |
|-------|---------|--------------|-------------------------------|
| fm    | [31:28] | `0xF0000000` | Must be `0000`                |
| rs1   | [19:15] | `0x000F8000` | Must be `x0`                  |
| rd    | [11:7]  | `0x00000F80` | Must be `x0`                  |

Any FENCE with non-zero fm, rs1, or rd is tagged `"reserved"`, which the
transpiler (`riscv2zisk_context.rs`) maps to `halt_with_error`:

```rust
"reserved" => self.halt_with_error(riscv_instruction, 4),
```

Meanwhile, a standard `fence` is transpiled to a NOP:

```rust
"fence" => self.nop(riscv_instruction, 4),
```

## What the RISC-V Spec Says

The RISC-V unprivileged spec (Section 2.7, "Memory Ordering Instructions")
states that reserved FENCE encodings must not trap:

- **Non-zero rs1 or rd with fm=0**: These are FENCE *hints*. They must execute
  as a standard FENCE (future extensions may give them additional semantics).
- **Reserved fm values** (not `0000` or `1000`): Must be treated as if fm=0000.
- **FENCE.TSO with non-standard pred/succ**: Must behave as a regular FENCE.

In all cases, the instruction must execute without trapping. Implementations are
free to ignore the ordering semantics (as Zisk does for standard FENCE by
treating it as a NOP), but they must not raise exceptions.

## Impact on ACT4 Test Encodings

The ACT4 `I-fence-00.S` test case 3 exercises 10 reserved encodings:

| Encoding     | Description                          | ZisK |
|-------------|--------------------------------------|------|
| `0x0331000f` | fence with nonzero rs1               | REJECTED (rs1) |
| `0x0330008f` | fence with nonzero rd                | REJECTED (rd) |
| `0x1330000f` | fence with reserved fm               | REJECTED (fm) |
| `0x0031000f` | hint: rs1!=x0, pred=0                | REJECTED (rs1) |
| `0x0301000f` | hint: rs1!=x0, succ=0                | REJECTED (rs1) |
| `0x0030008f` | hint: rd!=x0, pred=0                 | REJECTED (rd) |
| `0x0300008f` | hint: rd!=x0, succ=0                 | REJECTED (rd) |
| `0x0020000f` | hint: pred=0, succ!=0                | accepted |
| `0x0200000f` | hint: pred!=W, succ=0                | accepted |
| `0x8110000f` | FENCE.TSO with R,R instead of RW,RW  | REJECTED (fm) |

8 of 10 are rejected. Execution halts at the first one (`0x0331000f`).

## Why the Old Test Passed

The RISCOF `fence-01.S` test (from `old-framework-2.x` branch of riscv-arch-test)
was trivial:

```asm
sw x8, 0(x9)
sw x7, 4(x9)
fence              # ← standard encoding: 0x0FF0000F
lw x3, 0(x9)
lw x4, 4(x9)
```

This only used the canonical `fence rw, rw` (`0x0FF0000F`) which has fm=0,
rs1=x0, rd=x0 — all zero under the mask. No reserved encodings were tested.

ACT4's `I-fence-00.S` replaced this with three test cases:
1. Standard `fence` / `fence rw, rw`
2. `fence.tso`
3. Reserved/hint FENCE encodings (the ones that fail)

## Suggested Fix (Upstream)

In `riscv_interpreter.rs`, remove the mask check and unconditionally decode
FENCE as a NOP:

```rust
if i.funct3 == 0 {
    i.pred = (inst & 0x0F000000) >> 24;
    i.succ = (inst & 0x00F00000) >> 20;
    i.inst = "fence".to_string();
}
```

Since `fence` is already transpiled to a NOP (`self.nop()`), non-zero fm/rs1/rd
fields have no effect — they just need to not cause a halt. The same applies to
`fence.i` (funct3=1), which has a similar overly strict mask (`0xFFFF8F80`).

## Secondary Issue: Inconsistent Reporting

The native and target suites report this failure differently due to using
different act4-runner backends:

- **Native suite** (`--zkvm zisk`): Uses `run_zisk()` which discards stderr
  and only checks the exit code. Since ziskemu exits 0, it reports **passed**
  (false positive).
- **Target suite** (`--zkvm zisk-prove`): Uses `run_zisk_prove()` which also
  checks stderr for "finished with error". It correctly reports **failed**.

The `run_zisk()` backend should be updated to check stderr, matching
`run_zisk_prove()` behavior.
