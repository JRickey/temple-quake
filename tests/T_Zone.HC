// T_Zone.HC — battery for src/Zone.HC.
//
// Tests the API contracts of the shim. We're not verifying the
// allocator's internals (MAlloc/Free are TempleOS's), only that the
// Quake-side behaviors callers depend on hold:
//   - Z_Malloc returns zero-filled memory
//   - Hunk_AllocName returns zero-filled memory
//   - Cache_* roundtrips pointer state via cache_user_t.data
//   - Hunk_LowMark / FreeToLowMark don't crash (the deferred path)

U8 *_t_zone_buf;
cache_user_t _t_cache_slot;
I64 _t_zone_mark;

// ---- Z_Malloc returns zero-filled memory ----
_t_zone_buf = Z_Malloc(64);
ASSERT_EQ(_t_zone_buf != NULL, 1, "Z_Malloc_returns_pointer");
I64 _t_zone_sum = 0;
I64 _t_i;
for (_t_i = 0; _t_i < 64; _t_i++) {
  _t_zone_sum = _t_zone_sum + _t_zone_buf[_t_i];
}
ASSERT_EQ(_t_zone_sum, 0, "Z_Malloc_zero_filled");
Z_Free(_t_zone_buf);

// ---- Z_TagMalloc behaves like Z_Malloc (tag ignored) ----
_t_zone_buf = Z_TagMalloc(32, 1);
ASSERT_EQ(_t_zone_buf != NULL, 1, "Z_TagMalloc_returns_pointer");
Z_Free(_t_zone_buf);

// ---- Z_FreeMemory returns "lots" (no real bound) ----
ASSERT_EQ(Z_FreeMemory() > 1000000, 1, "Z_FreeMemory_unbounded");

// ---- Hunk_AllocName returns zero-filled ----
_t_zone_buf = Hunk_AllocName(128, "test_hunk");
ASSERT_EQ(_t_zone_buf != NULL, 1, "Hunk_AllocName_returns_pointer");
_t_zone_sum = 0;
for (_t_i = 0; _t_i < 128; _t_i++) {
  _t_zone_sum = _t_zone_sum + _t_zone_buf[_t_i];
}
ASSERT_EQ(_t_zone_sum, 0, "Hunk_AllocName_zero_filled");
Free(_t_zone_buf);  // direct free OK since we delegate

// ---- Hunk_Alloc / Hunk_HighAllocName / Hunk_TempAlloc all work ----
ASSERT_EQ(Hunk_Alloc(16) != NULL, 1, "Hunk_Alloc_returns_pointer");
ASSERT_EQ(Hunk_HighAllocName(16, "high") != NULL, 1, "Hunk_HighAllocName_returns_pointer");
ASSERT_EQ(Hunk_TempAlloc(16) != NULL, 1, "Hunk_TempAlloc_returns_pointer");

// ---- Hunk_LowMark / FreeToLowMark don't crash (deferred behavior) ----
_t_zone_mark = Hunk_LowMark();
ASSERT_EQ(_t_zone_mark, 0, "Hunk_LowMark_returns_zero");
Hunk_FreeToLowMark(_t_zone_mark);  // must not crash
ASSERT_EQ(1, 1, "Hunk_FreeToLowMark_no_crash");
Hunk_FreeToHighMark(Hunk_HighMark());
ASSERT_EQ(1, 1, "Hunk_FreeToHighMark_no_crash");

// ---- Cache_*: data slot roundtrips ----
_t_cache_slot.data = NULL;
ASSERT_EQ(Cache_Check(&_t_cache_slot) == NULL, 1, "Cache_Check_empty_returns_null");
U8 *_t_cache_p = Cache_Alloc(&_t_cache_slot, 256, "test_cache");
ASSERT_EQ(_t_cache_p != NULL, 1, "Cache_Alloc_returns_pointer");
ASSERT_EQ(Cache_Check(&_t_cache_slot) == _t_cache_p, 1, "Cache_Check_returns_alloc");
// Re-Alloc on a populated slot returns the existing buffer (Quake contract).
ASSERT_EQ(Cache_Alloc(&_t_cache_slot, 256, "again") == _t_cache_p,
          1, "Cache_Alloc_idempotent_when_live");
Cache_Free(&_t_cache_slot);
ASSERT_EQ(Cache_Check(&_t_cache_slot) == NULL, 1, "Cache_Check_after_free_null");

// ---- Cache_Free is safe on already-empty slot ----
Cache_Free(&_t_cache_slot);
ASSERT_EQ(1, 1, "Cache_Free_double_safe");

// ---- Memory_Init no-op ----
Memory_Init(NULL, 0);
ASSERT_EQ(1, 1, "Memory_Init_no_crash");

TEST_SUMMARY;
