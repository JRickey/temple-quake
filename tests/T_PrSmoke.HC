// T_PrSmoke.HC — end-to-end smoke test for the QuakeC VM.
//
// Builds a small but multi-feature progs.dat in memory, writes it to
// disk, loads it back through PR_LoadProgsFromFile, then executes
// `main`. The program does:
//
//   1. ADD_V on two vec3 constants (exercises vector arithmetic)
//   2. STORE_F a string-offset constant into OFS_PARM0
//   3. CALL1 the `print` builtin
//   4. DONE
//
// Success criterion: `print` is dispatched exactly once with the
// expected string. This validates the full Phase 4 spine —
// FileWrite → FileRead → header parse → loader → ADD_V → STORE_F →
// CALL1 → builtin dispatch → DONE — in a single bytecode run.

U8 _smoke_progs[1024];
I64 _smoke_i;
for (_smoke_i = 0; _smoke_i < 1024; _smoke_i++) {
  _smoke_progs[_smoke_i] = 0;
}

dprograms_t *_smoke_hdr = _smoke_progs;
_smoke_hdr->version       = 6;
_smoke_hdr->crc           = 0;
_smoke_hdr->ofs_statements = 64;
_smoke_hdr->numstatements  = 8;
_smoke_hdr->ofs_globaldefs = 64 + 8 * sizeof(dstatement_t);
_smoke_hdr->numglobaldefs  = 0;
_smoke_hdr->ofs_fielddefs  = _smoke_hdr->ofs_globaldefs;
_smoke_hdr->numfielddefs   = 0;
_smoke_hdr->ofs_functions  = _smoke_hdr->ofs_globaldefs;
_smoke_hdr->numfunctions   = 3;
_smoke_hdr->ofs_strings    = _smoke_hdr->ofs_functions
                           + 3 * sizeof(dfunction_t);
_smoke_hdr->numstrings     = 8;          // "\0ok\0main\0"
_smoke_hdr->ofs_globals    = _smoke_hdr->ofs_strings + 8;
_smoke_hdr->numglobals     = 64;
_smoke_hdr->entityfields   = 0;

// Statements: sentinel at [0], program at [1..4], OP_DONE padding after.
dstatement_t *_smoke_st = _smoke_progs + _smoke_hdr->ofs_statements;
I64 _smoke_si;
for (_smoke_si = 0; _smoke_si < 8; _smoke_si++) {
  _smoke_st[_smoke_si].op = OP_DONE;
}
// stmt[1]: ADD_V 40,43 → 46
_smoke_st[1].op = OP_ADD_V; _smoke_st[1].a = 40; _smoke_st[1].b = 43;
_smoke_st[1].c = 46;
// stmt[2]: STORE_F 51 → OFS_PARM0  (copy the string-offset constant)
_smoke_st[2].op = OP_STORE_F; _smoke_st[2].a = 51;
_smoke_st[2].b = OFS_PARM0; _smoke_st[2].c = 0;
// stmt[3]: CALL1 52 (globals[52] = function index of `print` = 1)
_smoke_st[3].op = OP_CALL1; _smoke_st[3].a = 52;
_smoke_st[3].b = 0; _smoke_st[3].c = 0;
// stmt[4]: DONE
_smoke_st[4].op = OP_DONE;

// Functions: [0] sentinel, [1] print (builtin), [2] main.
dfunction_t *_smoke_fn = _smoke_progs + _smoke_hdr->ofs_functions;
_smoke_fn[0].first_statement = 0;
_smoke_fn[0].s_name          = 0;
// print: builtin #1
_smoke_fn[1].first_statement = -1;
_smoke_fn[1].parm_start      = 0;
_smoke_fn[1].locals          = 0;
_smoke_fn[1].s_name          = 0;
_smoke_fn[1].numparms        = 1;
_smoke_fn[1].parm_size[0]    = 1;
// main
_smoke_fn[2].first_statement = 1;
_smoke_fn[2].parm_start      = 30;
_smoke_fn[2].locals          = 0;
_smoke_fn[2].s_name          = 4;             // "main" (after \0ok\0)
_smoke_fn[2].numparms        = 0;

// Strings: "\0ok\0main\0"  → ok at offset 1, main at offset 4.
U8 *_smoke_str = _smoke_progs + _smoke_hdr->ofs_strings;
_smoke_str[0] = 0;
_smoke_str[1] = 'o'; _smoke_str[2] = 'k'; _smoke_str[3] = 0;
_smoke_str[4] = 'm'; _smoke_str[5] = 'a'; _smoke_str[6] = 'i';
_smoke_str[7] = 'n';

// Disk round-trip + load.
FileWrite("::/Tmp/T_PrSmoke.dat", _smoke_progs, 1024);
ASSERT_EQ(PR_LoadProgsFromFile("::/Tmp/T_PrSmoke.dat") == TRUE, 1,
          "smoke.load_from_file");
ASSERT_EQ(pr_numfunctions, 3, "smoke.numfunctions");
ASSERT_EQ(Q_strcmp(_PR_GetString(1), "ok"), 0, "smoke.strings_ok");
ASSERT_EQ(Q_strcmp(PR_FunctionName(2), "main"), 0, "smoke.function_name_main");

// Seed the operand globals AFTER load (load resets the buffer pointers
// but the slot values come from the buffer's globals region; the
// values we set in _smoke_progs[ofs_globals + ...] would persist, but
// it's clearer to set them directly via pr_globals here).
_PR_SetFloat(40, 1.0); _PR_SetFloat(41, 2.0); _PR_SetFloat(42, 3.0);
_PR_SetFloat(43, 4.0); _PR_SetFloat(44, 5.0); _PR_SetFloat(45, 6.0);
pr_globals[51] = 1;                              // string offset of "ok"
pr_globals[52] = 1;                              // function index of print

// Execute main.
pr_last_builtin_called = 0;
pr_last_builtin_arg0_str[0] = 0;
PR_ExecuteProgram(2);

// Assertions: ADD_V worked, print fired with "ok".
ASSERT_NEAR(_PR_GetFloat(46), 5.0, 0.0001, "smoke.add_v_x");
ASSERT_NEAR(_PR_GetFloat(47), 7.0, 0.0001, "smoke.add_v_y");
ASSERT_NEAR(_PR_GetFloat(48), 9.0, 0.0001, "smoke.add_v_z");
ASSERT_EQ(pr_last_builtin_called, 1, "smoke.print_invoked");
ASSERT_EQ(Q_strcmp(pr_last_builtin_arg0_str, "ok"), 0,
          "smoke.print_received_ok");
ASSERT_EQ(pr_halted == TRUE, 1, "smoke.exec_halted_cleanly");
