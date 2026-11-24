#!/usr/bin/env python3
"""The static checks of the eth-act standards tests: a zkVM's static library,
its linker script and the built guest ELFs, checked without running them.

Usage:
    static_checks.py --library LIB [--linker-script LD] --probe-object O
        [--zkvm-run ZKVM_RUN --profile PROFILE] <out-dir>

build-runtime-guests.sh runs it after build-guests.sh built the ACT4 guests
into <out-dir>/<group>/ and after it linked the runtime guests into
<out-dir>/runtime/ (GNU ld) and <out-dir>/runtime-lld/ (LLD), and the probe
library/rt-segments.c into <out-dir>/library/rt-segments.probe and
rt-segments-lld.probe. A guest that did not link has a <name>.link-error file
instead of its ELF.

Writes <out-dir>/library/static-results.json: a list of verdicts
{"name", "group", "passed", "detail", "requirements"}, which the runner
records as tests. The checks are in group "library":

    lib-archive              the library is an ar archive of RISC-V ELF64 objects
    lib-linker-script        the zkVM supplies a linker script with the library
    lib-script-phdrs         the linker script has a PHDRS declaration
    lib-entry[-lld]          e_entry is _start in every runtime ELF
    lib-heap-symbols[-lld]   rt-heap-symbols defines _heap_start and _heap_end
    lib-segments[-lld]       in the probe, code is in executable, non-writable
                             segments, and read-only data in readable,
                             non-executable segments
    static-validate          the zkVM reference's loader accepts every guest
                             ELF under the zkVM's memory profile: for each ELF,
                             tools/resolve_profile.py, then
                             `zkvm-run --validate`; only with --zkvm-run and
                             --profile; not the crafted elf/accept-* and
                             elf/reject-* variants, which test the loader
    static-exec-decodes      for an execute-only zkVM (exec_perm x), every
                             word of each guest ELF's PF_X-only segments is an
                             RV64IM instruction (`zkvm-run --check-exec-decodes`)

A guest that did not link is a failed test in its own group (runtime or
runtime-lld). Without a linker script, the checks of the script and of the
ELFs fail.

"requirements" lists the requirement IDs of the check
(tests/eth-act-standards/static-requirements.txt) whose standard
tests/eth-act-standards/covered-standards.txt names; a guest that did not link
has the IDs of its .req file. The script uses only the Python standard library,
and riscv64-unknown-elf-nm through resolve_profile.py.
"""

import argparse
import json
import re
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
EM_RISCV = 243
PT_LOAD = 1
PF_X, PF_W, PF_R = 1, 2, 4
SHT_SYMTAB = 2
STB_GLOBAL, STB_WEAK = 1, 2

# The linkers, their runtime groups and the suffix of their ELF names.
LINKERS = [("GNU ld", "runtime", ""), ("LLD", "runtime-lld", "-lld")]

# The probe's symbols (library/rt-segments.c): name -> (input section, code).
PROBE_SYMBOLS = {
    "probe_text": (".text.rt_probe", True),
    "probe_init": (".init", True),
    "probe_fini": (".fini", True),
    "probe_rodata": (".rodata.rt_probe", False),
    "probe_srodata": (".srodata", False),
    "probe_gcc_except_table": (".gcc_except_table", False),
    "probe_data_rel_ro": (".data.rel.ro", False),
}


