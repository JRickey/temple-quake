#!/usr/bin/env python3
"""Inject a binary file into the running TempleOS VM via the daemon.

The daemon accepts HolyC source over COM2 and ExePutS it. To get
binary data in, this script reads a local file, hex-encodes each
byte (2 chars), and pushes batches of `PR_InjectChunk(hex, off, n);`
statements through `scripts/send.py`. After the last byte lands,
`PR_InjectFinish(vm_path);` writes the buffer to disk via
TempleOS's FileWrite.

Pre-requisites:
- VM up and daemon running (`make dev-temple` then daemon types
  `D_OK` to COM1).
- src/Pr.HC pushed (provides _pr_inject_buf + PR_InjectChunk +
  PR_InjectFinish).

Usage:
    scripts/inject-progs.py <local-path> <vm-path>
    scripts/inject-progs.py qwprogs.dat ::/Tmp/qwprogs.dat
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

# Bytes of binary per PR_InjectChunk call. Each chunk emits ~2*N
# chars of hex + ~50 chars overhead. 4 KB binary → ~8 KB hex per
# call, comfortably under the daemon's COM2 line buffer.
CHUNK = 4096

# How many PR_InjectChunk calls to bundle per send.py invocation.
# More calls per push = fewer round-trips but bigger source.
# 8 calls → ~64 KB of source per push, ~32 KB of binary.
CALLS_PER_PUSH = 8

REPO = Path(__file__).resolve().parent.parent
SEND = REPO / "devkit" / "scripts" / "send.py"


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <local-path> <vm-path>", file=sys.stderr)
        return 2
    src = Path(argv[1])
    dst = argv[2]
    if not src.exists():
        print(f"error: {src} not found", file=sys.stderr)
        return 2
    data = src.read_bytes()
    n_bytes = len(data)
    n_chunks = (n_bytes + CHUNK - 1) // CHUNK
    n_pushes = (n_chunks + CALLS_PER_PUSH - 1) // CALLS_PER_PUSH
    print(f"injecting {n_bytes:,} bytes from {src} → {dst}")
    print(f"  {n_chunks} chunks × {CHUNK} B, {n_pushes} pushes "
          f"× {CALLS_PER_PUSH} chunks")

    chunk_idx = 0
    for push_i in range(n_pushes):
        # Build a single source string with up to CALLS_PER_PUSH
        # PR_InjectChunk statements. Each statement runs in the
        # daemon's ExePutS pass.
        stmts = []
        for _ in range(CALLS_PER_PUSH):
            if chunk_idx >= n_chunks:
                break
            offset = chunk_idx * CHUNK
            chunk = data[offset:offset + CHUNK]
            hex_str = chunk.hex()
            stmts.append(
                f'PR_InjectChunk("{hex_str}",{offset},{len(chunk)});')
            chunk_idx += 1
        source = "".join(stmts)
        rc = subprocess.run(
            [str(SEND), source, "--enter", "--delay", "0.001"],
            check=False,
        )
        if rc.returncode != 0:
            print(f"error: send.py failed at push {push_i+1}",
                  file=sys.stderr)
            return 1
        print(f"  push {push_i+1}/{n_pushes} ({chunk_idx}/{n_chunks} "
              f"chunks, {chunk_idx*CHUNK:,} B)", flush=True)

    # Flush the buffer to disk on the VM.
    flush = f'if (PR_InjectFinish("{dst}")) {{ "INJECT_OK\\n"; }} else {{ "INJECT_FAIL\\n"; }}'
    rc = subprocess.run(
        [str(SEND), flush, "--enter", "--delay", "0.001"],
        check=False,
    )
    if rc.returncode != 0:
        print("error: flush failed", file=sys.stderr)
        return 1
    print(f"flushed → {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
