#!/usr/bin/env python3
"""Write the crafted ELF variants of the elf group.

Usage: mutate_elf.py <elf-dir>

Reads elf-image.elf and elf-tail.elf in <elf-dir> (build-guests.sh builds
them) and writes each variant <name>.elf next to them, with its <name>.input
when it has one. Each accept-* variant changes only ELF content that the ELF
loading and validation standard says a loader must ignore or handle, so the
guest must still pass.

A variant that needs a new program header gets a copy of the program header
table at the end of the file, with the new entry; e_phoff and e_phnum point
to the copy. The section header table does not move.

Python standard library only.
"""

import struct
import sys
from pathlib import Path

EHDR = struct.Struct("<16sHHIQQQIHHHHHH")
PHDR = struct.Struct("<IIQQQQQQ")
SHDR = struct.Struct("<IIQQQQIIQQ")
SYM = struct.Struct("<IBBHQQ")
EHDR_FIELDS = ("e_ident e_type e_machine e_version e_entry e_phoff e_shoff e_flags e_ehsize "
               "e_phentsize e_phnum e_shentsize e_shnum e_shstrndx").split()
PHDR_FIELDS = "p_type p_flags p_offset p_vaddr p_paddr p_filesz p_memsz p_align".split()
SHDR_FIELDS = ("sh_name sh_type sh_flags sh_addr sh_offset sh_size sh_link sh_info "
               "sh_addralign sh_entsize").split()

PT_LOAD = 1
PT_NOTE = 4
PF_X = 1
PF_W = 2
PF_R = 4
SHT_PROGBITS = 1
SHT_SYMTAB = 2
SHT_NOBITS = 8
SHF_WRITE = 1
SHF_ALLOC = 2
SHF_EXECINSTR = 4

PAGE = 0x1000


def tail_byte(i):
    """Match TAIL_BYTE in elf-tail.c."""
    return (i * 41 + 3) & 0xFF


class Elf:
    """An ELF64 little-endian file with its headers unpacked."""

    def __init__(self, path):
        self.data = bytearray(path.read_bytes())
        self.ehdr = dict(zip(EHDR_FIELDS, EHDR.unpack_from(self.data)))
        e = self.ehdr
        self.phdrs = [dict(zip(PHDR_FIELDS, PHDR.unpack_from(self.data, e["e_phoff"] + i * PHDR.size)))
                      for i in range(e["e_phnum"])]
        self.shdrs = [dict(zip(SHDR_FIELDS, SHDR.unpack_from(self.data, e["e_shoff"] + i * SHDR.size)))
                      for i in range(e["e_shnum"])]

    def loads(self):
        return [p for p in self.phdrs if p["p_type"] == PT_LOAD]

    def section_name(self, sh):
        strtab = self.shdrs[self.ehdr["e_shstrndx"]]
        start = strtab["sh_offset"] + sh["sh_name"]
        return bytes(self.data[start:self.data.index(0, start)]).decode()

    def section(self, name):
        return next(sh for sh in self.shdrs if self.section_name(sh) == name)

    def symbol(self, name):
        symtab = next(sh for sh in self.shdrs if sh["sh_type"] == SHT_SYMTAB)
        strtab = self.shdrs[symtab["sh_link"]]
        for off in range(symtab["sh_offset"], symtab["sh_offset"] + symtab["sh_size"], SYM.size):
            st_name, _, _, _, st_value, _ = SYM.unpack_from(self.data, off)
            start = strtab["sh_offset"] + st_name
            if bytes(self.data[start:self.data.index(0, start)]) == name.encode():
                return st_value
        sys.exit(f"mutate_elf.py: no symbol {name}")

    def append(self, contents, align):
        """Append `contents` at an `align`-aligned file offset and return the offset."""
        self.data += bytes(-len(self.data) % align)
        offset = len(self.data)
        self.data += contents
        return offset

    def add_phdr(self, **phdr):
        """Add a program header, in a copy of the table at the end of the file."""
        self.phdrs.append(phdr)
        self.ehdr["e_phoff"] = self.append(bytes(PHDR.size * len(self.phdrs)), 8)
        self.ehdr["e_phnum"] = len(self.phdrs)

    def write(self, path):
        e = self.ehdr
        EHDR.pack_into(self.data, 0, *(e[f] for f in EHDR_FIELDS))
        for i, p in enumerate(self.phdrs):
            PHDR.pack_into(self.data, e["e_phoff"] + i * PHDR.size, *(p[f] for f in PHDR_FIELDS))
        for i, sh in enumerate(self.shdrs[:e["e_shnum"]]):
            SHDR.pack_into(self.data, e["e_shoff"] + i * SHDR.size, *(sh[f] for f in SHDR_FIELDS))
        path.write_bytes(self.data)


