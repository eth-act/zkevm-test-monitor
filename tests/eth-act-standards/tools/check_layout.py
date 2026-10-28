#!/usr/bin/env python3
"""Static checks of the memory layout for the layout/ tests.

Usage:
    uv run --no-project --with pyyaml --with pyelftools \\
        tests/eth-act-standards/tools/check_layout.py defines <layout.yaml>
    ... check_layout.py check <layout.yaml> <elf> <stub-dir>

defines prints the -D options of the layout/ guests: LAYOUT_HEAP_START,
LAYOUT_HEAP_END, LAYOUT_STACK_BOTTOM and LAYOUT_STACK_TOP, each set to the
vendor's symbol that layout.yaml declares (none: no option, see layout/layout.h).

check checks a linked layout/ guest against layout.yaml
(zkvms/<zkvm>/standards/layout.yaml) and writes one ACT4 C test per check to
<stub-dir>, layout-static-<check>.c. The test passes, or fails with the
reason. The checks test the sentence of the memory-layout-restrictions
standard "Each zkVM vendor must provide its own linker script that correctly
describes its memory constraints, including the location and size of
critical memory regions such as heap and stack areas":

    a1  "must provide its own linker script": layout.yaml names the vendor's
        linker script (not none).
    a2  "correctly describes its memory constraints": each PT_LOAD segment of
        the ELF, the heap and the stack are in one region of layout.yaml, the
        memory that the zkVM source defines. A bound that the linker script
        does not declare is not checked here (a3 fails for it); a range with
        one declared bound checks that bound.
    a3  "including the location and size of ... heap and stack areas": the
        ELF has a symbol for each heap and stack bound (heap start and end,
        stack bottom and top). The standard names no symbols, so the
        vendor's names from layout.yaml are used.
"""

import json
import sys
from pathlib import Path

import yaml
from elftools.elf.elffile import ELFFile

# layout.yaml symbol key -> (guest macro, description)
SYMBOLS = {
    "heap_start": ("LAYOUT_HEAP_START", "heap start"),
    "heap_end": ("LAYOUT_HEAP_END", "heap end"),
    "stack_bottom": ("LAYOUT_STACK_BOTTOM", "stack bottom"),
    "stack_top": ("LAYOUT_STACK_TOP", "stack top"),
}

STUB = """\
// START_TEST_CONFIG
// REQUIRED_EXTENSIONS: ['I', 'M']
// MARCH: rv64im_zicclsm
// NEEDS_SIGNATURE: false
// END_TEST_CONFIG
/* Static layout check {check}, written by tools/check_layout.py from {elf}: {what} */
#include "checks.h"

int main(void) {{
    {body}
    return 0;
}}
"""

WHAT = {
    "a1": "the zkVM vendor provides its own linker script.",
    "a2": "each PT_LOAD segment, the heap and the stack are in memory that the zkVM defines.",
    "a3": "the ELF has the linker script's symbols for the heap and stack bounds.",
}


def load_layout(path):
    layout = yaml.safe_load(Path(path).read_text())
    symbols = {key: layout["symbols"][key] for key in SYMBOLS}
    for key, name in symbols.items():
        if not isinstance(name, str) or not name:
            sys.exit(f"error: {path}: symbols.{key} must be a symbol name or none")
    regions = []
    for region in layout["regions"]:
        start, end = int(region["start"]), int(region["end"])
        if start >= end:
            sys.exit(f"error: {path}: region {region['name']} is empty")
        regions.append((region["name"], start, end))
    return str(layout["linker_script"]), symbols, regions


def declared(symbols):
    return {key: name for key, name in symbols.items() if name != "none"}


def in_region(regions, start, end):
    """Whether [start, end) is in one region."""
    return any(r_start <= start and end <= r_end for _, r_start, r_end in regions)


def check(layout_path, elf_path, stub_dir):
    linker_script, symbols, regions = load_layout(layout_path)
    with open(elf_path, "rb") as f:
        elf = ELFFile(f)
        segments = [
            (seg["p_vaddr"], seg["p_memsz"]) for seg in elf.iter_segments() if seg["p_type"] == "PT_LOAD"
        ]
        symtab = elf.get_section_by_name(".symtab")
        values = {}
        for sym in symtab.iter_symbols() if symtab else []:
            if sym.name and sym["st_shndx"] != "SHN_UNDEF":
                values[sym.name] = sym["st_value"]

    failures = {"a1": [], "a2": [], "a3": []}

    if linker_script == "none":
        failures["a1"].append("the zkVM publishes no linker script")

    for key, (_, what) in SYMBOLS.items():
        name = symbols[key]
        if name == "none":
            failures["a3"].append(f"linker script declares no {what}")
        elif name not in values:
            failures["a3"].append(f"ELF has no symbol {name} ({what})")

    for vaddr, memsz in segments:
        if not in_region(regions, vaddr, vaddr + memsz):
            failures["a2"].append(f"PT_LOAD [{vaddr:#x}, {vaddr + memsz:#x}) is in no region")
    for area, low_key, high_key in (("heap", "heap_start", "heap_end"), ("stack", "stack_bottom", "stack_top")):
        low = values.get(symbols[low_key])
        high = values.get(symbols[high_key])
        if low is not None and high is not None:
            if low > high or not in_region(regions, low, high):
                failures["a2"].append(f"{area} [{low:#x}, {high:#x}) is in no region")
        elif low is not None and not in_region(regions, low, low + 1):
            failures["a2"].append(f"{SYMBOLS[low_key][1]} {low:#x} is in no region")
        elif high is not None and not in_region(regions, high - 1, high):
            failures["a2"].append(f"{SYMBOLS[high_key][1]} {high:#x} is in no region")

    stub_dir = Path(stub_dir)
    for name, reasons in failures.items():
        if reasons:
            reason = f"{name}: " + "; ".join(reasons)
            print(f"layout-static-{name}: fail: {reason}")
            body = f'print_error("%s\\n", {json.dumps(reason)});'
        else:
            print(f"layout-static-{name}: pass")
            body = "rvtest_pass();"
        stub = STUB.format(check=name, elf=Path(elf_path).name, what=WHAT[name], body=body)
        (stub_dir / f"layout-static-{name}.c").write_text(stub)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "defines":
        _, symbols, _ = load_layout(sys.argv[2])
        print(" ".join(f"-D{SYMBOLS[key][0]}={name}" for key, name in declared(symbols).items()))
    elif len(sys.argv) == 5 and sys.argv[1] == "check":
        check(*sys.argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
