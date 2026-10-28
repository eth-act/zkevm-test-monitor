#!/usr/bin/env python3
"""The static checks of the elf group, for a PF_X zkVM (ELF_EXEC_PERM=x).

Usage: static_checks.py <out.json> <elf>...

A zkVM that requires an execute-only (PF_X) segment should provide a linker
script that separates code from read-only data, and an execute-only artifact
has to be confirmed by post-link inspection of the linked ELF ("Code and data
separation"). build-guests.sh runs two checks on each guest ELF that the
zkVM's linker script linked:

- elf-static-segments: every allocated section with SHF_EXECINSTR lies in an
  executable segment, and no other allocated section does;
- elf-static-decode: the whole content of each executable segment decodes as
  RISC-V instructions (objdump -M max, so every extension, C included). A
  zero halfword, which the ISA defines as illegal, does not.

Writes {"<check>": {"passed": <bool>, "detail": <str>}} to <out.json>.
OBJDUMP names the objdump binary (default: riscv64-unknown-elf-objdump).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from mutate_elf import PF_X, SHF_ALLOC, SHF_EXECINSTR, Elf

OBJDUMP = os.environ.get("OBJDUMP", "riscv64-unknown-elf-objdump")
# "<address>:<tab><encoding><spaces><mnemonic>" in objdump -D output.
INSN = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]+)\s+(\S+)")
SHOWN = 5


def segment_problems(path, elf):
    """Allocated sections in the wrong kind of segment."""
    problems = []
    for sh in elf.shdrs:
        if not sh["sh_flags"] & SHF_ALLOC or sh["sh_size"] == 0:
            continue
        start, end = sh["sh_addr"], sh["sh_addr"] + sh["sh_size"]
        segment = next((p for p in elf.loads() if p["p_vaddr"] <= start and end <= p["p_vaddr"] + p["p_memsz"]), None)
        if segment is None:
            continue
        code = bool(sh["sh_flags"] & SHF_EXECINSTR)
        if code != bool(segment["p_flags"] & PF_X):
            where = "outside the executable segment" if code else "in the executable segment"
            problems.append(f"{path.name}: {elf.section_name(sh)} {where}")
    return problems


def decode_problems(path, elf):
    """Units of the executable segments that are not instructions."""
    problems = []
    for segment in elf.loads():
        if not segment["p_flags"] & PF_X:
            continue
        start = segment["p_offset"]
        content = bytes(elf.data[start:start + segment["p_filesz"]])
        content += bytes(segment["p_memsz"] - segment["p_filesz"])
        with tempfile.NamedTemporaryFile(suffix=".bin") as raw:
            raw.write(content)
            raw.flush()
            listing = subprocess.run(
                [OBJDUMP, "-D", "-z", "-b", "binary", "-m", "riscv:rv64", "-M", "max",
                 f"--adjust-vma={segment['p_vaddr']:#x}", raw.name],
                check=True, capture_output=True, text=True).stdout
        for line in listing.splitlines():
            m = INSN.match(line)
            if m and (m.group(3).startswith(".") or int(m.group(2), 16) == 0):
                problems.append(f"{path.name}: 0x{m.group(1)}: {m.group(2)} {m.group(3)}")
    return problems


def result(problems, count):
    if not problems:
        return {"passed": True, "detail": f"{count} ELFs checked"}
    shown = "; ".join(problems[:SHOWN])
    more = f" (and {len(problems) - SHOWN} more)" if len(problems) > SHOWN else ""
    return {"passed": False, "detail": f"{shown}{more}"}


def main():
    out = Path(sys.argv[1])
    paths = [Path(p) for p in sys.argv[2:]]
    segments, decode = [], []
    for path in paths:
        elf = Elf(path)
        segments += segment_problems(path, elf)
        decode += decode_problems(path, elf)
    checks = {
        "elf-static-segments": result(segments, len(paths)),
        "elf-static-decode": result(decode, len(paths)),
    }
    out.write_text(json.dumps(checks, indent=2) + "\n")
    for name, check in checks.items():
        print(f"{name}: {'passed' if check['passed'] else 'FAILED'}: {check['detail']}")


if __name__ == "__main__":
    main()
