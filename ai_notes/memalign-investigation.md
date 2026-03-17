# MemAlign Proving Failure — Root Cause Analysis

## Summary

Two bugs prevent Misalign tests from proving. Both must be fixed.

| Bug | Location | Effect | Fix |
|-----|----------|--------|-----|
| Bug 1 | `mem_helpers.rs:146` | MemAlign local constraint failure | Remove spurious `>> offset` |
| Bug 2 | `emu.rs` (multiple sites) | Global constraint failure (bus mismatch) | Use `ind_width` instead of hardcoded `8` |

## Assumes/Proves Mismatch — Full Picture

The MEMORY_ID bus permutation requires that every Main "assumes" tuple has a matching
MemAlign "proves" tuple. For the Misalign-lh-00 test (`lh` at addr `0xa0011897`, offset=7),
the concrete tuples are:

**Main assumes** (always correct — PIL constraint computes bytes=ind_width=2):
```
[LOAD_OP, 0xa0011897, step, 2, 0x0000ef00, 0x00000000]
```

### Before any fix (v0.15.0 as-is)
MemAlign proves (value corrupted by bug 1, width wrong from bug 2):
```
[LOAD_OP, 0xa0011897, step, 8, 0x00000100, 0x00000000]
```
- `bytes`: 8 ≠ 2 (bug 2: emulator hardcodes 8)
- `value[0]`: 0x00000100 ≠ 0x0000ef00 (bug 1: `>> offset` corrupts value)
- `value[1]`: matches (both 0) only by coincidence
- **Result**: MemAlign local constraints FAIL (value internally inconsistent),
  AND global constraint FAILS (tuple mismatch)

### After bug 1 fix only (get_read_value >> offset removed)
MemAlign proves (value correct for 8 bytes, but width still wrong):
```
[LOAD_OP, 0xa0011897, step, 8, 0xabcdef00, 0x23456789]
```
- `bytes`: 8 ≠ 2 (bug 2 still present)
- `value[0]`: 0xabcdef00 ≠ 0x0000ef00 (correct for 8-byte read, wrong for 2-byte)
- `value[1]`: 0x23456789 ≠ 0x00000000 (same issue)
- **Result**: MemAlign local constraints PASS (value internally consistent),
  but global constraint still FAILS (tuple mismatch on bytes and value)

### After both fixes (bug 1 + bug 2)
MemAlign proves (correct width, value correctly masked to 2 bytes):
```
[LOAD_OP, 0xa0011897, step, 2, 0x0000ef00, 0x00000000]
```
- All fields match Main's assumes tuple exactly
- **Result**: MemAlign local constraints PASS, global constraint PASSES

## The Bug

```rust
// mem_helpers.rs:141-155
pub fn get_read_value(addr: u32, bytes: u8, read_values: [u64; 2]) -> u64 {
    let is_double = Self::is_double(addr, bytes);
    let offset = Self::get_byte_offset(addr) * 8;  // offset in BITS
    let mut value = read_values[0] >> offset;
    if is_double {
        value |= (read_values[1] >> offset) << (64 - offset);  // BUG: >> offset
    }
    match bytes {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        4 => value & 0xFFFF_FFFF,
        8 => value,
        _ => panic!("Invalid bytes value"),
    }
}
```

Line 146 should be:
```rust
        value |= read_values[1] << (64 - offset);
```

The extra `>> offset` on `read_values[1]` destroys the low bits of the second aligned word before they are shifted into position.

## Proof of Bug

Concrete example from the Misalign-lh-00 test:
- **addr:** `0xa0011897` → byte offset = 7, bit offset = 56
- **read_values[0]:** `0x0011223344556677`
- **read_values[1]:** `0x0123456789ABCDEF`

**Buggy computation:**
```
value = 0x0011223344556677 >> 56           = 0x00
value |= (0x0123456789ABCDEF >> 56) << 8   = (0x01) << 8 = 0x100
Result: 0x0000000000000100 = 256           ← WRONG
```

**Correct computation:**
```
value = 0x0011223344556677 >> 56           = 0x00
value |= 0x0123456789ABCDEF << 8            = 0x23456789ABCDEF00
Result: 0x23456789ABCDEF00                 ← CORRECT
```

The correct value is the 8 bytes starting at byte 7: `[0x00, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23]` in LE = `0x23456789ABCDEF00`.

## Constraint Failure Chain

