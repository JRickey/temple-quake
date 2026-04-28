# temple-quake

A HolyC port of id Software's Quake to TempleOS.

```
quake-src/                     src/                                 tests/
─────────────                  ────                                 ──────
WinQuake/mathlib.c       →     QuakeMath.HC                         T_QuakeMath.HC
WinQuake/zone.c          →     Zone.HC                              T_Zone.HC
WinQuake/wad.c           →     Wad.HC                               T_Wad.HC
WinQuake/cmd.c           →     Cmd.HC                               T_Cmd.HC
WinQuake/cvar.c          →     Cvar.HC                              T_Cvar.HC
WinQuake/common.c        →     Common.HC                            T_Common.HC
WinQuake/crc.c           →     CRC.HC                               T_CRC.HC
WinQuake/pr_exec.c       →     Pr.HC (QuakeC bytecode VM)           T_Pr.HC + smoke + integration + inject
WinQuake/host_*.c        →     Bootstrap.HC (helpers + stubs)
```

## Status

**375 tests passing on TempleOS via QEMU.** The QuakeC bytecode VM
is the deepest piece so far — 100% dispatch coverage of the 68
builtins QuakeWorld's stock `qwprogs.dat` references, all opcodes
implemented, end-to-end integration validated through a synthetic
multi-function progs that runs `precache_model → spawn → setorigin
→ makevectors → vlen → traceline → bprint → OP_STATE → RETURN` in
one bytecode run.

What's NOT yet ported: the engine itself (renderer, network,
client/server loop). The VM is the heart of QuakeC; the rest is
C-to-HolyC translation work that's mechanical once the VM is
solid.

## Layout

```
src/             our HolyC port (.HC files)
  Bootstrap.HC   shared helpers + stubs (sorts first; pushed first)
  Cmd.HC         command-buffer
  Common.HC      common utilities (Q_strcmp, COM_LoadFile, etc.)
  CRC.HC         CRC-16 helper
  Cvar.HC        console-variable system
  Pr.HC          QuakeC VM (~1700 LOC, the big one)
  QuakeMath.HC   vec3 math
  Wad.HC         WAD file parser
  Zone.HC        zone allocator + hunk + cache
tests/           T_*.HC battery, ~375 assertions on TempleOS
quake-src/       id Software Quake (read-only mirror, submodule)
devkit/          upstream `rshtirmer/templeos-devkit` (submodule)
scripts/         host-side tools (inspect-progs.py, inject-progs.py)
docs/            port plans + design notes
build/           VM artifacts (gitignored)
```

## Dev loop

```sh
make lint            # holyc-lint.py (regex) + holycc (Rust parser)
make dev-temple      # boot TempleOS in QEMU autonomously
make test            # push src/ + tests/T_*.HC, parse PASS/FAIL
make test T=Pr       # filter to T_*Pr*.HC
make down            # stop the VM
```

`make lint` runs in <1s and catches most issues before VM round-trip
(~30-90s). The host parser at `devkit/holyc-parser/` is a Rust
re-implementation of TempleOS's lexer + parser tuned to be
**bug-compatible** with the real compiler — if the lint passes,
the VM accepts it.

For larger test batteries, bump the daemon push timeout:

```sh
PUSH_TIMEOUT=300 make test T=Pr   # default 60s; T_Pr.HC needs ~75s
```

## Try the VM

To see the QuakeC VM run a real-shape program:

```sh
make test T=PrIntegration
```

This builds a 4 KB synthetic progs.dat in memory exercising 12
canonical Quake builtins through 27 statements, watches the
edict pool get mutated, and verifies the trace_* result block,
v_forward unit vector, vlen of (10,20,30) ≈ 37.4, and so on.

To push QuakeWorld's actual `qwprogs.dat` (197 KB) into the VM
filesystem and load it:

```sh
make dev-temple
scripts/inject-progs.py \
    quake-src/QW/progs/qwprogs.dat \
    ::/Tmp/qwprogs.dat                # ~30s
# Then in-VM (via scripts/zctl eval or push-and-run):
PR_LoadProgsFromFile("::/Tmp/qwprogs.dat");
PR_ExecuteProgram(<main_fnum>);
```

## Phase ledger

