// Zone.HC — port of WinQuake/zone.c (delegating shim).
//
// The faithful Quake allocator was a hand-rolled three-tier system
// over a fixed contiguous block of memory:
//   - Hunk_ : low/high stack-style allocations from each end
//   - Z_    : small dynamic allocations within the low end of the hunk
//   - Cache_: LRU-managed allocations between the hunk marks
//
// The whole design exists because DOS-era Quake had to manage its
// own pool. TempleOS's kernel allocator (`MAlloc`/`Free`) does what's
// needed at zero loss to gameplay — porting the Hunk/Cache machinery
// faithfully is roughly 700 LOC of pointer arithmetic that buys us
// nothing on this platform.
//
// So this file is a shim. Every public API delegates to MAlloc/Free,
// honoring the Quake CONTRACT (zero-fill, name parameter ignored,
// etc.) but not the IMPLEMENTATION.
//
// What's deliberately NOT implemented (caller-visible behavior gaps):
//
//   - **Hunk mark/restore**: `Hunk_LowMark` returns 0; `Hunk_FreeToLowMark`
//     is a no-op. Callers using mark/restore for transient allocations
//     LEAK. Real Quake uses this in host_cmd.c and a few other places;
//     we'll either revisit if memory pressure becomes an issue, or
//     port a small mark-list bookkeeping layer when needed.
//
//   - **Cache LRU eviction**: Cache_Alloc never evicts. The cache is
//     unbounded. On long sessions this could OOM; on test runs it's
//     fine.
//
//   - **Diagnostics**: Z_DumpHeap / Z_CheckHeap / Hunk_Check /
//     Cache_Report are no-ops. The kernel allocator has its own
//     debugging via `MemRep` / `Lsb` etc.
//
// Z_Malloc / Z_Free live in Bootstrap.HC (every other module needs
// them and they're trivial). The rest is here.

// ----------------------------------------------------------------
// Memory_Init — Quake passes a pre-allocated buffer; we ignore.
// ----------------------------------------------------------------

U0 Memory_Init(U8 *buf, I64 size) {
  // No-op on TempleOS — kernel allocator manages memory globally.
  // Callers who pre-allocated a buffer themselves should free it.
  // We accept the parameters to keep the signature; the cast on the
  // pointer ensures the compiler doesn't warn about an unused arg.
  if (size < 0) {
    Print("Memory_Init: negative size?\n");
  }
  if (buf == NULL && size > 0) {
    Print("Memory_Init: null buf with size > 0\n");
  }
}

// ----------------------------------------------------------------
// Z_TagMalloc / Z_FreeMemory — extras beyond what Bootstrap.HC has.
// ----------------------------------------------------------------

U8 *Z_TagMalloc(I64 size, I64 tag) {
  // Tag is ignored — original Quake used it to free groups via
  // Z_FreeTags. Not currently exercised in our porting effort; can
  // be added if needed.
  if (tag < 0) {
    return NULL;
  }
  return Z_Malloc(size);
}

I64 Z_FreeMemory() {
  // Real Quake walked the zone free list and summed it. We delegate
  // to the kernel; "infinity" is the honest answer (memory is bounded
  // only by the system).
  return 0x7FFFFFFFFFFFFFFF;
}

U0 Z_DumpHeap() {
  // No-op — the kernel allocator tracks its own heap, and our shim
  // doesn't have a "zone" to dump.
}

U0 Z_CheckHeap() {
  // No-op — invariants tracked by the kernel.
}

// ----------------------------------------------------------------
// Hunk allocator — three forms that Quake distinguishes (low, high,
// temp). All map to MAlloc + zero-fill here. The `name` parameter is
// preserved for API parity but only used for an optional diagnostic.
// ----------------------------------------------------------------

U8 *Hunk_AllocName(I64 size, U8 *name) {
  U8 *p = MAlloc(size);
  if (p) {
    MemSet(p, 0, size);
  }
  // `name` reserved for Hunk_Print. Suppress unused-warning by
  // touching the pointer.
  if (name == NULL) {
    return p;
  }
  return p;
}

U8 *Hunk_Alloc(I64 size) {
  return Hunk_AllocName(size, "unknown");
}

U8 *Hunk_HighAllocName(I64 size, U8 *name) {
  // Same shim — there's no "high" / "low" distinction without a
  // contiguous pool. Callers that depended on the high/low ordering
  // (e.g. video buffers vs server allocations) get equivalent
  // behavior because each MAlloc returns its own region.
  return Hunk_AllocName(size, name);
}

I64 Hunk_LowMark() {
  // No real "low mark" without a stack pool. Callers that mark/free
  // are leaking — see file header.
  return 0;
}

U0 Hunk_FreeToLowMark(I64 mark) {
  // No-op (see file header). Suppress unused-warning.
  if (mark < 0) {
    return;
  }
}

I64 Hunk_HighMark() {
  return 0;
}

U0 Hunk_FreeToHighMark(I64 mark) {
  if (mark < 0) {
    return;
  }
}

U8 *Hunk_TempAlloc(I64 size) {
  // Real Hunk_TempAlloc returned the same buffer until next call,
  // freeing the previous. We always return fresh memory; callers
  // that depended on temp lifetime get fresh allocations instead.
  return Hunk_AllocName(size, "temp");
}

U0 Hunk_Check() {
  // No-op — kernel tracks invariants.
}

// ----------------------------------------------------------------
// Cache — Quake's LRU-evictable resource cache. Without eviction,
// this is just MAlloc + a slot to remember the pointer.
// ----------------------------------------------------------------

class cache_user_t {
  U8 *data;
};

U0 Cache_Flush() {
  // No-op (we don't track allocations). Real Quake would walk every
  // cache_user_t and free its data. We can add a registration list
  // if a level-load path actually needs cache invalidation.
}

U8 *Cache_Check(cache_user_t *c) {
  if (c == NULL) {
    return NULL;
  }
  return c->data;
}

U0 Cache_Free(cache_user_t *c) {
  if (c == NULL) {
    return;
  }
  if (c->data) {
    Free(c->data);
    c->data = NULL;
  }
}

U8 *Cache_Alloc(cache_user_t *c, I64 size, U8 *name) {
  if (c == NULL) {
    return NULL;
  }
  // Per Quake's contract: if data is already live, return it; the
  // caller is expected to call Cache_Free first if they want fresh.
  if (c->data) {
    return c->data;
  }
  c->data = MAlloc(size);
  if (c->data) {
    MemSet(c->data, 0, size);
  }
  // `name` reserved for Cache_Report.
  if (name == NULL) {
    return c->data;
  }
  return c->data;
}

U0 Cache_Report() {
  // No-op.
}