class Elf:
    """The parts of a little-endian ELF64 file that the checks read."""

    def __init__(self, path):
        data = Path(path).read_bytes()
        if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
            raise ValueError(f"{Path(path).name} is not a little-endian ELF64 file")
        (self.type, self.machine, _, self.entry, phoff, shoff, _, _, phentsize, phnum,
         shentsize, shnum, shstrndx) = struct.unpack_from("<HHIQQQIHHHHHH", data, 16)
        # (p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align)
        self.segments = [struct.unpack_from("<IIQQQQQQ", data, phoff + i * phentsize) for i in range(phnum)]
        # (sh_name, sh_type, sh_flags, sh_addr, sh_offset, sh_size, sh_link, ...)
        headers = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]

        def string(table, offset):
            start = headers[table][4] + offset
            return data[start:data.index(b"\0", start)].decode()

        self.section_names = [string(shstrndx, h[0]) for h in headers]
        # name -> (address, size)
        self.sections = {name: (h[3], h[5]) for name, h in zip(self.section_names, headers)}
        # Defined global and weak symbols: name -> (value, size, section index).
        self.symbols = {}
        for h in headers:
            if h[1] != SHT_SYMTAB:
                continue
            for offset in range(h[4], h[4] + h[5], 24):
                st_name, info, _, shndx, value, size = struct.unpack_from("<IBBHQQ", data, offset)
                if shndx != 0 and info >> 4 in (STB_GLOBAL, STB_WEAK):
                    self.symbols[string(h[6], st_name)] = (value, size, shndx)

    def loads(self, address):
        """The flags of each loadable segment that holds `address`."""
        return [s[1] for s in self.segments if s[0] == PT_LOAD and s[3] <= address < s[3] + s[6]]


def verdict(name, failures, group="library"):
    """A verdict that passes when `failures` (a list of reasons) is empty."""
    return {"name": name, "group": group, "passed": not failures,
            "detail": "; ".join(failures) if failures else None}


def archive_members(path):
    """The (name, bytes) of each member of an ar archive, or None if `path`
    is not an ar archive. Skips the symbol and long-name tables."""
    data = Path(path).read_bytes()
    if not data.startswith(b"!<arch>\n"):
        return None
    members, long_names, pos = [], b"", 8
    while pos + 60 <= len(data):
        name = data[pos:pos + 16].decode(errors="replace").rstrip()
        size = int(data[pos + 48:pos + 58])
        body = data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)
        if name == "//":
            long_names = body
        elif name in ("/", "/SYM64/") or name.startswith("__.SYMDEF"):
            continue
        else:
            if re.fullmatch(r"/\d+", name):
                start = int(name[1:])
                name = long_names[start:long_names.index(b"\n", start)].decode(errors="replace")
            members.append((name.rstrip("/"), body))
    return members


def check_archive(library):
    """Each zkVM vendor must provide a static library (.a archive) targeting
    their zkVM: an ar archive whose object members are RISC-V ELF64 objects."""
    members = archive_members(library)
    if members is None:
        return [f"{Path(library).name} is not an ar archive"]
    objects = [(name, body) for name, body in members if body[:4] == b"\x7fELF"]
    if not objects:
        return [f"{Path(library).name} has no ELF object"]
    other = [name for name, body in objects
             if body[4] != 2 or struct.unpack_from("<H", body, 18)[0] != EM_RISCV]
    if other:
        return [f"{len(other)} of {len(objects)} objects are not RISC-V ELF64 objects (first: {other[0]})"]
    return []


def guest_elfs(out):
    """Every guest ELF that the build wrote under `out`, without the crafted
    variants of the elf group (elf/accept-*, elf/reject-*), which test the
    zkVM's loader, not the vendor's build."""
    return sorted(elf for elf in out.rglob("*.elf")
                  if not (elf.parent.name == "elf" and elf.name.startswith(("accept-", "reject-"))))


