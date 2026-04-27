// T_Common.HC — battery for src/Common.HC + the Q_* extensions in
// Bootstrap.HC.

// ---- Q_* extensions (Bootstrap.HC) ----

ASSERT_EQ(Q_atoi("0"),       0,    "Qatoi_zero");
ASSERT_EQ(Q_atoi("42"),     42,    "Qatoi_int");
ASSERT_EQ(Q_atoi("-7"),     -7,    "Qatoi_neg");
ASSERT_EQ(Q_atoi("+13"),    13,    "Qatoi_plus_sign");
ASSERT_EQ(Q_atoi(""),        0,    "Qatoi_empty");
ASSERT_EQ(Q_atoi("12abc"),  12,    "Qatoi_stops_at_nondigit");

ASSERT_EQ(Q_strcasecmp("foo", "FOO"), 0, "Qstrcasecmp_eq");
ASSERT_EQ(Q_strcasecmp("ABC", "abc"), 0, "Qstrcasecmp_eq_rev");
ASSERT_EQ(Q_strcasecmp("a",   "b") != 0, 1, "Qstrcasecmp_diff");

ASSERT_EQ(Q_strncasecmp("aBcXX", "AbCYY", 3), 0, "Qstrncasecmp_prefix_eq");
ASSERT_EQ(Q_strncasecmp("a", "b", 1) != 0, 1, "Qstrncasecmp_diff");

U8 _t_cat[32];
StrCpy(_t_cat, "foo");
Q_strcat(_t_cat, "bar");
ASSERT_EQ(Q_strcmp(_t_cat, "foobar"), 0, "Qstrcat_basic");

U8 _t_ncpy[8];
Q_memset(_t_ncpy, 'X', 8);
Q_strncpy(_t_ncpy, "ab", 8);
ASSERT_EQ(_t_ncpy[0], 'a', "Qstrncpy_byte0");
ASSERT_EQ(_t_ncpy[1], 'b', "Qstrncpy_byte1");
ASSERT_EQ(_t_ncpy[2], 0,   "Qstrncpy_pad_zero");
ASSERT_EQ(_t_ncpy[7], 0,   "Qstrncpy_pads_to_n");

U8 *_t_rchr = Q_strrchr("foo/bar/baz.txt", '/');
ASSERT_EQ(*_t_rchr, '/', "Qstrrchr_finds_last_slash");
ASSERT_EQ(Q_strcmp(_t_rchr + 1, "baz.txt"), 0, "Qstrrchr_returns_after_match");
ASSERT_EQ(Q_strrchr("nope", 'z') == NULL, 1, "Qstrrchr_no_match_null");

// ---- Endian helpers ----
ASSERT_EQ(LittleLong(0x12345678), 0x12345678, "LittleLong_identity");
ASSERT_EQ(LittleShort(0x1234),   0x1234,     "LittleShort_identity");
ASSERT_EQ(BigLong(0x12345678),   0x78563412, "BigLong_swap");
// I16 sign-extension: BigShort(0x1234) → 0x3412.
ASSERT_EQ(BigShort(0x1234) & 0xFFFF, 0x3412, "BigShort_swap");

// ---- link_t doubly-linked list ----
link_t _t_head;
link_t _t_a;
link_t _t_b;
link_t _t_c;
ClearLink(&_t_head);
ASSERT_EQ(_t_head.next == &_t_head, 1, "ClearLink_self_ref_next");
ASSERT_EQ(_t_head.prev == &_t_head, 1, "ClearLink_self_ref_prev");

InsertLinkAfter(&_t_a, &_t_head);   // head ↔ a
InsertLinkAfter(&_t_b, &_t_a);      // head ↔ a ↔ b
InsertLinkBefore(&_t_c, &_t_a);     // head ↔ c ↔ a ↔ b
ASSERT_EQ(_t_head.next == &_t_c, 1, "Insert_chain_head_to_c");
ASSERT_EQ(_t_c.next == &_t_a,    1, "Insert_chain_c_to_a");
ASSERT_EQ(_t_a.next == &_t_b,    1, "Insert_chain_a_to_b");
ASSERT_EQ(_t_b.next == &_t_head, 1, "Insert_chain_b_to_head");

RemoveLink(&_t_a);
ASSERT_EQ(_t_c.next == &_t_b,    1, "RemoveLink_skips");
ASSERT_EQ(_t_b.prev == &_t_c,    1, "RemoveLink_back_skips");

// ---- sizebuf_t ----
sizebuf_t _t_sb;
SZ_Alloc(&_t_sb, 64);
ASSERT_EQ(_t_sb.maxsize >= 256, 1, "SZ_Alloc_min_size");
ASSERT_EQ(_t_sb.cursize, 0,        "SZ_Alloc_cursize_zero");
ASSERT_EQ(_t_sb.data != NULL, 1,   "SZ_Alloc_data_set");

U8 *_t_sp = SZ_GetSpace(&_t_sb, 4);
_t_sp[0] = 1; _t_sp[1] = 2; _t_sp[2] = 3; _t_sp[3] = 4;
ASSERT_EQ(_t_sb.cursize, 4, "SZ_GetSpace_advances_cursize");
ASSERT_EQ(_t_sb.data[0], 1, "SZ_GetSpace_writes_byte0");

