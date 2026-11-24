#!/usr/bin/env python3
"""Check that every monitor-tested requirement of the covered standards has a test.

Usage: check_requirements.py [--standards DIR]   (from the repository root)

DIR is an eth-act/zkevm-standards checkout (default: out/deps/zkevm-standards,
which src/run-eth-act-standards-tests.sh fetches at the commit config.json
pins). Each standard's README has a "Normative requirements" table of IDs; its
"Checked by" column says `monitor` (a guest test here) or `monitor-static` (a
static check here) for the requirements this repository tests.

For every prefix in tests/eth-act-standards/covered-standards.txt, each ID
checked by `monitor` or `monitor-static` must be named by a `.req` file (a
test's sidecar: whitespace-separated IDs, anywhere under tests/) or by a static
check in tests/eth-act-standards/static-requirements.txt (lines
`<check> <ID>...`). Fails, one line per problem, if one is not, or if a `.req`
file or a static check names an ID that no table defines.
"""
import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path.cwd()
HERE = ROOT / "tests" / "eth-act-standards"
HEADING = "## Normative requirements"


def cells(line):
    return [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]


def top_level_items(text):
    items, depth, cur = [], 0, ""
    for ch in text:
        depth += (ch == "(") - (ch == ")")
        if ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    return [i for i in items + [cur.strip()] if i]


def requirements(standards):
    """{id: monitor-tested?} for every row of every requirements table."""
    ids = {}
    for path in sorted((standards / "standards").rglob("*.md")):
        lines = path.read_text().splitlines()
        if HEADING not in lines:
            continue
        i = lines.index(HEADING) + 1
        while i < len(lines) and not lines[i].lstrip().startswith("|"):
            i += 1
        col = cells(lines[i]).index("Checked by")
        for line in lines[i + 2:]:
            if not line.lstrip().startswith("|"):
                break
            row = cells(line)
            ids[row[0]] = any(item.startswith("monitor") for item in top_level_items(row[col]))
    return ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--standards", type=pathlib.Path, default=ROOT / "out" / "deps" / "zkevm-standards")
    args = ap.parse_args()
    ids = requirements(args.standards)
    if not ids:
        sys.exit(f"no requirements tables under {args.standards}/standards")
    covered = (HERE / "covered-standards.txt").read_text().split()
    problems = []
    mentioned = set()
    for req in sorted((ROOT / "tests").rglob("*.req")):
        for rid in req.read_text().split():
            mentioned.add(rid)
            if rid not in ids:
                problems.append(f"{req.relative_to(ROOT)}: unknown requirement {rid}")
    static = HERE / "static-requirements.txt"
    if static.exists():
        for line in static.read_text().splitlines():
            words = line.split("#", 1)[0].split()
            for rid in words[1:]:
                mentioned.add(rid)
                if rid not in ids:
                    problems.append(f"{static.relative_to(ROOT)}: {words[0]}: unknown requirement {rid}")
    count = 0
    for rid, monitored in ids.items():
        prefix = re.match(r"[A-Z]+", rid).group(0)
        if prefix in covered and monitored:
            count += 1
            if rid not in mentioned:
                problems.append(f"{rid} is checked by the monitor but no .req file or static check names it")
    for p in problems:
        print(p)
    if problems:
        sys.exit(1)
    print(f"requirements: {count} monitor-tested ids of {' '.join(covered) or 'no standard'}, all covered")


if __name__ == "__main__":
    main()
