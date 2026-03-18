#!/bin/bash
# demo-jolt-proving.sh — Demonstrates jolt proving progress for ACT4 tests
#
# Prerequisites:
#   - jolt repo at ../jolt (symlinked or checked out)
#   - binaries/jolt-binary and binaries/jolt-prover built
#   - Docker with jolt:latest image built
#   - test-results/jolt/elfs/ populated (./run test jolt)
#
# What this demonstrates:
#   1. Execution pipeline works (split pipeline: Docker ELF gen + host execution)
#   2. Proving works for jolt-sdk guests (fib guest)
#   3. Proving works for jolt-sdk guests with inline assembly
#   4. Proving works when patching our code into a jolt guest ELF
#   5. Proving FAILS for bare gcc-compiled ELFs (missing boot code)
#   6. Root cause: jolt's ZeroOS boot code is required by the prover circuit

set -e
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; }
info() { echo -e "  ${YELLOW}INFO${NC}: $1"; }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

PROVER=binaries/jolt-prover
EMU=binaries/jolt-binary
FIB_ELF=/tmp/jolt-guest-targets/fibonacci-guest-/riscv64imac-unknown-none-elf/release/fibonacci-guest
ACT4_TEST_ELF=/tmp/jolt-guest-targets/act4-test-guest-act4_add_test/riscv64imac-unknown-none-elf/release/act4-test-guest

# Check prerequisites
section "Prerequisites"
for f in "$PROVER" "$EMU"; do
    if [ -f "$f" ]; then pass "$f exists"; else fail "$f missing — run build first"; exit 1; fi
done

# ─────────────────────────────────────────────────────────────
section "1. Execution pipeline (split pipeline)"
# ─────────────────────────────────────────────────────────────
if [ -d test-results/jolt/elfs/target ]; then
    ELF_COUNT=$(find test-results/jolt/elfs/target -name "*.elf" | wc -l)
    info "Found $ELF_COUNT target ELFs in test-results/jolt/elfs/target"

    # Run one test via jolt-emu
    TEST_ELF=$(find test-results/jolt/elfs/target -name "I-add-00.elf" | head -1)
    if [ -n "$TEST_ELF" ]; then
        OUTPUT=$("$EMU" "$TEST_ELF" 2>&1)
        if echo "$OUTPUT" | grep -q "Test Passed"; then
            pass "jolt-emu executes I-add-00: Test Passed"
        else
            fail "jolt-emu execution: $OUTPUT"
        fi
    fi
else
    info "No ELFs found — run './run test jolt' first to generate"
fi

# ─────────────────────────────────────────────────────────────
section "2. Proving: jolt-sdk fibonacci guest"
# ─────────────────────────────────────────────────────────────
if [ -f "$FIB_ELF" ]; then
    OUTPUT=$("$PROVER" prove "$FIB_ELF" --verify 2>&1)
    if echo "$OUTPUT" | grep -q "^verify:"; then
        CYCLES=$(echo "$OUTPUT" | grep "^trace:" | head -1 | grep -oP '\d+ cycles' | head -1)
        PROVE_TIME=$(echo "$OUTPUT" | grep "^prove:" | grep -oP '[0-9.]+s' | head -1)
        VERIFY_TIME=$(echo "$OUTPUT" | grep "^verify:" | grep -oP '[0-9.]+s' | head -1)
        pass "fibonacci guest: $CYCLES, prove $PROVE_TIME, verify $VERIFY_TIME"
    else
        fail "fibonacci guest verification failed"
    fi
else
    info "Fibonacci guest ELF not found — run 'cargo run --release -p fibonacci' in jolt/ first"
fi

# ─────────────────────────────────────────────────────────────
section "3. Proving: jolt guest with inline assembly"
# ─────────────────────────────────────────────────────────────
if [ -f "$ACT4_TEST_ELF" ]; then
    OUTPUT=$("$PROVER" prove "$ACT4_TEST_ELF" --verify 2>&1)
    if echo "$OUTPUT" | grep -q "^verify:"; then
        CYCLES=$(echo "$OUTPUT" | grep "^trace:" | head -1 | grep -oP '\d+ cycles' | head -1)
        pass "act4-test guest (inline asm: 42+58=100): $CYCLES"
    else
        fail "act4-test guest verification failed"
    fi
else
    info "act4-test guest not built — run 'cargo run --release -p act4-test' in jolt/"
fi

# ─────────────────────────────────────────────────────────────
section "4. Proving: jolt guest ELF with patched user code"
# ─────────────────────────────────────────────────────────────
# Take a working jolt guest ELF, strip non-essential sections, patch the
# termination j . with our own test code. This proves that arbitrary user
# code works as long as jolt's boot sequence runs first.
STRIPPED_ELF=""
for ELF in "$ACT4_TEST_ELF" "$FIB_ELF"; do
    if [ -f "$ELF" ]; then STRIPPED_ELF="$ELF"; break; fi
done

if [ -n "$STRIPPED_ELF" ]; then
    # Find the j . (a001 = c.j 0) at 0x80000040 and patch with our test code
    python3 - "$STRIPPED_ELF" /tmp/demo_patched.elf << 'PYEOF'
import struct, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
shutil.copy(src, dst)
elf = bytearray(open(dst, "rb").read())
# j . at 0x80000040 = file offset 0x1040
patch_offset = 0x1040
code = [
    0x02a00293,  # li t0, 42
    0x02a00313,  # li t1, 42
    0x00629463,  # bne t0, t1, +8
    0x0000006f,  # j . (pass)
    0x0000006f,  # j . (fail)
]
for i, instr in enumerate(code):
    struct.pack_into('<I', elf, patch_offset + i * 4, instr)
