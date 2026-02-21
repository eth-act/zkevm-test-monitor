#!/usr/bin/env python3
"""Post-process ACT4 ELFs for ZKVMs that pre-process all words as instructions.

Replaces non-instruction data words in executable segments with NOPs (addi x0, x0, 0).

ACT4's SELFCHECK mechanism embeds .word pointers (to test-name strings) in .text
immediately after each `jal failedtest_*` call. The failure handler loads the string
pointer via `LREG x6, 0(DEFAULT_LINK_REG)` — i.e., it reads the word that immediately
follows the jal in memory. ZKVMs like SP1, Pico, and OpenVM pre-process ALL 32-bit words
in executable segments as instructions before execution begins, panicking on these
arbitrary pointer values.

Replacing them with NOPs is safe because:
- They are placed after unconditional jumps and are never executed.
- They are only loaded (not jumped-to) by the failure handler for diagnostic output.
- RVMODEL_IO_WRITE_STR is a no-op for these ZKVMs, so losing the string is harmless.

Upstream tracking: the correct fix is for ACT4 to move these string pointers to .rodata
and use PC-relative addressing. See HACK_TRACKING.md — Hack 2.

Usage: python3 patch_elfs.py <elf_directory>
"""

import glob
import os
import re
import struct
import subprocess
import sys


def get_exec_sections(filepath: str) -> dict:
    """Get executable section info: name → (vaddr, file_offset, size)."""
    readelf = subprocess.run(
        ["riscv64-unknown-elf-readelf", "-S", filepath],
        capture_output=True, text=True
    )
    sections = {}
    for m in re.finditer(
        r'\[\s*\d+\]\s+(\S+)\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+\S+\s+(\S+)',
        readelf.stdout
    ):
        name, vaddr, off, size, flags = m.groups()
        if 'X' in flags:
            sections[name] = (int(vaddr, 16), int(off, 16), int(size, 16))
    return sections


def vaddr_to_file_offset(vaddr: int, sections: dict) -> int | None:
    """Convert a virtual address to file offset using section mappings."""
    for sec_vaddr, sec_off, sec_size in sections.values():
        if sec_vaddr <= vaddr < sec_vaddr + sec_size:
            return sec_off + (vaddr - sec_vaddr)
    return None


def find_patches(filepath: str) -> dict[int, int]:
    """Find file offsets of non-instruction data words in executable sections.

    Returns dict of file_offset → NOP (0x00000013).
    """
    sections = get_exec_sections(filepath)
    if not sections:
        return {}

    objdump = subprocess.run(
        ["riscv64-unknown-elf-objdump", "-d", "-M", "no-aliases", filepath],
        capture_output=True, text=True
    )

    NOP = 0x00000013  # addi x0, x0, 0

    patches = {}
    for line in objdump.stdout.splitlines():
        line_match = re.match(r'\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*)', line)
        if not line_match:
            continue

        vaddr_str, insn_hex, rest = line_match.groups()
        rest = rest.strip()

        # Non-instruction data words (.word or raw hex with no mnemonic)
        if rest.startswith('.word') or re.match(r'^0x[0-9a-f]+\s*$', rest):
            vaddr = int(vaddr_str, 16)
            file_off = vaddr_to_file_offset(vaddr, sections)
            if file_off is not None:
                patches[file_off] = NOP

    return patches


def patch_elf(filepath: str) -> int:
    """Patch a single ELF file. Returns number of words patched."""
    patches = find_patches(filepath)
    if not patches:
        return 0

    with open(filepath, "r+b") as elf:
        if elf.read(4) != b"\x7fELF":
            return 0

        for off in sorted(patches):
            elf.seek(off)
            elf.write(struct.pack("<I", patches[off]))

    return len(patches)


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <elf_directory>", file=sys.stderr)
        sys.exit(1)

    elf_dir = sys.argv[1]
    total_patched = 0
    files_patched = 0

    for f in sorted(glob.glob(os.path.join(elf_dir, "**", "*.elf"), recursive=True)):
        if os.path.islink(f):
            f = os.path.realpath(f)
        count = patch_elf(f)
        if count:
            print(f"  Patched {count} words in {os.path.basename(f)}")
            total_patched += count
            files_patched += 1

    if total_patched:
        print(f"  Total: {total_patched} words patched across {files_patched} files")


if __name__ == "__main__":
    main()