def check_reference(elfs, zkvm_run, profile, out, flag):
    """Each ELF passes `zkvm-run <flag>` (--validate: the zkVM reference's
    loader accepts it; --check-exec-decodes: it also decodes every word of its
    PF_X-only segments as an RV64IM instruction) under the zkVM's memory
    profile, with the stack range resolved from the ELF's symbols."""
    if not elfs:
        return ["no guest ELF was built"]
    failures = []
    with tempfile.TemporaryDirectory() as work:
        resolved = Path(work) / "profile.json"
        for elf in elfs:
            name = elf.relative_to(out)
            resolve = subprocess.run([sys.executable, str(Path(__file__).with_name("resolve_profile.py")),
                                      str(profile), str(elf), str(resolved)], capture_output=True, text=True)
            if resolve.returncode != 0:
                failures.append(f"{name}: {(resolve.stderr or resolve.stdout).strip()}")
                continue
            run = subprocess.run([str(zkvm_run), flag, str(resolved), str(elf)], capture_output=True, text=True)
            answer = run.stdout.strip()
            if run.returncode == 0 and answer == "OK":
                continue
            if (run.returncode, answer.split(" ")[0]) in ((2, "REJECT"), (3, "UNDECODABLE")):
                failures.append(f"{name}: {answer}")
            else:
                sys.exit(f"error: zkvm-run {flag} {elf}: exit {run.returncode}: {answer or run.stderr.strip()}")
    return failures


def requirement_lists():
    """check name -> requirement IDs (static-requirements.txt), keeping only
    the IDs of the standards in covered-standards.txt."""
    covered = set((HERE / "covered-standards.txt").read_text().split())
    table = {}
    for line in (HERE / "static-requirements.txt").read_text().splitlines():
        words = line.split("#", 1)[0].split()
        if words:
            table[words[0]] = [r for r in words[1:] if re.match(r"[A-Z]+", r).group(0) in covered]
    return table, covered


def missing(names, symbols):
    lost = [n for n in names if n not in symbols]
    return [f"not defined: {', '.join(lost)}"] if lost else []


def check_phdrs(script):
    """The linker script uses a PHDRS declaration."""
    text = re.sub(r"/\*.*?\*/", "", Path(script).read_text(), flags=re.S)
    return [] if re.search(r"\bPHDRS\s*\{", text) else ["the linker script has no PHDRS declaration"]


def check_entry(elfs, linker):
    """The linker script must set the ELF entry point to _start."""
    if not elfs:
        return [f"no runtime guest links with {linker}"]
    failures = []
    for path, elf in elfs:
        start = elf.symbols.get("_start")
        if start is None:
            failures.append(f"{path.stem}: _start is not defined")
        elif elf.entry != start[0]:
            failures.append(f"{path.stem}: e_entry {elf.entry:#x} is not _start ({start[0]:#x})")
    return failures


def check_heap_symbols(elfs, linker):
    """The linker script must define _heap_start and _heap_end. rt-heap-symbols
    references both, so a PROVIDE in the script also defines them there."""
    elf = next((elf for path, elf in elfs if path.stem.startswith("rt-heap-symbols")), None)
    if elf is None:
        return [f"rt-heap-symbols does not link with {linker}"]
    return missing(["_heap_start", "_heap_end"], elf.symbols)


def check_segments(probe, linker):
    """The linker script must assign the code sections to an executable,
    non-writable segment, and every read-only data section to a separate
    readable, non-executable segment. A section that the link discards is in
    no segment, so it cannot break the rule: SP1's script discards .eh_frame."""
    if not probe.exists():
        error = probe.with_suffix(".link-error")
        reason = f": {link_failure(error)}" if error.exists() else ""
        return [f"the probe rt-segments does not link with {linker}{reason}"]
    elf = Elf(probe)
    # What to check: (section, address, code).
    places = []
    for symbol, (section, code) in PROBE_SYMBOLS.items():
        if symbol not in elf.symbols:
            return [f"{symbol} ({section}) is not in the probe ELF"]
        places.append((section, elf.symbols[symbol][0], code))
    for name, (address, size) in elf.sections.items():
        if name.startswith(".eh_frame") and size > 0:
            places.append((name, address, False))
    unloaded, bad_code, bad_data = [], [], []
    for section, address, code in places:
        flags = elf.loads(address)
        if not flags:
            unloaded.append(section)
        elif code and any(not f & PF_X or f & PF_W for f in flags):
            bad_code.append(section)
        elif not code and any(not f & PF_R or f & PF_X for f in flags):
            bad_data.append(section)
    return [f"{what}: {', '.join(sections)}" for what, sections in [
        ("in no loadable segment", unloaded),
        ("code not in an executable, non-writable segment", bad_code),
        ("read-only data not in a readable, non-executable segment", bad_data),
    ] if sections]


