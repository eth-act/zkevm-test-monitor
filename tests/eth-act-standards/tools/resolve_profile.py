#!/usr/bin/env python3
"""Resolve a zkVM's memory profile for one guest ELF.

Usage: resolve_profile.py PROFILE ELF OUT

zkvms/<zkvm>/standards/profile.json is a memory profile of the zkVM reference
(eth-act/zkevm-standards reference/memory-profiles/) with two monitor-only keys:
`sources` (where each value comes from) and `symbols` (the vendor's linker
symbols for the stack and the heap, or null). The stack range depends on the
linked ELF, so the profile leaves it empty; this writes OUT with `stack` set to
[stack_bottom, stack_top) from the ELF's symbol table when both symbols are
named, and without the monitor-only keys, ready for `zkvm-run --validate`.
Exits 1 if a named stack symbol is missing from the ELF.
"""
import json
import shutil
import subprocess
import sys


def symbols(elf):
    nm = next((t for t in ("riscv64-unknown-elf-nm", "riscv64-elf-nm") if shutil.which(t)), None)
    if nm is None:
        sys.exit("riscv64-unknown-elf-nm (or riscv64-elf-nm) not found")
    out = subprocess.run([nm, elf], capture_output=True, text=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3:
            table[parts[2]] = int(parts[0], 16)
    return table


def main():
    profile_path, elf, out = sys.argv[1:4]
    profile = json.load(open(profile_path))
    names = profile.pop("symbols", {})
    profile.pop("sources", None)
    bottom, top = names.get("stack_bottom"), names.get("stack_top")
    if bottom and top:
        table = symbols(elf)
        missing = [n for n in (bottom, top) if n not in table]
        if missing:
            sys.exit(f"{elf}: stack symbol(s) {', '.join(missing)} not defined")
        profile["stack"] = {"base": hex(table[bottom]), "size": hex(table[top] - table[bottom])}
    with open(out, "w") as f:
        json.dump(profile, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
