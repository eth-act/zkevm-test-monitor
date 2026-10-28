#!/usr/bin/env python3
"""Check the memory map of the linked guests against the guard region standard.

Usage: check_guard_layout.py --stack-bottom <symbol|none> <out.c> <elf>...

The memory-safety-guard-regions standard says that the null pointer trap
region (0x0000 through 0x0FFF) "must not be mapped to readable or writable
memory" and "must not be used by the zkVM runtime, linker scripts, or any
other system component". It also says that the stack guard region, at least
4 kB "immediately below the bottom of the stack", "must not be mapped to
readable or writable memory".

--stack-bottom is the vendor linker symbol of the stack bottom, the lowest
stack byte (symbols.stack_bottom in zkvms/<zkvm>/standards/layout.yaml). With
none, the platform declares no stack bottom, so it has no stack guard region,
and the check fails. Each ELF fails the check when:
- a PT_LOAD segment with a non-zero memory size overlaps the null region or
  the 4 kB below the stack bottom;
- an allocated section (SHF_ALLOC) with a non-zero size overlaps one of them;
- it defines _heap_start and _heap_end (the heap symbols of the static
  library standard), and the heap [_heap_start, _heap_end) overlaps one of them;
- it does not define the stack bottom symbol, or the stack bottom is in the
  null region (the stack would use the region).

Writes <out.c>, the guard-layout guest: it calls rvtest_pass() when every ELF
passes, else print_error() with the first violations. It also prints the
violations. Exits 0 in both cases.
"""

import argparse
import struct
from pathlib import Path

NULL_REGION = (0x0, 0x1000)
STACK_GUARD_SIZE = 0x1000
MAX_SHOWN = 4

PT_LOAD = 1
SHF_ALLOC = 0x2
SHT_SYMTAB = 2
SHN_UNDEF = 0

HEADER = """\
// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/*
 * Written by tools/check_guard_layout.py from the memory map of the linked
 * guests: no segment, allocated section or heap of a guest overlaps the null
 * pointer trap region or the 4 kB below the stack bottom
 * (memory-safety-guard-regions: "The region must not be mapped to readable or
 * writable memory. It must not be used by the zkVM runtime, linker scripts,
 * or any other system component."; "It must not be mapped to readable or
 * writable memory.").
 */
#include "checks.h"

"""


def read_elf(path):
    """The PT_LOAD segments, the allocated sections and the defined symbols of a
    64-bit little-endian ELF: ([(vaddr, memsz)], [(name, addr, size)], {name: value})."""
    data = Path(path).read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{path} is not a 64-bit little-endian ELF")
    (_, _, _, _, _, phoff, shoff, _, _, phentsize, phnum, shentsize, shnum, shstrndx) = struct.unpack_from(
        "<16sHHIQQQIHHHHHH", data
    )
    segments = []
    for i in range(phnum):
        p_type, _, _, vaddr, _, _, memsz, _ = struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize)
        if p_type == PT_LOAD:
            segments.append((vaddr, memsz))
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]

    def string(table, offset):
        start = headers[table][4] + offset
        return data[start : data.index(b"\0", start)].decode()

    sections = []
    symbols = {}
    for name, sh_type, flags, addr, offset, size, link, _, _, entsize in headers:
        if flags & SHF_ALLOC:
            sections.append((string(shstrndx, name), addr, size))
        if sh_type == SHT_SYMTAB:
            for j in range(size // entsize):
                st_name, _, _, shndx, value, _ = struct.unpack_from("<IBBHQQ", data, offset + j * entsize)
                if shndx != SHN_UNDEF and st_name:
                    symbols[string(link, st_name)] = value
    return segments, sections, symbols


def overlaps(start, size, region):
    return size > 0 and start < region[1] and region[0] < start + size


def violations(path, stack_bottom):
    segments, sections, symbols = read_elf(path)
    found = []
    regions = [("the null region", NULL_REGION)]
    if stack_bottom is not None:
        if stack_bottom not in symbols:
            found.append(f"no stack bottom symbol {stack_bottom}")
        else:
            bottom = symbols[stack_bottom]
            if bottom < NULL_REGION[1]:
                found.append(f"the stack bottom {stack_bottom} ({bottom:#x}) is in the null region")
            guard = (bottom - STACK_GUARD_SIZE, bottom)
            regions.append((f"the stack guard region [{guard[0]:#x}, {guard[1]:#x})", guard))
    heap = None
    if "_heap_start" in symbols and "_heap_end" in symbols:
        heap = (symbols["_heap_start"], symbols["_heap_end"])
    for what, region in regions:
        for vaddr, memsz in segments:
            if overlaps(vaddr, memsz, region):
                found.append(f"a PT_LOAD segment at {vaddr:#x} (size {memsz:#x}) overlaps {what}")
        for name, addr, size in sections:
            if overlaps(addr, size, region):
                found.append(f"section {name} at {addr:#x} (size {size:#x}) overlaps {what}")
        if heap and overlaps(heap[0], heap[1] - heap[0], region):
            found.append(f"the heap [{heap[0]:#x}, {heap[1]:#x}) overlaps {what}")
    return found


def c_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stack-bottom", required=True, help="the stack bottom symbol, or none")
    parser.add_argument("out", type=Path, help="the guard-layout guest to write")
    parser.add_argument("elfs", nargs="+", help="the linked guests")
    args = parser.parse_args()
    stack_bottom = None if args.stack_bottom == "none" else args.stack_bottom
    found = [] if stack_bottom else ["the platform declares no stack bottom"]
    found += [f"{Path(elf).name}: {v}" for elf in args.elfs for v in violations(elf, stack_bottom)]
    for line in found:
        print(f"guard-layout: {line}")
    if found:
        shown = found[:MAX_SHOWN]
        if len(found) > MAX_SHOWN:
            shown.append(f"and {len(found) - MAX_SHOWN} more")
        body = f"    print_error(\"%s\\n\", {c_string('; '.join(shown))});\n"
    else:
        body = "    rvtest_pass();\n"
    args.out.write_text(HEADER + "int main(void) {\n" + body + "    return 0;\n}\n")


if __name__ == "__main__":
    main()
