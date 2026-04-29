#!/usr/bin/env python3
"""Inject a binary file into the running TempleOS VM via the daemon.

Pushes hex-encoded `PR_InjectChunk(...)` statements over the
daemon's COM2 socket — much faster than typing each char via the
QEMU monitor. Requires:

  * VM up (`make dev-temple`)
  * `src/Pr.HC` already pushed (provides PR_InjectChunk +
    PR_InjectFinish + _pr_inject_buf)
  * Daemon listening on COM2 (use `scripts/daemon-up.py` to bring
    it back if `temple-run.py --launch=""` exited it)

Usage:
    scripts/inject-progs.py <local-path> <vm-path>
    scripts/inject-progs.py qwprogs.dat ::/Tmp/qwprogs.dat
"""
from __future__ import annotations

import os
import socket
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
COM2 = Path(os.environ.get(
    "COM2_SOCK", REPO / "devkit" / "build" / "com2-temple.sock"))
LOG = Path(os.environ.get(
    "SERIAL_LOG", REPO / "devkit" / "build" / "serial-temple.log"))

# 4 KB binary per PR_InjectChunk → 8 KB hex per call
CHUNK = 4096
# Bundle 8 calls per COM2 push for throughput
CALLS_PER_PUSH = 8


def log_size() -> int:
    try:
        return LOG.stat().st_size
    except FileNotFoundError:
        return 0


def push_chunk(payload: bytes) -> None:
    """Send raw bytes to COM2, then EOT (mirrors temple-run.py)."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(COM2))
        for i in range(0, len(payload), 1024):
            s.sendall(payload[i:i + 1024])
            time.sleep(0.01)
        s.sendall(b"\x04")


def wait_for_token(token: str, since: int, timeout: float = 30.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with LOG.open("rb") as f:
                f.seek(since)
                data = f.read()
                if token.encode() in data:
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    return False


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} <local-path> <vm-path>", file=sys.stderr)
        return 2
    src = Path(argv[1])
    dst = argv[2]
    if not src.exists():
        print(f"error: {src} not found", file=sys.stderr)
        return 2
    if not COM2.exists():
        print(f"error: COM2 socket {COM2} not found — VM not up?",
              file=sys.stderr)
        return 1

    data = src.read_bytes()
    n_bytes = len(data)
    n_chunks = (n_bytes + CHUNK - 1) // CHUNK
    n_pushes = (n_chunks + CALLS_PER_PUSH - 1) // CALLS_PER_PUSH
    print(f"injecting {n_bytes:,} bytes from {src} → {dst}")
    print(f"  {n_chunks} chunks × {CHUNK} B, {n_pushes} pushes "
          f"× {CALLS_PER_PUSH} chunks")

    chunk_idx = 0
    for push_i in range(n_pushes):
        stmts = []
        for _ in range(CALLS_PER_PUSH):
            if chunk_idx >= n_chunks:
                break
            offset = chunk_idx * CHUNK
            chunk = data[offset:offset + CHUNK]
            stmts.append(
                f'PR_InjectChunk("{chunk.hex()}",{offset},'
                f'{len(chunk)});')
            chunk_idx += 1
        # The daemon ExePutS each pushed chunk and emits D_DONE.
        # Wait for it before sending the next batch so the FIFO
        # doesn't overflow.
        since = log_size()
        push_chunk("".join(stmts).encode())
        if not wait_for_token("D_DONE", since, timeout=60.0):
            print(f"!! timeout on push {push_i+1}/{n_pushes}",
                  file=sys.stderr)
            return 1
        print(f"  push {push_i+1}/{n_pushes} "
              f"({chunk_idx}/{n_chunks}, {chunk_idx*CHUNK:,} B)",
              flush=True)

    # Flush + verify
    since = log_size()
    flush = (
        f'CommPrint(1,"INJECT_BEGIN\\n");'
        f'if (PR_InjectFinish("{dst}")) {{ '
        f'CommPrint(1,"INJECT_OK\\n"); }} else {{ '
        f'CommPrint(1,"INJECT_FAIL\\n"); }}'
    )
    push_chunk(flush.encode())
    if not wait_for_token("INJECT_OK", since, timeout=30.0):
        print("!! INJECT_OK not seen after flush", file=sys.stderr)
        return 1
    print(f"flushed → {dst}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