```
get_read_value() returns wrong value (0x100 instead of 0x23456789ABCDEF00)
    │
    ▼
MemAlignInput.value = 0x100  (but mem_values are correct)
    │
    ▼
TwoReads witness: value_row.reg = rotated bytes of 0x100
                 = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    │
    ▼
second_read_row.reg = bytes of mem_values[1]
                    = [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01]
    │
    ▼
PIL constraint (mem_align.pil:117):
  ('reg[i] - reg[i]) * sel[i] * sel_down_to_up === 0
  Requires value_row.reg[0..6] == second_read_row.reg[0..6]
  0x01 ≠ 0xEF, 0x00 ≠ 0xCD, etc.
    │
    ▼
"Invalid evaluations" — MemAlign Instance #0 not verified
```

## Investigation Details

### Failing Constraint
- **PIL file:** `mem_align.pil:117`
- **Constraint:** `('reg[i] - reg[i]) * sel[i] * sel_down_to_up === 0`
- **Meaning:** In a V→R2 transition (down_to_up), registers at selected positions must be preserved
- **Fails at:** Row 28 of the MemAlign witness, constraints #1, #3, #5, #7, #9, #11, #13 (reg[0] through reg[6])
- **Passes:** reg[7] (sel[7]=0, so constraint is trivially satisfied)

### The Only TwoReads Operation
Out of 39 total MemAlign operations (22 OneRead + 16 OneWrite + 1 TwoReads), only ONE triggers the TwoReads path. This is a width=8 read at address `0xa0011897` (offset=7), which requires two aligned word reads.

The `sel_down_to_up=1` flag only appears in TwoReads/TwoWrites operations, so this single operation is the sole source of constraint failures.

### Why Only Misalign Tests Fail
- Misalign tests exercise memory accesses at non-8-byte-aligned addresses with widths that can span two aligned words
- When `offset + width > 8`, the MemAlign SM uses the TwoReads/TwoWrites path, triggering the bug in `get_read_value()`
- Non-misalign tests use OneRead/OneWrite (single aligned word) where `is_double=false`, so the buggy branch is never taken
- Tests with `offset=0` or small enough `offset+width ≤ 8` also avoid the bug

### Row Count Breakdown
Total MemAlign rows: 120 = 22×2 (OneRead) + 16×3 (OneWrite) + 1×3 (TwoReads) + padding
- The 22 OneReads are mostly width=1 byte accesses from the UART output loop (reading ASCII characters to print "PASSED")
- The 16 OneWrites are the corresponding UART byte writes
- The 1 TwoReads is the width=8 read at offset=7 (likely from a doubleword comparison/verification instruction in the test framework)

## Debugging Methodology

### Tools Used
1. **`cargo-zisk verify-constraints`** — Identified failing constraint IDs and row numbers
2. **`debug_mem_align` feature flag** — Enabled per-operation witness tracing
3. **Manual constraint evaluation** — Verified the register mismatch

### Build Steps for Debug Binary
```bash
# 1. Checkout v0.15.0
cd /home/cody/zisk && git checkout v0.15.0

# 2. Enable debug_mem_align in state-machines/mem/Cargo.toml
# Change: default = [] → default = ["debug_mem_align"]

# 3. Build (needs Intel OpenMP library path)
LIBRARY_PATH=/opt/intel/oneapi/compiler/2025.0/lib:$LIBRARY_PATH \
  cargo build --release -p cargo-zisk

# 4. Copy binary and witness library
cp target/release/cargo-zisk /path/to/binaries/cargo-zisk-debug
cp target/release/libzisk_witness.so /path/to/binaries/libzisk_witness-debug.so

# 5. Run with debug witness library (needs Rust stdlib in path)
RUST_LOG=debug \
LD_LIBRARY_PATH=/home/cody/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib:binaries/zisk-lib \
  binaries/cargo-zisk-debug verify-constraints \
  --elf test.elf --witness-lib binaries/libzisk_witness-debug.so --emulator -vv
```

## Bug Report (for upstream Zisk)

**Title:** `get_read_value()` incorrectly shifts second word in double-word reads, causing MemAlign proving failures

**Description:** `MemHelpers::get_read_value()` in `state-machines/mem-common/src/mem_helpers.rs:146` has an extra `>> offset` on `read_values[1]` that corrupts the reconstructed value for reads spanning two aligned 64-bit words. This causes the value passed to the MemAlign state machine to disagree with the actual memory contents, violating the register-preservation constraint (`mem_align.pil:117`) during proof verification.

**Reproduction:** Run `cargo-zisk prove --verify-proofs` on any Misalign ACT4 compliance test (lh, lhu, lw, lwu, ld, sh, sw, sd). All 8 fail with "Invalid evaluations" on the MemAlign instance.

