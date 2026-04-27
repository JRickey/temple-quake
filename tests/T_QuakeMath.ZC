// T_QuakeMath.ZC — battery for src/QuakeMath.ZC.
//
// Why no #define macros / no `1e-9`: HolyC's parametrized #define is
// unreliable across ExePutS chunks (parser errors caught on first run),
// and exponent-form float literals trip "Missing )". So tests call the
// underscored function forms (_DotProduct, _VectorAdd, ...) directly
// and use plain decimal eps values.

F64 _v_a[3];
F64 _v_b[3];
F64 _v_c[3];
F64 _ang[3];
F64 _fwd[3];
F64 _rgt[3];
F64 _up[3];
I64 _q;
I64 _r;
F64 _eps = 0.000000001;

// DotProduct: (1,2,3) . (4,5,6) = 32
_v_a[0] = 1.0; _v_a[1] = 2.0; _v_a[2] = 3.0;
_v_b[0] = 4.0; _v_b[1] = 5.0; _v_b[2] = 6.0;
ASSERT_NEAR(_DotProduct(_v_a, _v_b), 32.0, _eps, "DotProduct");

// CrossProduct: (1,0,0) x (0,1,0) = (0,0,1)
_v_a[0] = 1.0; _v_a[1] = 0.0; _v_a[2] = 0.0;
_v_b[0] = 0.0; _v_b[1] = 1.0; _v_b[2] = 0.0;
CrossProduct(_v_a, _v_b, _v_c);
ASSERT_VEC3(_v_c, 0.0, 0.0, 1.0, _eps, "CrossProduct_xy");

// _VectorAdd / _VectorSubtract
_v_a[0] = 1.0; _v_a[1] = 2.0; _v_a[2] = 3.0;
_v_b[0] = 10.0; _v_b[1] = 20.0; _v_b[2] = 30.0;
_VectorAdd(_v_a, _v_b, _v_c);
ASSERT_VEC3(_v_c, 11.0, 22.0, 33.0, _eps, "VectorAdd");
_VectorSubtract(_v_b, _v_a, _v_c);
ASSERT_VEC3(_v_c, 9.0, 18.0, 27.0, _eps, "VectorSubtract");

// VectorMA: (1,2,3) + 2*(10,20,30) = (21, 42, 63)
_v_a[0] = 1.0; _v_a[1] = 2.0; _v_a[2] = 3.0;
_v_b[0] = 10.0; _v_b[1] = 20.0; _v_b[2] = 30.0;
VectorMA(_v_a, 2.0, _v_b, _v_c);
ASSERT_VEC3(_v_c, 21.0, 42.0, 63.0, _eps, "VectorMA");

// Length: |(3, 4, 0)| = 5
_v_a[0] = 3.0; _v_a[1] = 4.0; _v_a[2] = 0.0;
ASSERT_NEAR(Length(_v_a), 5.0, _eps, "Length");

// VectorNormalize: returns original length, leaves unit vector.
_v_a[0] = 3.0; _v_a[1] = 4.0; _v_a[2] = 0.0;
ASSERT_NEAR(VectorNormalize(_v_a), 5.0, _eps, "VectorNormalize_returns_len");
ASSERT_VEC3(_v_a, 0.6, 0.8, 0.0, _eps, "VectorNormalize_unit");
ASSERT_NEAR(Length(_v_a), 1.0, _eps, "VectorNormalize_unit_len");

// VectorInverse / VectorScale
_v_a[0] = 1.0; _v_a[1] = -2.0; _v_a[2] = 3.0;
VectorInverse(_v_a);
ASSERT_VEC3(_v_a, -1.0, 2.0, -3.0, _eps, "VectorInverse");
VectorScale(_v_a, 0.5, _v_b);
ASSERT_VEC3(_v_b, -0.5, 1.0, -1.5, _eps, "VectorScale");

