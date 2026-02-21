#!/usr/bin/env python3
"""Post-process ACT4 ELFs for ZKVMs that need instruction-level fixups.

Two modes:

  Default (no flags): word-in-text patch for SP1, Pico, OpenVM
    Replaces non-instruction data words embedded in executable sections with NOPs.
    ACT4's SELFCHECK mechanism places .word string pointers after jal failedtest_*
    calls in .text. ZKVMs that pre-process all words as instructions panic on these.

  --zisk: failure-handler bypass patch for Zisk
    Replaces the first instruction of failedtest_saveresults with a JAL x0 to
    failedtest_terminate (exit 1). Zisk maps .text.init as execute-only; ACT4's
    failure handler decodes the failing instruction by reading bytes from .text.init
    via lhu with negative offsets from x5 (the return address). Zisk panics. Simple
    NOPs aren't sufficient because subsequent `ld` instructions use the stale lhu
    results to compute further load addresses, cascading the crash. A direct jump to
    failedtest_terminate preserves exit-code semantics: 0 = pass, 1 = fail.

Usage:
  python3 patch_elfs.py <elf_directory>           # SP1/Pico/OpenVM mode
  python3 patch_elfs.py --zisk <elf_directory>    # Zisk mode
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
    """Find non-instruction data words in executable sections (SP1/Pico/OpenVM mode).

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


def encode_jal_x0(src_vaddr: int, dst_vaddr: int) -> int:
    """Encode 'jal x0, (dst_vaddr - src_vaddr)' as a 32-bit RISC-V J-type instruction."""
    offset = dst_vaddr - src_vaddr
    assert offset % 2 == 0 and -(1 << 20) <= offset < (1 << 20), \
        f"JAL offset {offset:#x} out of range"
    imm = offset & ((1 << 21) - 1)
    imm20     = (imm >> 20) & 0x1
    imm_10_1  = (imm >> 1)  & 0x3FF
    imm11     = (imm >> 11) & 0x1
    imm_19_12 = (imm >> 12) & 0xFF
    return (imm20 << 31) | (imm_10_1 << 21) | (imm11 << 20) | (imm_19_12 << 12) | 0x6F


def find_zisk_patches(filepath: str) -> dict[int, int]:
    """Patch failedtest_saveresults to jump directly to failedtest_terminate (Zisk mode).

    ACT4's failedtest_saveresults decodes the failing instruction by reading bytes from
    .text.init via lhu with negative offsets from t0 (return address into the code
    segment). Zisk maps .text.init as execute-only, so these reads panic. Subsequent
    instructions use the stale/garbage registers to compute further load addresses,
    causing a cascade of crashes even after NOPping the individual lhu instructions.

    Fix: replace the first instruction of failedtest_saveresults with a JAL x0 directly
    to failedtest_terminate (exit code 1). This skips all instruction-decoding code
    while preserving correct exit-code semantics (1 = test failed, 0 = test passed).

    Returns dict of file_offset → JAL encoding.
    """
    sections = get_exec_sections(filepath)
    if not sections:
        return {}

    objdump = subprocess.run(
        ["riscv64-unknown-elf-objdump", "-d", filepath],
        capture_output=True, text=True
    )

    # Collect symbol → first-instruction vaddr
    symbols: dict[str, int] = {}
    for line in objdump.stdout.splitlines():
        m = re.match(r'([0-9a-f]+) <([^>]+)>:', line)
        if m:
            vaddr, name = int(m.group(1), 16), m.group(2)
            if name in ('failedtest_saveresults', 'failedtest_terminate'):
                symbols[name] = vaddr

    if 'failedtest_saveresults' not in symbols or 'failedtest_terminate' not in symbols:
        return {}

    src_vaddr = symbols['failedtest_saveresults']
    dst_vaddr = symbols['failedtest_terminate']
    file_off = vaddr_to_file_offset(src_vaddr, sections)
    if file_off is None:
        return {}

    return {file_off: encode_jal_x0(src_vaddr, dst_vaddr)}


def patch_elf(filepath: str, zisk_mode: bool = False) -> int:
    """Patch a single ELF file. Returns number of words patched."""
    patches = find_zisk_patches(filepath) if zisk_mode else find_patches(filepath)
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
    args = sys.argv[1:]
    zisk_mode = False
    if args and args[0] == '--zisk':
        zisk_mode = True
        args = args[1:]

    if len(args) != 1:
        print(f"Usage: {sys.argv[0]} [--zisk] <elf_directory>", file=sys.stderr)
        sys.exit(1)

    elf_dir = args[0]
    total_patched = 0
    files_patched = 0

    for f in sorted(glob.glob(os.path.join(elf_dir, "**", "*.elf"), recursive=True)):
        if os.path.islink(f):
            f = os.path.realpath(f)
        count = patch_elf(f, zisk_mode=zisk_mode)
        if count:
            print(f"  Patched {count} words in {os.path.basename(f)}")
            total_patched += count
            files_patched += 1

    if total_patched:
        print(f"  Total: {total_patched} words patched across {files_patched} files")


if __name__ == "__main__":
    main()
