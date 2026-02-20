#!/usr/bin/env python3
"""Post-process ACT4 ELFs for ZKVMs that pre-process all words as instructions.

Fixes three incompatibilities:

1. Strips EF_RISCV_RVC flag: ACT4's test_setup.h uses ".option rvc" for alignment,
   setting the RVC flag even though no compressed instructions are emitted.

2. Replaces non-instruction data words in executable segments with NOPs: ACT4's
   SELFCHECK mechanism embeds .word data (string pointers) in .text immediately
   after jal instructions. ZKVMs like SP1 and Pico pre-process ALL 32-bit words in
   executable segments as instructions, panicking on these data words. Replacing them
   with NOPs is safe because they are never executed (placed after unconditional jumps)
   and only read by the failure handler for diagnostics (RVMODEL_IO_WRITE_STR is
   a no-op for these ZKVMs).

3. Replaces CSR instructions with NOPs/zero-loads: SP1 and Pico treat ALL opcode-0x73
   instructions as ecalls (reading a7 as syscall number). CSR instructions (csrr, csrw,
   csrs, csrc, etc.) share opcode 0x73 but have funct3 != 0. ACT4's test setup uses
   CSR instructions to initialize machine-mode state (mstatus, mepc, etc.) which these
   ZKVMs don't implement. Replacing csrw/csrs/csrc (rd=x0) with NOPs and csrr/csrrw/
   csrrs/csrrc (rd!=x0) with "addi rd, x0, 0" safely simulates all CSRs reading as 0.

Uses riscv64-unknown-elf-objdump for reliable detection of non-instruction words.

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
    """Find all file offsets that need patching and their replacement values.

    Returns dict of file_offset → replacement_word.
    """
    sections = get_exec_sections(filepath)
    if not sections:
        return {}

    objdump = subprocess.run(
        ["riscv64-unknown-elf-objdump", "-d", "-M", "no-aliases", filepath],
        capture_output=True, text=True
    )

    NOP = 0x00000013  # addi x0, x0, 0

    patches = {}  # file_offset → replacement instruction
    for line in objdump.stdout.splitlines():
        # Parse instruction lines: "   addr:  hex_encoding   mnemonic ..."
        line_match = re.match(
            r'\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(.*)', line
        )
        if not line_match:
            continue

        vaddr_str, insn_hex, rest = line_match.groups()
        vaddr = int(vaddr_str, 16)
        rest = rest.strip()

        # 1. Non-instruction data words (.word or raw hex)
        if rest.startswith('.word') or re.match(r'^0x[0-9a-f]+\s*$', rest):
            file_off = vaddr_to_file_offset(vaddr, sections)
            if file_off is not None:
                patches[file_off] = NOP
            continue

        # 2. CSR instructions (opcode 0x73, funct3 != 0)
        # Detect by mnemonic: csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci
        # (objdump with no-aliases shows the full form, not pseudo-ops like csrw/csrr)
        if re.match(r'csr(rw|rs|rc)(i?)\s', rest):
            insn = int(insn_hex, 16)
            rd = (insn >> 7) & 0x1F
            file_off = vaddr_to_file_offset(vaddr, sections)
            if file_off is not None:
                if rd == 0:
                    # Pure write (e.g. csrw = csrrw x0, csr, rs): replace with NOP
                    patches[file_off] = NOP
                else:
                    # Has destination register: replace with "addi rd, x0, 0"
                    # to simulate reading CSR as 0
                    patches[file_off] = NOP | (rd << 7)
            continue

    return patches


def patch_elf(filepath: str) -> int:
    """Patch a single ELF file. Returns number of words patched."""
    patches = find_patches(filepath)

    with open(filepath, "r+b") as elf:
        elf.seek(0)
        if elf.read(4) != b"\x7fELF":
            return 0
        ei_class = elf.read(1)[0]  # 1=ELF32, 2=ELF64

        # Strip RVC flag from ELF header
        flags_off = 0x24 if ei_class == 1 else 0x30
        elf.seek(flags_off)
        flags = struct.unpack("<I", elf.read(4))[0]
        if flags & 0x1:
            elf.seek(flags_off)
            elf.write(struct.pack("<I", flags & ~0x1))

        # Apply all patches
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