def accept_extra_phdr(elf):
    """Only PT_LOAD segments are loaded: a PT_NOTE whose p_vaddr is the
    checked .data bytes of elf-image does not change them."""
    note = struct.pack("<III", 8, 16, 1) + b"eth-act\0" + bytes([0xA5] * 16)
    offset = elf.append(note, 4)
    addr = elf.symbol("elf_image_data")
    elf.add_phdr(p_type=PT_NOTE, p_flags=PF_R, p_offset=offset, p_vaddr=addr, p_paddr=addr,
                 p_filesz=len(note), p_memsz=len(note), p_align=4)


def accept_no_shdrs(elf):
    """Loading does not depend on the section headers: remove the table."""
    elf.ehdr.update(e_shoff=0, e_shnum=0, e_shstrndx=0)


def accept_shdrs_altered(elf):
    """Loading does not depend on the contents of the section headers: change
    the address, size, type and flags of each allocated section, and give
    .symtab an invalid string table index."""
    for sh in elf.shdrs:
        if sh["sh_flags"] & SHF_ALLOC:
            sh["sh_addr"] += 0x10000000
            sh["sh_size"] //= 2
            sh["sh_type"] = {SHT_PROGBITS: SHT_NOBITS, SHT_NOBITS: SHT_PROGBITS}.get(sh["sh_type"], sh["sh_type"])
            sh["sh_flags"] ^= SHF_WRITE | SHF_EXECINSTR
    elf.section(".symtab")["sh_link"] = elf.ehdr["e_shnum"]


def accept_paddr(elf):
    """The image is placed at the virtual addresses (VMA == LMA): a physical
    address that differs from p_vaddr does not change it."""
    for p in elf.phdrs:
        p["p_paddr"] = p["p_vaddr"] + 0x10000000


def accept_tail(elf, r):
    """Zero fill does not overwrite file bytes: a read-only segment with
    16 + r file bytes and 16 bytes of zero fill, 1 MiB above the last
    segment. Returns the input of elf-tail: the address and r."""
    end = max(p["p_vaddr"] + p["p_memsz"] for p in elf.loads())
    addr = (end + (1 << 20) + PAGE - 1) & ~(PAGE - 1)
    file_size = 16 + r
    offset = elf.append(bytes(tail_byte(i) for i in range(file_size)), PAGE)
    elf.add_phdr(p_type=PT_LOAD, p_flags=PF_R, p_offset=offset, p_vaddr=addr, p_paddr=addr,
                 p_filesz=file_size, p_memsz=file_size + 16, p_align=PAGE)
    return struct.pack("<QQ", addr, r)


def main():
    elf_dir = Path(sys.argv[1])
    image = elf_dir / "elf-image.elf"
    tail = elf_dir / "elf-tail.elf"

    # name -> (base ELF, mutation); a mutation returns the input, or None.
    variants = {
        "accept-extra-phdr": (image, accept_extra_phdr),
        "accept-no-shdrs": (image, accept_no_shdrs),
        "accept-shdrs-altered": (image, accept_shdrs_altered),
        "accept-paddr": (image, accept_paddr),
    }
    for r in range(1, 8):
        variants[f"accept-tail-{r}"] = (tail, lambda elf, r=r: accept_tail(elf, r))

    for name, (base, mutate) in variants.items():
        elf = Elf(base)
        data_in = mutate(elf)
        elf.write(elf_dir / f"{name}.elf")
        if data_in is not None:
            (elf_dir / f"{name}.input").write_bytes(data_in)


if __name__ == "__main__":
    main()