| Phase | What | Status |
|---|---|---|
| 1 | mathlib.c port | ✅ |
| 2 | small modules (cvar/cmd/zone/wad/common/crc) | ✅ |
| 3 | pr_exec.c MVP — 20 opcodes | ✅ |
| 4 | OP_CALL + Tier-1 builtins + smoke test | ✅ |
| 5 | globalvars overlay + symbolic fields + OP_STATE mutation | ✅ |
| 6 | 100% qwprogs.dat builtin coverage (8 batches × ~6 builtins) | ✅ |
| 7a | kitchen-sink integration test | ✅ |
| 7b | host→VM binary file injection | ✅ |
| 8 | actually run a real progs.dat end-to-end | next |
| 9+ | engine layers (renderer, server) | future |

## HolyC quirks worth knowing

These are documented in `CLAUDE.md` and as test cases / lint
rules in our parser. Most surfaced during porting:

- **No F32**: HolyC has only F64. The QuakeC VM still treats
  globals as 4-byte slots, so we widen on read and narrow on
  write via IEEE-754 bit conversion (`_PR_F32_to_F64`,
  `_PR_F64_to_F32`).
- **Bitwise on F64 acts on IEEE bits, not the truncated int.**
  `_PR_GetFloat(slot) & 0xFF` masks the bit pattern; route
  through an explicit `I64 vi = float_val;` first. Lint rule
  `f64-bitwise` catches this (operand-aware as of devkit PR #39).
- **Postfix typecast `expr(I64)` is bit reinterpretation, not
  numeric conversion.** Use `Floor()` / `Ceil()` for integer
  rounding.
- **No parametrized `#define`** — we replaced macros with
  out-of-line functions.
- **Adjacent string-literal concatenation** isn't supported by
  our parser (and shouldn't be relied upon in HolyC).
- **Switch case bodies share scope** AND **sibling braced
  blocks at function scope share scope** (caught by lint rules
  `switch-case-shared-scope` + `block-shared-scope` from devkit
  PR #40). Use distinct names per block.
- **No exponent float literals** (`1e-9` chokes the parser);
  use plain decimals.
- **Reserved names**: `pi`, `eps`, `inf`, `nan`, `tS`, `ms`
  collide as variable names.
- **`offset`, `start`, `end`, `reg`, `noreg`** are
  context-dependent keywords — only special in expression /
  declaration positions (devkit PRs #33 + #38).

## Workflow rule: every quirk goes upstream

When porting work surfaces a HolyC quirk that isn't already
caught offline, the fix ships **upstream into the devkit** so
every future HolyC project benefits. Each tool owns a different
domain:

- **`holycc` (Rust parser)**: semantic errors, scope-aware
  checks, name resolution, type-aware lint
- **`holyc-lint.py` (Python regex)**: lex-level errors,
  formatting, cheap heuristic warnings

This session's upstream PRs to `rshtirmer/templeos-devkit`:

- #28 arity-mismatch lint + fn-pointer arrays at file scope
- #29 coverage tests for HolyC-specific modifiers + case ranges
- #30 housekeeping — drop stub modules, add CLI + preproc tests
- #31 accept `;` as parameter separator (kernel quirk)
- #32 accept empty default-arg slots in calls
- #33 `offset` is a contextual keyword
- #34 builtins manifest fix — `ATan` spelling
- #35 per-declarator `*` prefix in comma-decl lists
- #36 comma in `for(init; cond; update)` clauses
- #37 `#`-directives accepted inside function bodies
- #38 `start` / `reg` / `noreg` are contextual keywords
- #39 f64-bitwise rule checks operand types, not LHS context
- #40 shared-scope lint generalizes to all sibling braced blocks
- #41 configurable per-chunk push timeout

## Repo links

- This: https://github.com/JRickey/temple-quake
- Devkit: https://github.com/rshtirmer/templeos-devkit
- Reference: https://github.com/id-Software/Quake (WinQuake/)

## Why

Because TempleOS is a non-virtualized 64-bit ring-0
single-address-space single-language operating system written by
one programmer over a decade, and Quake is a real-time
networked 3D shooter from 1996. They were never supposed to
meet, but here we are.

The journey is the point. Each ported module has surfaced a
HolyC quirk our dev tooling now catches, and the upstream
`templeos-devkit` parser has gotten meaningfully better as a
side effect — currently 600+ tests, 100% pass, 0 false
positives on this 22-file port.
