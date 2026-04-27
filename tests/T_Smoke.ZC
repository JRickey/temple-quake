// T_Smoke.ZC — bare-minimum sanity: does our test harness print anything?

PASS("smoke.bare");
ASSERT_EQ(1 + 1, 2, "smoke.add");

F64 _smoke_v[3];
_smoke_v[0] = 3.0; _smoke_v[1] = 4.0; _smoke_v[2] = 0.0;
ASSERT_NEAR(Length(_smoke_v), 5.0, 0.000000001, "smoke.length");
ASSERT_VEC3(_smoke_v, 3.0, 4.0, 0.0, 0.000000001, "smoke.vec3");

TEST_SUMMARY;
