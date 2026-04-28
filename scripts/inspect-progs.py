#!/usr/bin/env python3
"""Dump the dprograms_t header of a Quake progs.dat plus the
builtin-index frequency histogram.

Useful for sizing checks before pushing a file through our VM —
compares the file's `entityfields`, `numglobals`, etc. against the
limits compiled into src/Pr.HC, and tells you which builtin
indices a real progs is going to dispatch (so you know which ones
to install before trying to execute it).

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

    # ---- builtin frequency histogram ----
    # Each dfunction_t is 36 bytes laid out as:
    #   i32 first_statement, parm_start, locals, profile,
    #   i32 s_name, s_file, numparms,
    #   u8 parm_size[8]
    # first_statement < 0 → builtin; |first_statement| is the index.
    # We also need the strings pool to print human names.
    nfn = fields["numfunctions"]
    fn_off = fields["ofs_functions"]
    str_off = fields["ofs_strings"]
    builtin_calls: dict[int, str] = {}
    for i in range(nfn):
        b = raw[fn_off + i * 36 : fn_off + (i + 1) * 36]
        first = struct.unpack("<i", b[:4])[0]
        if first < 0:
            s_name = struct.unpack("<i", b[16:20])[0]
            # Read NUL-terminated name from strings pool.
            end = raw.index(b"\x00", str_off + s_name)
            name = raw[str_off + s_name : end].decode("ascii", "replace")
            idx = -first
            builtin_calls[idx] = name

    if builtin_calls:
        print()
        print(f"== builtins referenced ({len(builtin_calls)}) ==")
        # The set installed in src/Pr.HC's _PR_DispatchBuiltin. Keep
        # in sync — this is a pre-flight checklist, the live VM is
        # the source of truth.
        installed = {1, 2, 3, 4,
                     6, 7, 9, 10, 11, 12, 13, 14, 15, 16,
                     18, 19, 20, 21, 22, 25, 26,
                     27, 28, 29, 30, 31, 32, 34,
                     36, 37, 38, 40, 41, 43, 44, 45, 46, 49, 51,
                     52, 53, 54, 55, 56, 57, 58, 59,
                     68, 69, 72, 74, 75, 76, 77, 78, 80, 81}
        rows: list[tuple[int, str, str]] = []
        for idx in sorted(builtin_calls):
            mark = "ok" if idx in installed else "MISSING"
            rows.append((idx, builtin_calls[idx], mark))
        idx_w = max(len(str(i)) for i, _, _ in rows)
        name_w = max(len(n) for _, n, _ in rows)
        for idx, name, mark in rows:
            print(f"  #{idx:<{idx_w}}  {name:<{name_w}}  {mark}")
        missing = [i for i, _, m in rows if m == "MISSING"]
        if missing:
            print()
            print(f"  ! {len(missing)} of {len(rows)} builtins not yet "
                  f"installed in our VM — add to _PR_DispatchBuiltin "
                  f"before executing this progs.")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
