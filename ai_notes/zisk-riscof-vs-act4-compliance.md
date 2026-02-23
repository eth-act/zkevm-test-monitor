# Zisk: RISCOF Failures vs ACT4 — Compliance Analysis

## The 11 RISCOF Failures

All are in `rv64i_m/C` or `rv64i_m/privilege/`:

| Test | Category |
|------|----------|
| `rv64i_m/C/cebreak-01.S` | Compressed ebreak |
| `rv64i_m/privilege/ebreak.S` | ebreak trap |
| `rv64i_m/privilege/ecall.S` | ecall trap |
| `rv64i_m/privilege/misalign-ld-01.S` | misaligned LD |
| `rv64i_m/privilege/misalign-lh-01.S` | misaligned LH |
| `rv64i_m/privilege/misalign-lhu-01.S` | misaligned LHU |
| `rv64i_m/privilege/misalign-lw-01.S` | misaligned LW |
| `rv64i_m/privilege/misalign-lwu-01.S` | misaligned LWU |
| `rv64i_m/privilege/misalign-sd-01.S` | misaligned SD |
| `rv64i_m/privilege/misalign-sh-01.S` | misaligned SH |
| `rv64i_m/privilege/misalign-sw-01.S` | misaligned SW |

All fail because Zisk does not implement M-mode trap infrastructure: misaligned
accesses are handled transparently in hardware, and ecall/ebreak do not write
exception state into machine-mode CSRs.

## Are There Zicsr Tests in RISCOF?

No. Despite `zisk_isa.yaml` declaring `RV64IMAFDCZicsr`, there is no
`rv64i_m/Zicsr/` directory in the RISCOF test run. The 11 failures are all
privilege/exception tests, not CSR instruction tests. The `fcsr` register
(which is the actual Zicsr dependency for F/D) is implicitly exercised by the
662 passing F/D tests.

## Full RISCOF Test Breakdown (2026-01-28 run)

| Extension | Tests | Pass | Fail |
|-----------|-------|------|------|
| rv32i_m/F | 342 | 342 | 0 |
| rv32i_m/D | 151 | 151 | 0 |
| rv64i_m/C | 35 | 34 | 1 (cebreak) |
| rv64i_m/I | 51 | 51 | 0 |
| rv64i_m/M | 13 | 13 | 0 |
| rv64i_m/A | 18 | 18 | 0 |
| rv64i_m/F | 18 | 18 | 0 |
| rv64i_m/D | 27 | 27 | 0 |
| rv64i_m/privilege | 18 | 8 | 10 |
| **Total** | **673** | **662** | **11** |

## Does the Spec Require M-Mode for F/D?

### The normative F→Zicsr dependency

`riscv-isa-manual/src/f-st-ext.adoc`, line 10:

> `[#norm:f_depends_zicsr]` The F extension depends on the "Zicsr" extension
> for control and status register access.

F/D formally depends on Zicsr. Zisk satisfies this — `fcsr` works (662 passing
F/D tests). **But Zicsr ≠ M-mode exception handling.**

### The RVI20 profile (the key)

`ctp/src/profiles.adoc`:

> RV{32/64}IMAFDC_Zifencei_Zicntr_Zihpm with **no Sm machine mode, no PMP**.
> Zicsr instructions only access counters and floating-point CSRs.

The CTP profile matrix confirms F/D and M-mode exceptions are orthogonal
requirements:

| Coverage | RVI20 | MC100+ |
|---|---|---|
| F, D | optional | optional/required |
| ExceptionsSm | — | **x** |
| ExceptionsF | — | **x** |

The CTP even explains the ecall gap explicitly:
> "Although the RVI20 profile states that ecall causes a trap to the execution
> environment, it also says that Zicsr instructions are not supported independent
> of the Zicntr or F instructions, so there is no way to control mtvec and write
> a trap handler. Therefore **ecall is not exercised**."

So the 11 RISCOF failures (ecall, ebreak, misalign-*) are exactly the M-mode
exception tests that are **not required for RVI20**. A ZK-VM implementing F/D
with hardware-handled misalignment and no machine-mode trap infrastructure is a
valid RVI20 implementation.

## Example: RISCOF Test Not in ACT4

**`rv64i_m/privilege/misalign-lw-01.S`**

RISCOF tests: execute a misaligned `lw`, expect the CPU to raise a Load Address
Misaligned exception, write `mcause=4`, `mepc`, `mtval` into CSRs via M-mode
trap handler, then capture that state into the signature. Fails for Zisk because
no trap occurs — Zisk handles it transparently.

ACT4 tests instead (Misalign suite, 8 tests in target suite): execute misaligned
loads/stores and verify the **result value is correct**. No trap expected.
Passes 8/8.

These test the same underlying property from opposite angles. For a ZK-VM,
hardware-handled misalignment is the correct and desired behavior; the RISCOF
test is verifying M-mode exception infrastructure that ZK-VMs don't need.

Similarly, `ecall.S` and `ebreak.S`: RISCOF tests trap-and-CSR behavior. In
ACT4, every single test terminates via ecall (a7=93), so correct ecall dispatch
is implicitly verified 180+ times per run.

## The Correctness Issue with Our ACT4 Profile Declaration

The Zisk native ACT4 profile (`config/zisk/zisk-rv64im/zisk-rv64im.yaml`) lists
`Sm: 1.12.0` in `implemented_extensions`. This is inconsistent — if you claim
`Sm`, you're implying `ExceptionsSm` should pass, but it can't because Zisk
doesn't implement M-mode trap infrastructure.

The ACT4 **target** suite (`zisk-rv64im-zicclsm`, 72/72 pass) gets this right:
it scopes to `Zicclsm` (hardware-handled misalignment) rather than `Sm`, which
is exactly the RVI20 + Zicclsm baseline — the honest compliance claim for a
ZK-VM.

**Recommended fix**: Remove `Sm` from the Zisk native profile's
`implemented_extensions`. Replace with a comment that Zicsr is implemented in
the limited RVI20 sense (fcsr access only, no M-mode trap CSRs). This makes the
declared ISA match what the tests actually verify.