**Fix:** Line 146 should be `value |= read_values[1] << (64 - offset);` (remove the `>> offset`).

## Patch Validation (2026-03-13)

Applied the one-line fix to v0.15.0 and ran `verify-constraints` on Misalign-lh-00:

| | Unpatched | Patched |
|---|---|---|
| MemAlign local constraints | **FAIL** (row 28, 7 constraints) | **PASS** |
| Global constraint #0 | FAIL | FAIL (pre-existing) |
| All other SMs (Main, Rom, Binary, Mem, etc.) | PASS | PASS |

Sanity check on I-add-00 (non-Misalign test): all local AND global constraints pass with the patched binary. The fix does not affect non-double-word reads.

The global constraint #0 failure is **pre-existing** and independent of this bug — it fails identically on both patched and unpatched v0.15.0. This is likely a separate bus grand-sum issue in the Misalign test suite.

### Build & Test Commands
```bash
# Build patched v0.15.0
cd /home/cody/zisk && git checkout v0.15.0
# Apply fix: remove ">> offset" from line 146 of mem_helpers.rs
LIBRARY_PATH=/opt/intel/oneapi/compiler/2025.0/lib:$LIBRARY_PATH cargo build --release -p cargo-zisk

# Test
LD_LIBRARY_PATH=/home/cody/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/lib/rustlib/x86_64-unknown-linux-gnu/lib:binaries/zisk-lib \
  binaries/cargo-zisk-patched verify-constraints \
  --elf test-results/zisk/elfs/target/rv64i/Misalign/Misalign-lh-00.elf \
  --witness-lib binaries/libzisk_witness-patched.so --emulator -vv
```

### Note on Proving Keys
The fix is purely in witness generation code (`mem_helpers.rs`), not in PIL constraints (the circuit). The existing v0.15.0 proving keys work without regeneration.

## Bug 2: Emulator Sends Wrong `bytes` for Double-Word Misaligned Loads

### Summary
The emulator hardcodes `bytes=8` in the bus payload for double-word misaligned loads, but Main's PIL constraint sends `bytes=ind_width`. This causes a permutation mismatch on the MEMORY_ID bus, failing Global Constraint #0.

### The Bug
In `emulator/src/emu.rs`, the double-word misaligned case for source B (and source A, and stores) always sends `bytes=8`:

```rust
// emu.rs ~line 834 (double-word case for source B)
let payload = MemHelpers::mem_load(
    address as u32,
    self.ctx.inst_ctx.step,
    1,
    8,                          // BUG: should be instruction.ind_width as u8
    [raw_data_1, raw_data_2],
);
```

Compare with the single-word unaligned case (~line 813) which correctly uses `instruction.ind_width as u8`.

### Why It Fails
Main's PIL (main.pil:301) sends `bytes = b_src_ind * (ind_width - 8) + 8 = ind_width` (e.g., 2 for `lh`).
MemAlign's PIL (mem_align.pil:189) sends `width` from the witness, which is 8 (from the bus data).

The permutation on MEMORY_ID bus:
- Main assumes: `[LOAD_OP, addr, step, 2, ...]`
- MemAlign proves: `[LOAD_OP, addr, step, 8, ...]`

`2 ≠ 8` → grand-sum doesn't balance → Global Constraint #0 invalid.

### Affected Cases
Only sub-8-byte loads/stores that span two aligned 8-byte words:
- `lh`/`lhu` at offset 7
- `lw`/`lwu` at offset 5, 6, 7
- `sh` at offset 7
- `sw` at offset 5, 6, 7
- `ld`/`sd` with bytes=8 are NOT affected (8 == 8)

### Fix Locations
Multiple places in `emu.rs` where `MemHelpers::mem_load()` or `MemHelpers::mem_write()` is called with hardcoded `8` for double-word cases. Should use `instruction.ind_width as u8` instead.

Additionally, `get_read_value()` in `mem_helpers.rs` and `MemAlignInput.width` in the collector need to receive the correct `ind_width` (not 8) for the value masking and MemAlign witness generation to be consistent.

### Interaction with Bug 1
Both bugs must be fixed for Misalign proving to work:
- Bug 1 alone: MemAlign local constraints pass, but global constraint still fails (bytes and value mismatch)
- Bug 2 alone: global constraint would pass for bytes field, but MemAlign local constraints still fail (corrupted value)
- Both fixes together: MemAlign local constraints pass AND global constraint passes

See the "Assumes/Proves Mismatch" section at the top for concrete tuple values at each stage.
