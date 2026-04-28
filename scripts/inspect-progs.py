#!/usr/bin/env python3
"""Dump the dprograms_t header of a Quake progs.dat.

Useful for sizing checks before pushing a file through our VM —
compares the file's `entityfields`, `numglobals`, etc. against the
limits compiled into src/Pr.HC (MAX_ENTITY_FIELDS, MAX_EDICTS,
MAX_STACK_DEPTH, LOCALSTACK_SIZE).

Usage: scripts/inspect-progs.py <path/to/progs.dat>
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

# Limits hard-coded in src/Pr.HC. Keep these in sync if the C source
# changes — the script is a pre-flight check, not a definitive source.
MAX_ENTITY_FIELDS = 256
MAX_EDICTS = 64
MAX_STACK_DEPTH = 32
LOCALSTACK_SIZE = 2048
PROG_VERSION = 6

HEADER_FIELDS = [
    "version", "crc",
    "ofs_statements", "numstatements",
    "ofs_globaldefs", "numglobaldefs",
    "ofs_fielddefs", "numfielddefs",
    "ofs_functions", "numfunctions",
    "ofs_strings", "numstrings",
    "ofs_globals", "numglobals",
    "entityfields",
]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <progs.dat>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    raw = path.read_bytes()
    if len(raw) < 60:
        print(f"{path}: too small to be a progs.dat ({len(raw)} bytes)",
              file=sys.stderr)
        return 1
    fields = dict(zip(HEADER_FIELDS, struct.unpack("<15i", raw[:60])))
    width = max(len(k) for k in HEADER_FIELDS)
    print(f"{path}  ({len(raw):,} bytes)")
    for k in HEADER_FIELDS:
        print(f"  {k:<{width}}  {fields[k]:>10,}")

    print()
    print("== compatibility ==")
    issues = []
    if fields["version"] != PROG_VERSION:
        issues.append(f"version {fields['version']} != {PROG_VERSION}")
    if fields["entityfields"] > MAX_ENTITY_FIELDS:
        issues.append(
            f"entityfields {fields['entityfields']} > "
            f"MAX_ENTITY_FIELDS {MAX_ENTITY_FIELDS}"
        )
    # Loader bounds-checks ofs_* + count*sizeof against the buffer.
    # On disk this is only sanity — the live loader catches this.
    for tag, ofs, n, stride in [
        ("statements", fields["ofs_statements"], fields["numstatements"], 8),
        ("functions",  fields["ofs_functions"],  fields["numfunctions"], 36),
        ("globals",    fields["ofs_globals"],    fields["numglobals"], 4),
    ]:
        end = ofs + n * stride
        if end > len(raw):
            issues.append(f"{tag} table extends past EOF ({end} > {len(raw)})")
    if issues:
        for i in issues:
            print(f"  ! {i}")
        return 1
    print("  ok — should load")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
