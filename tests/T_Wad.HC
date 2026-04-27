// T_Wad.HC — battery for src/Wad.HC.
//
// We don't have file IO yet, so the test builds a synthetic WAD2
// blob in memory and drives W_LoadWadFromBuffer directly.
//
// Layout we synthesize (offsets in bytes, all little-endian):
//
//   0x00  "WAD2"          (4 bytes — header.identification)
//   0x04  numlumps = 2    (4 bytes I32)
//   0x08  infotableofs = 0x40   (4 bytes I32)
//   0x0C  pad to 0x40
//   0x40  lumpinfo[0]:
//           filepos  = 0xA0
//           disksize = 4
//           size     = 4
//           type     = TYP_LABEL
//           compression = 0
//           pad1, pad2 = 0
//           name = "ALPHA\0..." (16 bytes, will be lowercased on load)
//   0x60  lumpinfo[1]:
//           filepos = 0xA4
//           disksize = 8
//           size = 8
//           type = TYP_QPIC
//           name = "pic\0..."
//   0xA0  lump[0] data: 4 bytes "abcd"
//   0xA4  lump[1] data: qpic_t (width=2, height=2, then 4 bytes pixels)

U8 _t_wad[256];
I64 _t_wi;

// ---- W_CleanupName: lowercase + NUL-pad ----
U8 _t_clean_in[20];
U8 _t_clean_out[20];
StrCpy(_t_clean_in, "Hello!");
W_CleanupName(_t_clean_in, _t_clean_out);
ASSERT_EQ(_t_clean_out[0], 'h', "cleanup_lowercase_first");
ASSERT_EQ(_t_clean_out[5], '!', "cleanup_keeps_punct");
ASSERT_EQ(_t_clean_out[6], 0,   "cleanup_pads_zero");
ASSERT_EQ(_t_clean_out[15], 0,  "cleanup_pads_to_16");

// ---- LittleLong / LittleShort identity (x86_64) ----
ASSERT_EQ(LittleLong(0x12345678), 0x12345678, "LittleLong_identity");
ASSERT_EQ(LittleShort(0x1234), 0x1234, "LittleShort_identity");

// ---- Build the synthetic WAD blob ----

// Zero the buffer first.
for (_t_wi = 0; _t_wi < 256; _t_wi++) {
  _t_wad[_t_wi] = 0;
}

// Header at 0x00
_t_wad[0] = 'W';
_t_wad[1] = 'A';
_t_wad[2] = 'D';
_t_wad[3] = '2';
// numlumps = 2 at 0x04 (I32 little-endian)
_t_wad[4] = 2; _t_wad[5] = 0; _t_wad[6] = 0; _t_wad[7] = 0;
// infotableofs = 0x40 at 0x08
_t_wad[8]  = 0x40; _t_wad[9]  = 0; _t_wad[10] = 0; _t_wad[11] = 0;

// lumpinfo[0] at 0x40
_t_wad[0x40] = 0xA0; _t_wad[0x41] = 0; _t_wad[0x42] = 0; _t_wad[0x43] = 0;  // filepos
_t_wad[0x44] = 0x04; _t_wad[0x45] = 0; _t_wad[0x46] = 0; _t_wad[0x47] = 0;  // disksize
_t_wad[0x48] = 0x04; _t_wad[0x49] = 0; _t_wad[0x4A] = 0; _t_wad[0x4B] = 0;  // size
_t_wad[0x4C] = TYP_LABEL;       // type
_t_wad[0x4D] = CMP_NONE;        // compression
// pad1, pad2 (0x4E, 0x4F) already 0
// name "ALPHA" at 0x50 (will be lowercased on load to "alpha")
_t_wad[0x50] = 'A'; _t_wad[0x51] = 'L'; _t_wad[0x52] = 'P';
_t_wad[0x53] = 'H'; _t_wad[0x54] = 'A';

// lumpinfo[1] at 0x60 (sizeof(lumpinfo_t) = 32)
_t_wad[0x60] = 0xA4; _t_wad[0x61] = 0; _t_wad[0x62] = 0; _t_wad[0x63] = 0;  // filepos
_t_wad[0x64] = 0x08; _t_wad[0x65] = 0; _t_wad[0x66] = 0; _t_wad[0x67] = 0;  // disksize
_t_wad[0x68] = 0x08; _t_wad[0x69] = 0; _t_wad[0x6A] = 0; _t_wad[0x6B] = 0;  // size
_t_wad[0x6C] = TYP_QPIC;
_t_wad[0x6D] = CMP_NONE;
// name "pic" at 0x70
_t_wad[0x70] = 'p'; _t_wad[0x71] = 'i'; _t_wad[0x72] = 'c';

