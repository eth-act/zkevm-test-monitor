#!/usr/bin/env python3
"""Wrap ACT4 ELFs with jolt ZeroOS boot code for proving compatibility.

Uses objcopy to add a .text.boot section at a high address, then patches
the ELF entry point and the boot code's termination jump.

Usage:
    python3 wrap_boot.py <boot.bin> <elf_directory>
"""

import glob
import os
import struct
import subprocess
import sys
import tempfile

# Address where boot code will be placed
BOOT_VADDR = 0x80100000


def get_symbol_address(elf_path: str, symbol: str) -> int | None:
    """Get address of a symbol from ELF using nm."""
    result = subprocess.run(
        ["riscv64-unknown-elf-nm", elf_path],
        capture_output=True, text=True
    )
    for line in result.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) >= 3 and parts[2] == symbol:
            return int(parts[0], 16)
    return None


def wrap_elf(elf_path: str, boot_bin: bytes) -> bool:
    """Wrap a single ELF with boot code. Returns True on success."""
    # Get test entry point
    test_entry = get_symbol_address(elf_path, "rvtest_entry_point")
    if test_entry is None:
        return False

    # Find the exit-point j . in boot code.
    # The boot code has multiple j . (c.j 0 = 0xa001): dead code at 0x40,
    # normal exit at 0xe3a (after writing termination bit), error handler at 0x1660.
    # We patch the SECOND one (0xe3a) — the normal exit after main() returns.
    boot = bytearray(boot_bin)
    j_dot_positions = []
    for i in range(0, len(boot) - 1, 2):
        if boot[i] == 0x01 and boot[i + 1] == 0xa0:
            j_dot_positions.append(i)
    if len(j_dot_positions) < 2:
        print(f"  Warning: expected >=2 j . in boot code, found {len(j_dot_positions)}")
        return False
    exit_offset = j_dot_positions[1]  # second j . = normal exit
    jal_src = BOOT_VADDR + exit_offset

    # Append trampoline at end of boot code: auipc t1, hi; jalr x0, lo(t1)
    # Uses PC-relative addressing which works correctly on RV64 (no sign-extension issues).
    tramp_offset = len(boot)
    tramp_addr = BOOT_VADDR + tramp_offset
    pc_offset = test_entry - tramp_addr
    # Split into hi20 + lo12 with sign correction
    lo12 = pc_offset & 0xFFF
    if lo12 >= 0x800:
        lo12 -= 0x1000
        hi20 = ((pc_offset - lo12) >> 12) & 0xFFFFF
    else:
        hi20 = (pc_offset >> 12) & 0xFFFFF
    auipc = (hi20 << 12) | (6 << 7) | 0x17     # auipc t1, hi20
    jalr  = ((lo12 & 0xFFF) << 20) | (6 << 15) | 0x67  # jalr x0, lo12(t1)
    boot.extend(struct.pack("<II", auipc, jalr))

    # Patch exit j . with 4-byte JAL to trampoline
    # The j . (2 bytes) + unimp (2 bytes) = 4 bytes available
    t_offset = tramp_addr - jal_src
    imm = t_offset & ((1 << 21) - 1)
    imm20     = (imm >> 20) & 0x1
    imm_10_1  = (imm >> 1)  & 0x3FF
    imm11     = (imm >> 11) & 0x1
    imm_19_12 = (imm >> 12) & 0xFF
    word = (imm20 << 31) | (imm_10_1 << 21) | (imm11 << 20) | (imm_19_12 << 12) | 0x6F
    boot[exit_offset:exit_offset + 4] = struct.pack("<I", word)

    # Write patched boot code to temp file
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(boot)
        boot_tmp = f.name

    try:
        # Use objcopy to add boot section
        result = subprocess.run(
            [
                "riscv64-unknown-elf-objcopy",
                "--add-section", f".text.boot={boot_tmp}",
                "--set-section-flags", ".text.boot=alloc,load,code",
                "--change-section-address", f".text.boot={BOOT_VADDR:#x}",
                elf_path,
            ],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"  objcopy failed for {os.path.basename(elf_path)}: {result.stderr.strip()}")
            return False

        # Patch ELF entry point to boot code address
        elf = bytearray(open(elf_path, "rb").read())
        if elf[:4] != b"\x7fELF":
            return False
        struct.pack_into("<Q", elf, 24, BOOT_VADDR)
        open(elf_path, "wb").write(elf)

        return True
    finally:
        os.unlink(boot_tmp)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <boot.bin> <elf_directory>", file=sys.stderr)
        sys.exit(1)

    boot_bin = open(sys.argv[1], "rb").read()
    elf_dir = sys.argv[2]
    print(f"  Boot code: {len(boot_bin)} bytes, placed at {BOOT_VADDR:#x}")

    total = wrapped = 0
    for f in sorted(glob.glob(os.path.join(elf_dir, "**", "*.elf"), recursive=True)):
        if os.path.islink(f):
            f = os.path.realpath(f)
        total += 1
        if wrap_elf(f, boot_bin):
            wrapped += 1

    print(f"  Boot-wrapped {wrapped}/{total} ELFs")


if __name__ == "__main__":
    main()