SZ_Clear(&_t_sb);
ASSERT_EQ(_t_sb.cursize, 0,           "SZ_Clear_resets");
ASSERT_EQ(_t_sb.overflowed == FALSE, 1, "SZ_Clear_clears_overflowed");

// ---- MSG_Write* + MSG_Read* roundtrip ----
SZ_Clear(&_t_sb);
MSG_WriteByte(&_t_sb, 0x42);
MSG_WriteShort(&_t_sb, 0x1234);
MSG_WriteLong(&_t_sb, 0x12345678);
MSG_WriteString(&_t_sb, "hello");
MSG_WriteChar(&_t_sb, -5);

MSG_BeginReading(&_t_sb);
ASSERT_EQ(MSG_ReadByte(),  0x42,       "MSG_byte_roundtrip");
ASSERT_EQ(MSG_ReadShort(), 0x1234,     "MSG_short_roundtrip");
ASSERT_EQ(MSG_ReadLong(),  0x12345678, "MSG_long_roundtrip");
ASSERT_EQ(Q_strcmp(MSG_ReadString(), "hello"), 0, "MSG_string_roundtrip");
ASSERT_EQ(MSG_ReadChar(), -5,          "MSG_signed_char_roundtrip");

// Read past end → msg_badread
MSG_ReadByte();   // overshoot
ASSERT_EQ(msg_badread == TRUE, 1, "MSG_badread_set_on_overshoot");

// Float roundtrip — small loss expected via F32 narrowing in the
// wire format; tolerance ~1e-6.
SZ_Clear(&_t_sb);
MSG_WriteFloat(&_t_sb, 3.14);
MSG_BeginReading(&_t_sb);
F64 _t_f = MSG_ReadFloat();
ASSERT_NEAR(_t_f, 3.14, 0.00001, "MSG_float_roundtrip");

// Coord (1/8 unit, I16): roundtrip ±value with quantization tolerance
SZ_Clear(&_t_sb);
MSG_WriteCoord(&_t_sb, 12.5);
MSG_BeginReading(&_t_sb);
ASSERT_NEAR(MSG_ReadCoord(), 12.5, 0.001, "MSG_coord_roundtrip");

// Angle (byte = 1/256 of a rotation): tolerance ~360/256
SZ_Clear(&_t_sb);
MSG_WriteAngle(&_t_sb, 90.0);
MSG_BeginReading(&_t_sb);
ASSERT_NEAR(MSG_ReadAngle(), 90.0, 1.5, "MSG_angle_roundtrip");

SZ_Free(&_t_sb);

// ---- COM_Parse + com_token ----
U8 *_t_rest = COM_Parse("  hello   world  ");
ASSERT_EQ(Q_strcmp(com_token, "hello"), 0, "COM_Parse_first_token");
_t_rest = COM_Parse(_t_rest);
ASSERT_EQ(Q_strcmp(com_token, "world"), 0, "COM_Parse_second_token");

_t_rest = COM_Parse("\"quoted thing\"");
ASSERT_EQ(Q_strcmp(com_token, "quoted thing"), 0, "COM_Parse_quoted");

_t_rest = COM_Parse(NULL);
ASSERT_EQ(_t_rest == NULL, 1, "COM_Parse_null_returns_null");

// ---- va() ----
U8 *_t_va1 = va("hello %d", 42, NULL, NULL, NULL);
ASSERT_EQ(Q_strcmp(_t_va1, "hello 42"), 0, "va_basic");
// Second call to va doesn't clobber the first (rotating slots).
U8 *_t_va2 = va("other %d", 7, NULL, NULL, NULL);
ASSERT_EQ(Q_strcmp(_t_va1, "hello 42"), 0, "va_rotating_slots_first_intact");
ASSERT_EQ(Q_strcmp(_t_va2, "other 7"), 0, "va_rotating_slots_second_correct");

// ---- Path helpers ----
U8 _t_pbuf[64];

ASSERT_EQ(Q_strcmp(COM_SkipPath("foo/bar/baz.txt"), "baz.txt"), 0, "SkipPath_basic");
ASSERT_EQ(Q_strcmp(COM_SkipPath("nopath.txt"),     "nopath.txt"), 0, "SkipPath_no_dirs");

COM_StripExtension("maps/start.bsp", _t_pbuf);
ASSERT_EQ(Q_strcmp(_t_pbuf, "maps/start"), 0, "StripExtension_basic");
COM_StripExtension("noext", _t_pbuf);
ASSERT_EQ(Q_strcmp(_t_pbuf, "noext"), 0, "StripExtension_noop");

COM_FileBase("maps/start.bsp", _t_pbuf);
ASSERT_EQ(Q_strcmp(_t_pbuf, "start"), 0, "FileBase_strips_dir_and_ext");
COM_FileBase("simple", _t_pbuf);
ASSERT_EQ(Q_strcmp(_t_pbuf, "simple"), 0, "FileBase_no_ext_no_dir");

U8 _t_pbuf2[64];
StrCpy(_t_pbuf2, "world");
COM_DefaultExtension(_t_pbuf2, ".bsp");
ASSERT_EQ(Q_strcmp(_t_pbuf2, "world.bsp"), 0, "DefaultExtension_appends");
StrCpy(_t_pbuf2, "world.dat");
COM_DefaultExtension(_t_pbuf2, ".bsp");
ASSERT_EQ(Q_strcmp(_t_pbuf2, "world.dat"), 0, "DefaultExtension_keeps_existing");

TEST_SUMMARY;