// VectorCompare
_v_a[0] = 1.0; _v_a[1] = 2.0; _v_a[2] = 3.0;
_v_b[0] = 1.0; _v_b[1] = 2.0; _v_b[2] = 3.0;
ASSERT_EQ(VectorCompare(_v_a, _v_b), 1, "VectorCompare_eq");
_v_b[2] = 3.5;
ASSERT_EQ(VectorCompare(_v_a, _v_b), 0, "VectorCompare_neq");

// AngleVectors at zero -> standard basis (forward=+x, right=-y, up=+z)
_ang[0] = 0.0; _ang[1] = 0.0; _ang[2] = 0.0;
AngleVectors(_ang, _fwd, _rgt, _up);
ASSERT_VEC3(_fwd, 1.0, 0.0, 0.0, _eps, "AngleVectors_zero_fwd");
ASSERT_VEC3(_rgt, 0.0, -1.0, 0.0, _eps, "AngleVectors_zero_right");
ASSERT_VEC3(_up,  0.0, 0.0, 1.0, _eps, "AngleVectors_zero_up");

// AngleVectors yaw=90 -> forward=+y, right=+x
_ang[0] = 0.0; _ang[1] = 90.0; _ang[2] = 0.0;
AngleVectors(_ang, _fwd, _rgt, _up);
ASSERT_VEC3(_fwd, 0.0, 1.0, 0.0, _eps, "AngleVectors_yaw90_fwd");
ASSERT_VEC3(_rgt, 1.0, 0.0, 0.0, _eps, "AngleVectors_yaw90_right");

// anglemod folds into [0, 360)
ASSERT_NEAR(anglemod(0.0),    0.0,   0.001, "anglemod_0");
ASSERT_NEAR(anglemod(370.0), 10.0,   0.01,  "anglemod_370");
ASSERT_NEAR(anglemod(720.0),  0.0,   0.001, "anglemod_720");

// FloorDivMod: 7 / 3 = (2, 1); -7 / 3 = (-3, 2)  (floor-based)
FloorDivMod(7.0, 3.0, &_q, &_r);
ASSERT_EQ(_q, 2, "FloorDivMod_pos_q");
ASSERT_EQ(_r, 1, "FloorDivMod_pos_r");
FloorDivMod(-7.0, 3.0, &_q, &_r);
ASSERT_EQ(_q, -3, "FloorDivMod_neg_q");
ASSERT_EQ(_r, 2,  "FloorDivMod_neg_r");

// GreatestCommonDivisor
ASSERT_EQ(GreatestCommonDivisor(12, 18), 6, "GCD_12_18");
ASSERT_EQ(GreatestCommonDivisor(17, 13), 1, "GCD_17_13");
ASSERT_EQ(GreatestCommonDivisor(0,   5), 5, "GCD_0_5");

// Q_log2
ASSERT_EQ(Q_log2(1),    0,  "Qlog2_1");
ASSERT_EQ(Q_log2(2),    1,  "Qlog2_2");
ASSERT_EQ(Q_log2(1024), 10, "Qlog2_1024");

// Invert24To16: tiny -> sentinel; 0x1000000 (= 1.0 in 8.24) -> 0x10000 (= 1.0 in 16.16)
ASSERT_EQ(Invert24To16(255), 0xFFFFFFFF, "Invert24To16_tiny");
ASSERT_EQ(Invert24To16(0x1000000), 0x10000, "Invert24To16_unit");

// R_ConcatRotations: I * I = I (sample two cells)
F64 _I[9];
F64 _O[9];
MemSet(_I, 0, sizeof(_I));
_I[0] = 1.0; _I[4] = 1.0; _I[8] = 1.0;
R_ConcatRotations(_I, _I, _O);
ASSERT_NEAR(_O[0], 1.0, _eps, "R_ConcatRotations_I_00");
ASSERT_NEAR(_O[4], 1.0, _eps, "R_ConcatRotations_I_11");
ASSERT_NEAR(_O[8], 1.0, _eps, "R_ConcatRotations_I_22");
ASSERT_NEAR(_O[1], 0.0, _eps, "R_ConcatRotations_I_01");

TEST_SUMMARY;
