// T_Cvar.HC — battery for src/Cvar.HC.
//
// Each test allocates its own cvar_t globals so registration order
// is deterministic and we don't bleed state across cases.

cvar_t _t_draworder;
cvar_t _t_screensize;
cvar_t _t_servervar;

// Helper: zero out a cvar_t that we're about to (re)use. cvar_vars
// is a singly-linked list; if we re-register the same global it
// would loop, so each test uses a different cvar_t global.
U0 _T_setup_cvar(cvar_t *v, U8 *name, U8 *value, Bool archive, Bool server) {
  v->name = name;
  v->string = value;
  v->archive = archive;
  v->server = server;
  v->value = 0.0;
  v->next = NULL;
}

// ---- Q_atof: float parsing ----
ASSERT_NEAR(Q_atof("0"),       0.0,   0.0001, "Qatof_zero");
ASSERT_NEAR(Q_atof("1"),       1.0,   0.0001, "Qatof_int");
ASSERT_NEAR(Q_atof("-1"),     -1.0,   0.0001, "Qatof_neg_int");
ASSERT_NEAR(Q_atof("3.14"),    3.14,  0.0001, "Qatof_decimal");
ASSERT_NEAR(Q_atof("-2.5"),   -2.5,   0.0001, "Qatof_neg_decimal");
ASSERT_NEAR(Q_atof("+42"),    42.0,   0.0001, "Qatof_plus_sign");
ASSERT_NEAR(Q_atof(""),        0.0,   0.0001, "Qatof_empty");

// ---- Q_strncmp: bounded compare ----
ASSERT_EQ(Q_strncmp("abc", "abc", 3), 0, "Qstrncmp_eq");
ASSERT_EQ(Q_strncmp("abc", "abd", 3) != 0, 1, "Qstrncmp_diff");
ASSERT_EQ(Q_strncmp("abc", "abd", 2), 0, "Qstrncmp_prefix_match");
ASSERT_EQ(Q_strncmp("a",   "abc", 5), -98, "Qstrncmp_short_lhs");
ASSERT_EQ(Q_strncmp("abc", "a",   5), 98,  "Qstrncmp_short_rhs");
ASSERT_EQ(Q_strncmp("xy",  "yz",  0), 0,   "Qstrncmp_zero_len");

// ---- Cvar_RegisterVariable / Cvar_FindVar ----
_T_setup_cvar(&_t_draworder, "r_draworder", "1", FALSE, FALSE);
Cvar_RegisterVariable(&_t_draworder);
ASSERT_EQ(Cvar_FindVar("r_draworder") != NULL, 1, "register_findable");
ASSERT_EQ(Cvar_FindVar("nope") == NULL, 1, "find_missing");

// ---- value / string accessors ----
ASSERT_NEAR(Cvar_VariableValue("r_draworder"), 1.0, 0.0001, "value_after_register");
ASSERT_EQ(Q_strcmp(Cvar_VariableString("r_draworder"), "1"), 0, "string_after_register");

// ---- missing-variable defaults ----
ASSERT_NEAR(Cvar_VariableValue("nope"), 0.0, 0.0001, "missing_value_zero");
ASSERT_EQ(Q_strcmp(Cvar_VariableString("nope"), ""), 0, "missing_string_empty");

// ---- Cvar_Set ----
Cvar_Set("r_draworder", "0");
ASSERT_NEAR(Cvar_VariableValue("r_draworder"), 0.0, 0.0001, "set_updates_value");
ASSERT_EQ(Q_strcmp(Cvar_VariableString("r_draworder"), "0"), 0, "set_updates_string");

Cvar_Set("r_draworder", "2.5");
ASSERT_NEAR(Cvar_VariableValue("r_draworder"), 2.5, 0.0001, "set_decimal_value");

// ---- Cvar_SetValue (float-encoding path) ----
Cvar_SetValue("r_draworder", 7.0);
ASSERT_NEAR(Cvar_VariableValue("r_draworder"), 7.0, 0.0001, "setvalue_round_trips");

// ---- Multiple cvars + Cvar_CompleteVariable ----
_T_setup_cvar(&_t_screensize, "screensize", "1", TRUE, FALSE);
Cvar_RegisterVariable(&_t_screensize);
ASSERT_EQ(Cvar_FindVar("screensize") != NULL, 1, "second_cvar_registered");
ASSERT_EQ(Cvar_FindVar("r_draworder") != NULL, 1, "first_cvar_still_present");

ASSERT_EQ(Q_strcmp(Cvar_CompleteVariable("scr"), "screensize"), 0, "complete_prefix");
ASSERT_EQ(Cvar_CompleteVariable("xyzzy") == NULL, 1, "complete_no_match");
ASSERT_EQ(Cvar_CompleteVariable("") == NULL, 1, "complete_empty_returns_null");

// ---- archive / server flags survive registration ----
ASSERT_EQ(Cvar_FindVar("screensize")->archive == TRUE, 1, "archive_flag_preserved");
ASSERT_EQ(Cvar_FindVar("screensize")->server == FALSE, 1, "server_flag_preserved");

// ---- server cvar with sv.active = false → no broadcast crash ----
_T_setup_cvar(&_t_servervar, "teamplay", "0", FALSE, TRUE);
Cvar_RegisterVariable(&_t_servervar);
sv.active = FALSE;
Cvar_Set("teamplay", "1");  // would broadcast if sv.active; must not crash
ASSERT_NEAR(Cvar_VariableValue("teamplay"), 1.0, 0.0001, "server_cvar_set_ok_when_inactive");

TEST_SUMMARY;