// lump[0] body at 0xA0: "abcd"
_t_wad[0xA0] = 'a'; _t_wad[0xA1] = 'b'; _t_wad[0xA2] = 'c'; _t_wad[0xA3] = 'd';

// lump[1] body at 0xA4: qpic_t { width=2, height=2 }, then 4 pixel bytes
_t_wad[0xA4] = 2; _t_wad[0xA5] = 0; _t_wad[0xA6] = 0; _t_wad[0xA7] = 0;  // width
_t_wad[0xA8] = 2; _t_wad[0xA9] = 0; _t_wad[0xAA] = 0; _t_wad[0xAB] = 0;  // height
_t_wad[0xAC] = 0x10; _t_wad[0xAD] = 0x20; _t_wad[0xAE] = 0x30; _t_wad[0xAF] = 0x40;

// ---- Load + structural checks ----
ASSERT_EQ(W_LoadWadFromBuffer(_t_wad, 256) == TRUE, 1, "load_returns_true");
ASSERT_EQ(wad_numlumps, 2, "load_sets_numlumps");
ASSERT_EQ(wad_base == _t_wad, 1, "load_sets_base");
ASSERT_EQ(wad_lumps != NULL, 1, "load_sets_lumps");

// ---- Lookup by name (case-insensitive — "ALPHA" was lowercased) ----
lumpinfo_t *_t_lump = W_GetLumpinfo("alpha");
ASSERT_EQ(_t_lump != NULL, 1, "lookup_by_name_alpha");
ASSERT_EQ(_t_lump->type, TYP_LABEL, "lookup_alpha_type");
ASSERT_EQ(_t_lump->size, 4, "lookup_alpha_size");

// Lookup with an UPPERCASE query — should still hit because the
// query is also W_CleanupName'd before compare.
ASSERT_EQ(W_GetLumpinfo("ALPHA") != NULL, 1, "lookup_by_uppercase");

// Lookup miss returns NULL (and prints a not-found message).
ASSERT_EQ(W_GetLumpinfo("missing") == NULL, 1, "lookup_miss_returns_null");

// ---- W_GetLumpName returns pointer to the data block ----
U8 *_t_data0 = W_GetLumpName("alpha");
ASSERT_EQ(_t_data0 != NULL, 1, "GetLumpName_returns_pointer");
ASSERT_EQ(_t_data0[0], 'a', "GetLumpName_data_byte0");
ASSERT_EQ(_t_data0[3], 'd', "GetLumpName_data_byte3");

// ---- W_GetLumpNum bounds-checks ----
ASSERT_EQ(W_GetLumpNum(0) != NULL, 1, "GetLumpNum_zero_ok");
ASSERT_EQ(W_GetLumpNum(1) != NULL, 1, "GetLumpNum_one_ok");
ASSERT_EQ(W_GetLumpNum(99) == NULL, 1, "GetLumpNum_oob_returns_null");
ASSERT_EQ(W_GetLumpNum(-1) == NULL, 1, "GetLumpNum_negative_returns_null");

// ---- QPIC: SwapPic ran during load; width/height read from the lump ----
qpic_t *_t_pic = W_GetLumpName("pic");
ASSERT_EQ(_t_pic != NULL, 1, "GetLumpName_pic");
ASSERT_EQ(_t_pic->width, 2,  "pic_width_after_swap");
ASSERT_EQ(_t_pic->height, 2, "pic_height_after_swap");

// ---- Bad header rejected ----
_t_wad[0] = 'X';  // corrupt the magic
ASSERT_EQ(W_LoadWadFromBuffer(_t_wad, 256) == FALSE, 1, "bad_magic_rejected");
// Restore so subsequent tests in the same battery still see clean state.
_t_wad[0] = 'W';
ASSERT_EQ(W_LoadWadFromBuffer(_t_wad, 256) == TRUE, 1, "reload_after_fix");

TEST_SUMMARY;
