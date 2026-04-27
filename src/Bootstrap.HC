// Bootstrap.HC — foundation: shared helpers + temporary stubs for
// Quake subsystems we haven't ported yet. Named to sort FIRST in
// src/ alphabetical order so every other module sees Q_strcmp,
// Z_Malloc, Con_Printf, etc. defined when it compiles via ExePutS.
//
// The stub list shrinks as we port more modules. When a module is
// ported, DELETE the corresponding stub here and let the real
// implementation take over.

// ----------------------------------------------------------------
// Memory: Z_Malloc / Z_Free
// ----------------------------------------------------------------
//
// Quake's zone allocator was a custom small-block allocator over
// a fixed hunk. On TempleOS the kernel's MAlloc/Free already do
// what's needed; the Zone API is a shim. Zone.HC ports the rest
// of the Hunk_/Cache_ surface; these two stay here in Bootstrap
// because every consumer uses them.
//
// Quake spec: Z_Malloc returns ZERO-FILLED memory. Don't drop the
// MemSet — callers (cvar.c, cmd.c, …) rely on it for clean state.

U8 *Z_Malloc(I64 size) {
  U8 *p = MAlloc(size);
  if (p) {
    MemSet(p, 0, size);
  }
  return p;
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

// strncpy semantics: copy up to n bytes; if src is shorter than n,
// pad the remainder with NUL. Standard C library behavior.
U0 Q_strncpy(U8 *dst, U8 *src, I64 n) {
  I64 i = 0;
  while (i < n && src[i]) {
    dst[i] = src[i];
    i++;
  }
  while (i < n) {
    dst[i] = 0;
    i++;
  }
}

U0 Q_strcat(U8 *dst, U8 *src) {
  I64 i = StrLen(dst);
  I64 j = 0;
  while (src[j]) {
    dst[i + j] = src[j];
    j++;
  }
  dst[i + j] = 0;
}

U8 *Q_strrchr(U8 *s, I64 c) {
  // Last occurrence of byte `c` in s, or NULL. Per C: a search for
  // '\0' returns the pointer to the terminator.
  U8 *last = NULL;
  I64 i = 0;
  while (TRUE) {
    if (s[i] == c) {
      last = &s[i];
    }
    if (!s[i]) {
      break;
    }
    i++;
  }
  return last;
}

I64 Q_strcasecmp(U8 *a, U8 *b) {
  // Case-insensitive ASCII compare.
  I64 i = 0;
  I64 ca;
  I64 cb;
  while (TRUE) {
    ca = a[i];
    cb = b[i];
    if (ca >= 'A' && ca <= 'Z') {
      ca = ca + ('a' - 'A');
    }
    if (cb >= 'A' && cb <= 'Z') {
      cb = cb + ('a' - 'A');
    }
    if (ca != cb) {
      return ca - cb;
    }
    if (!ca) {
      return 0;
    }
    i++;
  }
  return 0;
}

I64 Q_strncasecmp(U8 *a, U8 *b, I64 n) {
  I64 i;
  I64 ca;
  I64 cb;
  for (i = 0; i < n; i++) {
    ca = a[i];
    cb = b[i];
    if (ca >= 'A' && ca <= 'Z') {
      ca = ca + ('a' - 'A');
    }
    if (cb >= 'A' && cb <= 'Z') {
      cb = cb + ('a' - 'A');
    }
    if (ca != cb) {
      return ca - cb;
    }
    if (!ca) {
      return 0;
    }
  }
  return 0;
}

I64 Q_atoi(U8 *s) {
  // Decimal integer parser with leading sign. Hex/char-const corner
  // cases from Quake's Q_atoi are out of scope for now.
  I64 sign = 1;
  I64 value = 0;
  I64 i = 0;
  if (s[0] == '-') {
    sign = -1;
    i = 1;
  } else if (s[0] == '+') {
    i = 1;
  }
  while (s[i] >= '0' && s[i] <= '9') {
    value = value * 10 + (s[i] - '0');
    i++;
  }
  return sign * value;
}

// Mem helpers — thin wrappers over TempleOS's MemSet/MemCpy/MemCmp,
// kept under the Q_ namespace so call sites read the same as
// upstream Quake.
U0 Q_memset(U8 *dst, I64 fill, I64 count) {
  MemSet(dst, fill, count);
}

U0 Q_memcpy(U8 *dst, U8 *src, I64 count) {
  MemCpy(dst, src, count);
}

I64 Q_memcmp(U8 *a, U8 *b, I64 count) {
  return MemCmp(a, b, count);
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
// Command system: ported in Cmd.HC.
// ----------------------------------------------------------------
//
// Cmd_Argc / Cmd_Argv / Cmd_Exists used to be stubbed here; the
// real implementations now live in Cmd.HC, which sorts after
// Bootstrap.HC and before Cvar.HC, so Cvar.HC sees the real
// command-system entry points when it pushes.

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