def check_probe_object(path):
    """Stop if the probe object does not have its sections: then the segment
    check would not test them. This is a fault of the probe, not of the zkVM."""
    elf = Elf(path)
    for symbol, (section, _) in PROBE_SYMBOLS.items():
        found = elf.symbols.get(symbol)
        if found is None or elf.section_names[found[2]] != section:
            sys.exit(f"error: {path} has no {symbol} in {section}")
    if ".eh_frame" not in elf.sections:
        sys.exit(f"error: {path} has no .eh_frame")


def link_failure(path):
    """The first error line of a linker's output, else its first line, without
    the gcc driver's summary line and the linker's directory."""
    lines = [re.sub(r"^\S*/(ld|ld\.lld): ", r"\1: ", line.strip())
             for line in path.read_text(errors="replace").splitlines()
             if line.strip() and not line.startswith("collect2:")]
    errors = [line for line in lines if "error" in line or "undefined reference" in line]
    return ((errors or lines or ["no linker output"])[0])[:300]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", required=True)
    parser.add_argument("--linker-script")
    parser.add_argument("--probe-object", required=True)
    parser.add_argument("--zkvm-run", type=Path, help="the zkVM reference's zkvm-run")
    parser.add_argument("--profile", type=Path, help="the zkVM's profile.json")
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    if (args.zkvm_run is None) != (args.profile is None):
        parser.error("--zkvm-run and --profile go together")

    check_probe_object(args.probe_object)
    requirements, covered = requirement_lists()
    script = args.linker_script
    no_script = ["the zkVM supplies no linker script"]

    results = [
        verdict("lib-archive", check_archive(args.library)),
        verdict("lib-linker-script", [] if script else no_script),
        verdict("lib-script-phdrs", check_phdrs(script) if script else no_script),
    ]
    for linker, group, suffix in LINKERS:
        elfs = []
        for path in sorted((args.out / group).glob("*.link-error")):
            name = path.name.removesuffix(".link-error")
            results.append(verdict(name, [f"does not link with {linker}: {link_failure(path)}"], group))
        for path in sorted((args.out / group).glob("*.elf")):
            elfs.append((path, Elf(path)))
        probe = args.out / "library" / f"rt-segments{suffix}.probe"
        results += [
            verdict(f"lib-entry{suffix}", check_entry(elfs, linker) if script else no_script),
            verdict(f"lib-heap-symbols{suffix}", check_heap_symbols(elfs, linker) if script else no_script),
            verdict(f"lib-segments{suffix}", check_segments(probe, linker) if script else no_script),
        ]
    if args.zkvm_run:
        elfs = guest_elfs(args.out)
        results.append(verdict("static-validate", check_reference(elfs, args.zkvm_run, args.profile, args.out, "--validate")))
        # Only an execute-only zkVM needs its PF_X segments to hold nothing but instructions.
        if json.loads(args.profile.read_text())["exec_perm"] == "x":
            results.append(verdict("static-exec-decodes",
                                   check_reference(elfs, args.zkvm_run, args.profile, args.out, "--check-exec-decodes")))

    for r in results:
        if r["group"] == "library":
            if r["name"] not in requirements:
                sys.exit(f"error: {r['name']} has no line in static-requirements.txt")
            r["requirements"] = requirements[r["name"]]
        else:
            req = HERE / "runtime" / f"{r['name'].removesuffix('-lld')}.req"
            ids = req.read_text().split() if req.exists() else []
            r["requirements"] = [i for i in ids if re.match(r"[A-Z]+", i).group(0) in covered]

    out = args.out / "library" / "static-results.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(results, indent=2) + "\n")
    for r in results:
        print(f"  {'PASS' if r['passed'] else 'FAIL'} {r['name']}" + (f": {r['detail']}" if r["detail"] else ""))


if __name__ == "__main__":
    main()
