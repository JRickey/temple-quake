// T_CRC.HC — battery for src/CRC.HC.
//
// Test vectors come from the CRC-CCITT / XMODEM standard:
//   - empty buffer → 0xFFFF (init value, final xor is 0)
//   - "123456789" → 0x29B1 (the canonical CRC-CCITT-FALSE check value)

U16 _crc_v;
U8  _crc_check[9];
U8  _crc_one[1];

// Empty input: CRC value is just the post-XOR of init.
CRC_Init(&_crc_v);
ASSERT_EQ(CRC_Value(_crc_v), 0xFFFF, "CRC_empty_init");

// Standard "123456789" test vector — the universally-cited CRC-CCITT
// check value. If this matches, the table and accumulator agree
// with the rest of the world.
_crc_check[0] = '1';
_crc_check[1] = '2';
_crc_check[2] = '3';
_crc_check[3] = '4';
_crc_check[4] = '5';
_crc_check[5] = '6';
_crc_check[6] = '7';
_crc_check[7] = '8';
_crc_check[8] = '9';
ASSERT_EQ(CRC_Block(_crc_check, 9), 0x29B1, "CRC_check_123456789");

// Single-byte sanity: shifting state by exactly one byte must match
// the same byte run via Block().
_crc_one[0] = 'A';
CRC_Init(&_crc_v);
CRC_ProcessByte(&_crc_v, 'A');
ASSERT_EQ(CRC_Value(_crc_v), CRC_Block(_crc_one, 1), "CRC_block_eq_step_one");

// Determinism: running the same input twice produces the same CRC.
ASSERT_EQ(CRC_Block(_crc_check, 9), CRC_Block(_crc_check, 9), "CRC_block_deterministic");

// Distinct inputs should produce distinct CRCs (avalanche sanity —
// not strict guarantee, but "1" vs "2" definitely differ).
_crc_one[0] = '1';
U16 _crc_a = CRC_Block(_crc_one, 1);
_crc_one[0] = '2';
U16 _crc_b = CRC_Block(_crc_one, 1);
ASSERT_EQ(_crc_a == _crc_b, 0, "CRC_block_distinguishes_inputs");

TEST_SUMMARY;