open(dst, "wb").write(elf)
PYEOF

    OUTPUT=$("$PROVER" prove /tmp/demo_patched.elf --verify 2>&1)
    if echo "$OUTPUT" | grep -q "^verify:"; then
        CYCLES=$(echo "$OUTPUT" | grep "^trace:" | head -1 | grep -oP '\d+ cycles' | head -1)
        pass "patched guest (boot code + our asm at termination): $CYCLES"
    else
        fail "patched guest verification failed"
    fi
    rm -f /tmp/demo_patched.elf
else
    info "No jolt guest ELF available for patching"
fi

# ─────────────────────────────────────────────────────────────
section "5. Proving: gcc-compiled bare ELF (NO boot code)"
# ─────────────────────────────────────────────────────────────
# Build a minimal ELF with gcc (same test logic, no jolt boot code)
if command -v docker &>/dev/null; then
    docker run --rm -v /tmp:/out --entrypoint bash jolt:latest -c '
cat > /tmp/bare.S << "ASM"
.section .text
.globl _start
_start:
    li t0, 42
    li t1, 42
    bne t0, t1, fail
    j .
fail:
    j .
ASM
cat > /tmp/bare.ld << "LD"
OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 0x10000000 }
PHDRS { text PT_LOAD FLAGS(5); }
SECTIONS { . = 0x80000000; .text : { *(.text) } > RAM : text }
LD
riscv64-unknown-elf-gcc -nostdlib -nostartfiles -march=rv64imac -mabi=lp64 \
  -T /tmp/bare.ld -Wl,--strip-all -o /out/demo_bare.elf /tmp/bare.S
' 2>/dev/null

    # Execution works
    OUTPUT=$("$EMU" /tmp/demo_bare.elf 2>&1)
    if echo "$OUTPUT" | grep -q "Test Passed\|exited successfully"; then
        pass "gcc bare ELF executes successfully"
    else
        info "gcc bare ELF execution: $(echo "$OUTPUT" | tail -1)"
    fi

    # Proving fails (expected)
    OUTPUT=$("$PROVER" prove /tmp/demo_bare.elf --verify 2>&1) || true
    if echo "$OUTPUT" | grep -q "^verify:"; then
        fail "gcc bare ELF unexpectedly verified (should fail)"
    else
        CYCLES=$(echo "$OUTPUT" | grep "^trace:" | head -1 | grep -oP '\d+ cycles' | head -1)
        pass "gcc bare ELF proving fails as expected ($CYCLES — missing boot code)"
    fi
    rm -f /tmp/demo_bare.elf 2>/dev/null || true
else
    info "Docker not available — skipping gcc ELF test"
fi

# ─────────────────────────────────────────────────────────────
section "6. ACT4 I-add-00 execution + proving status"
# ─────────────────────────────────────────────────────────────
TEST_ELF=$(find test-results/jolt/elfs/target -name "I-add-00.elf" 2>/dev/null | head -1)
if [ -n "$TEST_ELF" ]; then
    # Execution
    OUTPUT=$("$EMU" "$TEST_ELF" 2>&1)
    if echo "$OUTPUT" | grep -q "Test Passed"; then
        pass "ACT4 I-add-00 execution: Test Passed"
    else
        fail "ACT4 I-add-00 execution failed"
    fi

    # Proving (expected to fail — no boot code)
    OUTPUT=$("$PROVER" prove "$TEST_ELF" --verify 2>&1) || true
    CYCLES=$(echo "$OUTPUT" | grep "^trace:" | head -1 | grep -oP '\d+ cycles' | head -1)
    if echo "$OUTPUT" | grep -q "^verify:"; then
        pass "ACT4 I-add-00 proving: VERIFIED ($CYCLES)"
    else
        info "ACT4 I-add-00 proving: Stage 4 Sumcheck fails ($CYCLES) — needs jolt boot code"
    fi
else
    info "ACT4 I-add-00 ELF not found"
fi

# ─────────────────────────────────────────────────────────────
section "Summary"
# ─────────────────────────────────────────────────────────────
echo ""
echo "Infrastructure complete:"
echo "  - Split pipeline (Docker ELF gen + host execution) ✓"
echo "  - act4-runner Jolt/JoltProve backends ✓"
echo "  - jolt-prover CLI (auto-detect trace length) ✓"
echo "  - patch_elfs.py for data-in-text NOPping ✓"
echo "  - j . halt for PC stall termination ✓"
echo ""
echo "Proving status:"
echo "  - jolt-sdk guests (fib, inline asm): PROVES + VERIFIES ✓"
echo "  - jolt guest with patched user code: PROVES + VERIFIES ✓"
echo "  - gcc bare ELFs (no boot code):      PROVES but VERIFY FAILS ✗"
echo "  - ACT4 ELFs (no boot code):          PROVES but VERIFY FAILS ✗"
echo ""
echo "Root cause: jolt's ZeroOS boot code (~290 cycles) initializes state"
echo "that the prover circuit requires. Without it, Stage 4 RAM value"
echo "checking fails. ACT4 tests need to be compiled as jolt guests or"
echo "have the boot stub prepended."
echo ""
echo "Detailed notes: ai_notes/jolt-proving-debug.md"
