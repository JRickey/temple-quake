// Bootstrap.HC — foundation: shared helpers + temporary stubs for
// Quake subsystems we haven't ported yet. Named to sort FIRST in
// src/ alphabetical order so every other module sees Q_strcmp,
// Z_Malloc, Con_Printf, etc. defined when it compiles via ExePutS.
//
// The stub list shrinks as we port more modules. When a module is
// ported, DELETE the corresponding stub here and let the real
// implementation take over.

// ----------------------------------------------------------------
// Memory: Z_Malloc / Z_Free / Q_memcpy
// ----------------------------------------------------------------
//
// Quake's zone allocator (zone.c) is a custom pool over a fixed
// hunk. We delegate to TempleOS's MAlloc/Free for now — same API
// shape. zone.c port will replace this.

U8 *Z_Malloc(I64 size) {
  return MAlloc(size);
}

U0 Z_Free(U8 *p) {
  Free(p);
}

// ----------------------------------------------------------------
// String helpers: Q_strcmp / Q_strncmp / Q_strlen / Q_strcpy
// ----------------------------------------------------------------
//
// Quake's Q_* string ops are thin wrappers around standard C str*
// (for portability across compilers that disagreed on signedness).
// HolyC's StrCmp/StrLen/StrCpy match the canonical semantics.
// Q_strncmp is missing — we provide it directly here.

I64 Q_strcmp(U8 *a, U8 *b) {
  return StrCmp(a, b);
}

I64 Q_strncmp(U8 *a, U8 *b, I64 n) {
  // Standard strncmp: compare at most n bytes; stop at first mismatch
  // or NUL; return 0 if equal up to n, else sign of (a[i]-b[i]).
  I64 i;
  for (i = 0; i < n; i++) {
    U8 ca = a[i];
    U8 cb = b[i];
    if (ca != cb) {
      return ca - cb;
    }
    if (ca == 0) {
      return 0;
    }
  }
  return 0;
}

I64 Q_strlen(U8 *s) {
  return StrLen(s);
}

U0 Q_strcpy(U8 *dst, U8 *src) {
  StrCpy(dst, src);
}

// Q_atof: very small float parser. Quake's `atof` allows a leading
// `'X'` char-constant form (`'AB'` → multi-char int packed) plus
// hex (`0xNN`), but in practice cvar values are always decimal —
// the corner cases are out of scope for the cvar port.
F64 Q_atof(U8 *s) {
  F64 sign = 1.0;
  F64 value = 0.0;
  F64 frac = 0.0;
  F64 fracdiv = 1.0;
  I64 i = 0;
  if (s[0] == '-') {
    sign = -1.0;
    i = 1;
  } else if (s[0] == '+') {
    i = 1;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    value = value * 10.0 + (s[i] - '0');
    i++;
  }
  if (s[i] == '.') {
    i++;
    while (s[i] >= '0' && s[i] <= '9') {
      fracdiv = fracdiv * 10.0;
      frac = frac * 10.0 + (s[i] - '0');
      i++;
    }
    value = value + (frac / fracdiv);
  }
  return sign * value;
}

// ----------------------------------------------------------------
// Console: Con_Printf
// ----------------------------------------------------------------
//
// Real Con_Printf prints to the in-game console + screen. For now
// route to TempleOS's Print (screen) and CommPrint(1, ...) (serial)
// so test runs see the messages.

U0 Con_Printf(U8 *msg) {
  Print("%s", msg);
  CommPrint(1, "%s", msg);
}

// ----------------------------------------------------------------
// Command system: Cmd_Argc / Cmd_Argv / Cmd_Exists
// ----------------------------------------------------------------
//
// Replaced when we port cmd.c. Stubs return "no args, nothing
// exists" so cvar.c paths that call these treat the command system
// as empty.

I64 Cmd_Argc() {
  return 0;
}

U8 *Cmd_Argv(I64 idx) {
  // Return a stable empty string. Callers compare to "" or use the
  // result as a cvar name lookup that will fail to find anything.
  return "";
}

Bool Cmd_Exists(U8 *name) {
  return FALSE;
}

// ----------------------------------------------------------------
// Server: SV_BroadcastPrintf, sv.active
// ----------------------------------------------------------------
//
// Replaced when we port the server. For now there's no active
// server, so cvar's broadcast-on-change path becomes a no-op.

class CSvStubState {
  Bool active;
};

CSvStubState sv;

U0 SV_BroadcastPrintf(U8 *fmt, U8 *a, U8 *b) {
  // Variadic — Quake passes (name, value). We accept (fmt, a, b) and
  // forward to Print + CommPrint as a no-op-with-trace.
  Print(fmt, a, b);
  CommPrint(1, fmt, a, b);
}
