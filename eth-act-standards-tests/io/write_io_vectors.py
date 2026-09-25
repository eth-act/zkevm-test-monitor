#!/usr/bin/env python3
"""Write the I/O test vectors next to the I/O test ELFs.

Usage: write_io_vectors.py <out-dir>

An I/O test vector is a test's private input (<name>.input) and its expected
public output (<name>.expected). They are defined here, so the guest sources
stay small. A test without one of the two files gets the runner's default:
empty input, or the verdict "PASS" as expected output.
"""

import sys
from pathlib import Path


def pattern(n):
    """Match io_pattern() in pattern.h."""
    return bytes((i * 37 + 11 + (i >> 8)) & 0xFF for i in range(n))


PASS = b"PASS"

# name -> (input bytes or None, expected output bytes or None)
CASES = {
    "io-read-empty": (b"", None),
    "io-read-one-byte": (b"\xa5", None),
    "io-read-unaligned-length": (pattern(13), None),
    "io-read-large": (pattern(65536 + 5), None),
    "io-read-idempotent": (pattern(24), None),
    "io-echo": (pattern(37), pattern(37)),
    "io-write-split": (None, pattern(64)),
    "io-write-byte-at-a-time": (None, pattern(64)),
    "io-write-zero-length": (None, pattern(10)),
    "io-write-257-bytes": (None, pattern(257)),
    "io-write-1024-bytes": (None, pattern(1024)),
}


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, (data_in, data_out) in CASES.items():
        if not (out / f"{name}.elf").exists():
            sys.exit(f"write_io_vectors.py: no ELF for {name} in {out}")
        if data_in is not None:
            (out / f"{name}.input").write_bytes(data_in)
        if data_out is not None:
            (out / f"{name}.expected").write_bytes(data_out)


if __name__ == "__main__":
    main()
