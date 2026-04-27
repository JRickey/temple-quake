# CLAUDE.md — agent guide for temple-quake

A HolyC port of id Software's Quake to TempleOS. The Quake C source
lives in `quake-src/` (submodule, read-only id-Software/Quake mirror).
The HolyC port lives in `src/` and `tests/`. The dev tooling (test
loop, lint, host parser) is in `devkit/` (submodule, the upstream
`rshtirmer/templeos-devkit`).

## File extension convention

**All HolyC files we write use TempleOS-native extensions.**

- `.HC` — HolyC source (functions, top-level executable code)
- `.HH` — HolyC header (forward declarations, shared constants)

Don't use `.ZC` for new files. `.ZC` is the ZealOS dialect; pure
TempleOS uses `.HC`. The devkit's tooling (since `rshtirmer/templeos-devkit`
PR #19) accepts both, but our convention is `.HC` for everything we
author. If a symlink points at the devkit's `Assert.ZC`, name the
local symlink `Assert.HC` so the tree reads cleanly.

## Layout

```
src/             our HolyC port (.HC files)
tests/           test framework symlink + T_*.HC battery
quake-src/       id Software Quake (read-only reference)
devkit/          upstream dev tooling (lint, daemon, holycc parser)
build/           VM artefacts (gitignored)
```

## Dev loop

```sh
make lint            # holyc-lint.py (regex) + holycc (Rust parser, if built)
make dev-temple      # boot TempleOS in QEMU autonomously
make test            # push src/ + tests/T_*.HC, parse PASS/FAIL from serial log
make test T=Math     # filter to T_*Math*.HC
make down            # stop the VM
```

The COM1 error capture (devkit PR #8) means HolyC parser errors land
in `devkit/build/serial-temple.log` between `COMPILE_ERR_BEGIN` /
`COMPILE_ERR_END` markers — no screenshot OCR needed for compile
errors. Keep watching that log when iterating.

## Porting workflow

1. Pick a small Quake module in `quake-src/WinQuake/foo.c`.
2. Read it. Note macros (`#define`s), comma-separated decls, exponent
   floats, and any TempleOS reserved names (`pi`, `eps`, `inf`, etc.)
   that collide with Quake variable names.
3. Port to `src/Foo.HC` following:
   - `vec_t = F64` (HolyC has no F32; widen at I/O boundary later)
   - Function-form ops only (no parametrized `#define` macros — they
     don't expand reliably under ExePutS)
   - All `if`-bodies braced (one-line unbraced trips the boot-phase
     parser per devkit/CLAUDE.md)
   - Each variable on its own line (no `F64 a, b;` even at function
     scope — portable across both ExePutS and AOT paths)
   - Plain decimal float literals (no `1e-9` exponent form — also
     `eps` is reserved)
4. Add `tests/T_Foo.HC` exercising every public function.
5. `make lint && make test T=Foo` until green.
6. Commit. Each port is one commit; mention which `.c` file it covers.

## Known TempleOS reserved names

These cannot be used as parameter / local variable names without
shadowing failures (PrsType chokes, the value gets resolved to the
constant before the type slot can fill):

- `eps` — machine epsilon (≈ 2.22e-16)
- `pi`  — 3.14159...
- `inf`, `nan` — special F64 constants
- `tS`  — seconds-since-boot global (ZealOS only; harmless on TempleOS)
- `ms`  — mouse global
- `cnts.jiffies` — kernel counters

When porting, scan for these names. If Quake uses `eps` as a local,
rename to `tol`/`epsilon`. Add new names here as we discover them.

## Repo links

- Parent: https://github.com/JRickey/temple-quake
- Devkit: https://github.com/rshtirmer/templeos-devkit
- Reference: https://github.com/id-Software/Quake (WinQuake/)
