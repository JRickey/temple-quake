// T_Pr.HC — battery for src/Pr.HC.
//
// Builds a synthetic progs.dat in memory (no file IO yet) and drives
// PR_LoadProgsFromBuffer + PR_ExecuteProgram. Tests cover loader
// validation, F32↔F64 bit conversion roundtrips, and the MVP opcode
// subset (DONE, RETURN, arithmetic, comparisons, control flow,
// store, logical, bitwise).

// ---- F32 ↔ F64 bit-conversion ----
ASSERT_NEAR(_PR_F32_to_F64(0x40490FDB), 3.14159274, 0.0001, "F32_to_F64_pi");
ASSERT_NEAR(_PR_F32_to_F64(0x00000000), 0.0,        0.0001, "F32_to_F64_zero");
ASSERT_NEAR(_PR_F32_to_F64(0xBF800000), -1.0,       0.0001, "F32_to_F64_neg_one");

// Roundtrip: F32→F64→F32 must preserve bits for representable values.
ASSERT_EQ(_PR_F64_to_F32(_PR_F32_to_F64(0x40490FDB)) & 0xFFFFFFFF,
          0x40490FDB, "F32_F64_roundtrip_pi");
ASSERT_EQ(_PR_F64_to_F32(_PR_F32_to_F64(0x00000000)) & 0xFFFFFFFF,
          0x00000000, "F32_F64_roundtrip_zero");
ASSERT_EQ(_PR_F64_to_F32(_PR_F32_to_F64(0xBF800000)) & 0xFFFFFFFF,
          0xBF800000, "F32_F64_roundtrip_neg_one");

// ---- Build a synthetic progs.dat ----
//
// Layout (in `_t_progs`, 1024 bytes total):
//
//   off    | what
//   -------+--------------------------------------------------------
//   0      | dprograms_t header (60 bytes)
//   64     | dstatement_t[2]   — sentinel + the first executable
//   80     | ddef_t[0]         — empty globaldefs
//   80     | ddef_t[0]         — empty fielddefs
//   80     | dfunction_t[1]    — one function
//   116    | strings           — "\0entry\0"
//   128    | globals[64]       — 256 bytes of slots
//
// Functions point first_statement = 1 (statement 0 is the conventional
// error sentinel).

U8 _t_progs[1024];
I64 _t_i;
for (_t_i = 0; _t_i < 1024; _t_i++) {
  _t_progs[_t_i] = 0;
}

dprograms_t *_t_hdr = _t_progs;
// 16 statement slots (128 bytes) — gives every test room to grow
// without the layout overlapping the function table.
_t_hdr->version       = 6;
_t_hdr->crc           = 0;
_t_hdr->ofs_statements = 64;
_t_hdr->numstatements  = 16;      // [0]=sentinel; [1..] reused per test
_t_hdr->ofs_globaldefs = 64 + 16 * sizeof(dstatement_t);
_t_hdr->numglobaldefs  = 0;
_t_hdr->ofs_fielddefs  = _t_hdr->ofs_globaldefs;
_t_hdr->numfielddefs   = 0;
_t_hdr->ofs_functions  = _t_hdr->ofs_globaldefs;
_t_hdr->numfunctions   = 1;
// Reserve room for 4 dfunction_t slots even though we only declare 1
// up front — the OP_CALL tests later in this battery bump
// numfunctions to 3 without re-laying-out the buffer, and we don't
// want the function table to extend into the strings region.
_t_hdr->ofs_strings    = _t_hdr->ofs_functions + 4 * sizeof(dfunction_t);
_t_hdr->numstrings     = 7;       // "\0entry\0"
_t_hdr->ofs_globals    = _t_hdr->ofs_strings + 7;
_t_hdr->numglobals     = 64;
_t_hdr->entityfields   = 0;

// statements: sentinel + 15 slots of OP_DONE; tests overwrite the
// slots they need.
dstatement_t *_t_st = _t_progs + _t_hdr->ofs_statements;
I64 _t_si;
for (_t_si = 0; _t_si < 16; _t_si++) {
  _t_st[_t_si].op = OP_DONE;
  _t_st[_t_si].a = 0;
  _t_st[_t_si].b = 0;
  _t_st[_t_si].c = 0;
}

dfunction_t *_t_fn = _t_progs + _t_hdr->ofs_functions;
_t_fn[0].first_statement = 1;
_t_fn[0].parm_start      = 30;     // after RESERVED_OFS (28)
_t_fn[0].locals          = 0;
_t_fn[0].profile         = 0;
_t_fn[0].s_name          = 1;      // "entry"
_t_fn[0].s_file          = 1;
_t_fn[0].numparms        = 0;
// parm_size[0..7] already 0

U8 *_t_str = _t_progs + _t_hdr->ofs_strings;
_t_str[0] = 0;                     // null string
_t_str[1] = 'e'; _t_str[2] = 'n'; _t_str[3] = 't';
_t_str[4] = 'r'; _t_str[5] = 'y'; _t_str[6] = 0;

// ---- Loader sanity ----
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "load_returns_true");
ASSERT_EQ(pr_progs->version, 6, "load_version");
ASSERT_EQ(pr_numstatements, 16, "load_numstatements");
ASSERT_EQ(pr_numfunctions,  1,  "load_numfunctions");
ASSERT_EQ(pr_numglobals,   64,  "load_numglobals");
ASSERT_EQ(Q_strcmp(_PR_GetString(1), "entry"), 0, "load_strings_entry");
ASSERT_EQ(Q_strcmp(PR_FunctionName(0), "entry"), 0, "FunctionName_lookup");

// ---- Trivial OP_DONE: function returns immediately ----
PR_ExecuteProgram(0);
ASSERT_EQ(pr_halted == TRUE, 1, "exec_done_halts");
ASSERT_EQ(pr_runaway == FALSE, 1, "exec_done_no_runaway");
ASSERT_EQ(_pr_depth, 0, "exec_done_clean_stack");

// ---- OP_RETURN: copy a→OFS_RETURN, then leave ----
// Set up: globals[40] = 42.0 (F32 bits). Statement[1] = OP_RETURN a=40.
_PR_SetFloat(40, 42.0);
_t_st[1].op = OP_RETURN; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 0;
_t_st[2].op = OP_DONE;
_PR_SetFloat(OFS_RETURN, 0.0);                 // clear previous
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 42.0, 0.0001, "OP_RETURN_propagates_value");

// ---- OP_ADD_F + OP_RETURN: globals[40]+globals[41] → OFS_RETURN ----
_PR_SetFloat(40, 7.0);
_PR_SetFloat(41, 35.0);
// statement[1]: ADD_F c=42 = a=40 + b=41
_t_st[1].op = OP_ADD_F; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
// statement[2]: RETURN a=42
_t_st[2].op = OP_RETURN; _t_st[2].a = 42; _t_st[2].b = 0; _t_st[2].c = 0;
_t_st[3].op = OP_DONE;
_PR_SetFloat(OFS_RETURN, 0.0);
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 42.0, 0.0001, "OP_ADD_F_then_RETURN");

// ---- OP_SUB_F / OP_MUL_F / OP_DIV_F ----
_PR_SetFloat(40, 100.0);
_PR_SetFloat(41, 25.0);
_t_st[1].op = OP_SUB_F; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
_t_st[2].op = OP_RETURN; _t_st[2].a = 42; _t_st[2].b = 0; _t_st[2].c = 0;
_t_st[3].op = OP_DONE;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 75.0, 0.0001, "OP_SUB_F");

_PR_SetFloat(40, 6.0);
_PR_SetFloat(41, 7.0);
_t_st[1].op = OP_MUL_F;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 42.0, 0.0001, "OP_MUL_F");

_PR_SetFloat(40, 84.0);
_PR_SetFloat(41, 2.0);
_t_st[1].op = OP_DIV_F;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 42.0, 0.0001, "OP_DIV_F");

// ---- Comparisons: each yields 0.0 or 1.0 ----
_PR_SetFloat(40, 5.0);
_PR_SetFloat(41, 5.0);
_t_st[1].op = OP_EQ_F;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 1.0, 0.0001, "OP_EQ_F_true");

_PR_SetFloat(41, 6.0);
_t_st[1].op = OP_EQ_F;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.0001, "OP_EQ_F_false");

_t_st[1].op = OP_LT;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 1.0, 0.0001, "OP_LT_true");

_t_st[1].op = OP_GT;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.0001, "OP_GT_false");

// ---- Logical AND / OR / NOT ----
_PR_SetFloat(40, 1.0);
_PR_SetFloat(41, 1.0);
_t_st[1].op = OP_AND;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 1.0, 0.0001, "OP_AND_true");

_PR_SetFloat(41, 0.0);
_t_st[1].op = OP_AND;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.0001, "OP_AND_false");

_t_st[1].op = OP_OR;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 1.0, 0.0001, "OP_OR_true");

_PR_SetFloat(40, 0.0);
_t_st[1].op = OP_OR;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.0001, "OP_OR_false");

_PR_SetFloat(40, 0.0);
_t_st[1].op = OP_NOT_F; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 42;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 1.0, 0.0001, "OP_NOT_F_zero_to_one");

_PR_SetFloat(40, 5.0);
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.0001, "OP_NOT_F_nonzero_to_zero");

// ---- OP_STORE_F ----
_PR_SetFloat(40, 17.0);
_PR_SetFloat(41, 999.0);
_t_st[1].op = OP_STORE_F; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 0;
_t_st[2].op = OP_RETURN;  _t_st[2].a = 41; _t_st[2].b = 0; _t_st[2].c = 0;
_t_st[3].op = OP_DONE;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 17.0, 0.0001, "OP_STORE_F_copies_a_to_b");

// ---- OP_GOTO + OP_IFNOT control flow ----
// program:
//   stmt[1]: IFNOT a=40 b=2  ; if globals[40]==0 jump +2 → stmt[3]
//   stmt[2]: ADD_F a=40 b=41 c=42      ; otherwise compute 40+41 → 42
//   stmt[3]: RETURN a=42
//   stmt[4]: DONE  (already DONE from initial loop)
_t_st[1].op = OP_IFNOT;  _t_st[1].a = 40; _t_st[1].b = 2; _t_st[1].c = 0;
_t_st[2].op = OP_ADD_F;  _t_st[2].a = 40; _t_st[2].b = 41; _t_st[2].c = 42;
_t_st[3].op = OP_RETURN; _t_st[3].a = 42; _t_st[3].b = 0; _t_st[3].c = 0;
_t_st[4].op = OP_DONE;

// Path 1: globals[40] != 0 → ADD_F runs.
_PR_SetFloat(40, 10.0);
_PR_SetFloat(41, 32.0);
_PR_SetFloat(42, 0.0);
_PR_SetFloat(OFS_RETURN, -1.0);
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 42.0, 0.0001, "IFNOT_taken_false_runs_then");

// Path 2: globals[40] == 0 → jump skips the ADD_F.
_PR_SetFloat(40, 0.0);
_PR_SetFloat(42, 99.0);                // would-be add result; should remain
_PR_SetFloat(OFS_RETURN, -1.0);
PR_ExecuteProgram(0);
// ADD_F was skipped, so globals[42] retains its 99.0; RETURN copies that.
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 99.0, 0.0001, "IFNOT_taken_true_skips");

// ---- OP_GOTO ----
// Reset to a goto-based program: stmt[1] GOTO+2 → stmt[3] RETURN.
_t_st[1].op = OP_GOTO;   _t_st[1].a = 2;  _t_st[1].b = 0; _t_st[1].c = 0;
_t_st[2].op = OP_ADD_F;  _t_st[2].a = 40; _t_st[2].b = 41; _t_st[2].c = 42;  // skipped
_t_st[3].op = OP_RETURN; _t_st[3].a = 42; _t_st[3].b = 0; _t_st[3].c = 0;
_t_st[4].op = OP_DONE;
_PR_SetFloat(40, 1.0);
_PR_SetFloat(41, 2.0);
_PR_SetFloat(42, 7.0);
_PR_SetFloat(OFS_RETURN, -1.0);
PR_ExecuteProgram(0);
// ADD_F skipped → globals[42] still 7.0
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 7.0, 0.0001, "GOTO_skips_intermediate");

// ---- Bitwise ----
_PR_SetFloat(40, 15.0);                // 0xF
_PR_SetFloat(41, 5.0);                 // 0x5
_t_st[1].op = OP_BITAND; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
_t_st[2].op = OP_RETURN; _t_st[2].a = 42; _t_st[2].b = 0; _t_st[2].c = 0;
_t_st[3].op = OP_DONE;
_t_st[4].op = OP_DONE;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 5.0, 0.0001, "OP_BITAND");

_t_st[1].op = OP_BITOR;
PR_ExecuteProgram(0);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 15.0, 0.0001, "OP_BITOR");

// ---- Bad version rejected ----
_t_hdr->version = 99;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == FALSE, 1, "bad_version_rejected");
_t_hdr->version = 6;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_after_fix");

// ============================================================
// OP_CALL + builtin dispatch
// ============================================================
//
// We rebuild the synthetic progs.dat with three functions:
//   fn[0] — sentinel ("function 0 is empty" per Quake convention)
//   fn[1] — print, builtin #1 (first_statement = -1)
//   fn[2] — entry, calls print with OFS_PARM0 = string offset
//
// Parameters: OFS_PARM0 holds the string offset into pr_strings.
// `print` reads it and stores the resolved bytes in
// pr_last_builtin_arg0_str for assertion.

// Reset numfunctions on the existing buffer; we already have room
// because we sized the strings/globals tables generously.
_t_hdr->numfunctions = 3;
_t_hdr->numstrings   = 18;     // "\0entry\0Hello QC!\0" — 18 bytes

// Reset the strings pool: "\0entry\0Hello QC!\0"
_t_str = _t_progs + _t_hdr->ofs_strings;
_t_str[0]  = 0;
_t_str[1]  = 'e'; _t_str[2]  = 'n'; _t_str[3]  = 't';
_t_str[4]  = 'r'; _t_str[5]  = 'y'; _t_str[6]  = 0;
_t_str[7]  = 'H'; _t_str[8]  = 'e'; _t_str[9]  = 'l';
_t_str[10] = 'l'; _t_str[11] = 'o'; _t_str[12] = ' ';
_t_str[13] = 'Q'; _t_str[14] = 'C'; _t_str[15] = '!';
_t_str[16] = 0;
_t_str[17] = 0;

// fn[0] — sentinel
_t_fn[0].first_statement = 0;
_t_fn[0].parm_start      = 0;
_t_fn[0].locals          = 0;
_t_fn[0].s_name          = 0;
_t_fn[0].numparms        = 0;
// fn[1] — print, builtin #1
_t_fn[1].first_statement = -1;
_t_fn[1].parm_start      = 0;
_t_fn[1].locals          = 0;
_t_fn[1].s_name          = 0;
_t_fn[1].numparms        = 1;
_t_fn[1].parm_size[0]    = 1;
// fn[2] — entry: call print with arg
_t_fn[2].first_statement = 1;
_t_fn[2].parm_start      = 30;
_t_fn[2].locals          = 0;
_t_fn[2].s_name          = 1;
_t_fn[2].numparms        = 0;

// Statements:
//   stmt[1]: OP_CALL1 a=40   ; globals[40] holds the function
//                              index of `print` (1)
//   stmt[2]: OP_DONE
_t_st[1].op = OP_CALL1; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 0;
_t_st[2].op = OP_DONE;
_t_st[3].op = OP_DONE;
_t_st[4].op = OP_DONE;

// Reload so the runtime picks up the new function table.
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_with_call");
ASSERT_EQ(pr_numfunctions, 3, "load_three_functions");

// Pre-set the call's operand globals.
pr_globals[40] = 1;                          // function index of `print`
pr_globals[OFS_PARM0] = 7;                   // string offset of "Hello QC!"

// Execute the entry point.
pr_last_builtin_called = 0;
pr_last_builtin_arg0_str[0] = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 1, "PF_print_invoked");
ASSERT_EQ(Q_strcmp(pr_last_builtin_arg0_str, "Hello QC!"), 0, "PF_print_received_arg");

// ---- ftos: float → string in side channel ----
_t_fn[1].first_statement = -2;               // re-target fn[1] to builtin #2
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_ftos");
_PR_SetFloat(OFS_PARM0, 3.5);
pr_last_builtin_called = 0;
pr_last_builtin_arg0_str[0] = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 2, "PF_ftos_invoked");
// PF_ftos uses StrPrint with explicit "%5.1f" precision. The
// resulting string contains "3.5" somewhere (possibly with leading
// space-padding from the field width). Find a '3' followed
// by a '.' followed by '5'.
I64 _t_idx;
Bool _t_found_three_point_five = FALSE;
for (_t_idx = 0; _t_idx < 60; _t_idx++) {
  if (pr_last_builtin_arg0_str[_t_idx] == '3'
      && pr_last_builtin_arg0_str[_t_idx + 1] == '.'
      && pr_last_builtin_arg0_str[_t_idx + 2] == '5') {
    _t_found_three_point_five = TRUE;
    break;
  }
  if (pr_last_builtin_arg0_str[_t_idx] == 0) {
    break;
  }
}
ASSERT_EQ(_t_found_three_point_five == TRUE, 1, "PF_ftos_contains_3.5");

// ---- error: halts the VM ----
_t_fn[1].first_statement = -3;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_error");
pr_globals[OFS_PARM0] = 7;                   // "Hello QC!" reused as fake error
pr_last_builtin_called = 0;
pr_halted = FALSE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 3, "PF_error_invoked");
ASSERT_EQ(pr_halted == TRUE, 1, "PF_error_halts_vm");

// ---- random: returns a float in [0, 1) ----
_t_fn[1].first_statement = -4;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_random");
_PR_SetFloat(OFS_RETURN, -1.0);
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 4, "PF_random_invoked");
F64 _t_r = _PR_GetFloat(OFS_RETURN);
ASSERT_EQ(_t_r >= 0.0 && _t_r < 1.0, 1, "PF_random_in_unit_interval");

// ---- Unknown builtin index → halts cleanly ----
_t_fn[1].first_statement = -99;              // not installed
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_bad_builtin");
pr_halted = FALSE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_halted == TRUE, 1, "bad_builtin_index_halts");

// ============================================================
// Vector ops (ADD_V / SUB_V / MUL_V / MUL_FV / MUL_VF / EQ_V /
// NE_V / NOT_V). Each vec3 occupies three consecutive 4-byte global
// slots. We use globals[40..42] for `va`, [43..45] for `vb`, and
// [46..48] for the result `vc`. Re-target fn[1] back to a regular
// (non-builtin) function so OP_CALL is no longer involved — these
// tests drive the entry function directly.
// ============================================================
_t_fn[1].first_statement = 0;                   // sentinel: fn[1] inert
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_vector_ops");

// ADD_V: va + vb → vc.
_PR_SetFloat(40, 1.0); _PR_SetFloat(41,  2.0); _PR_SetFloat(42,  3.0);
_PR_SetFloat(43, 4.0); _PR_SetFloat(44, 10.0); _PR_SetFloat(45, 20.0);
_PR_SetFloat(46, 0.0); _PR_SetFloat(47,  0.0); _PR_SetFloat(48,  0.0);
_t_st[1].op = OP_ADD_V; _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
_t_st[2].op = OP_DONE;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46),  5.0, 0.0001, "OP_ADD_V_x");
ASSERT_NEAR(_PR_GetFloat(47), 12.0, 0.0001, "OP_ADD_V_y");
ASSERT_NEAR(_PR_GetFloat(48), 23.0, 0.0001, "OP_ADD_V_z");

// SUB_V: va - vb → vc.
_t_st[1].op = OP_SUB_V; _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46),  -3.0, 0.0001, "OP_SUB_V_x");
ASSERT_NEAR(_PR_GetFloat(47),  -8.0, 0.0001, "OP_SUB_V_y");
ASSERT_NEAR(_PR_GetFloat(48), -17.0, 0.0001, "OP_SUB_V_z");

// MUL_V: dot product → scalar at vc.
// va·vb = 1*4 + 2*10 + 3*20 = 4 + 20 + 60 = 84
_t_st[1].op = OP_MUL_V; _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 84.0, 0.0001, "OP_MUL_V_dot");

// MUL_FV: scalar(a) * vec(b) → vec(c). Use globals[40] = 2.5 alone.
_PR_SetFloat(40, 2.5);
_PR_SetFloat(43, 1.0); _PR_SetFloat(44, 2.0); _PR_SetFloat(45, 4.0);
_t_st[1].op = OP_MUL_FV; _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46),  2.5, 0.0001, "OP_MUL_FV_x");
ASSERT_NEAR(_PR_GetFloat(47),  5.0, 0.0001, "OP_MUL_FV_y");
ASSERT_NEAR(_PR_GetFloat(48), 10.0, 0.0001, "OP_MUL_FV_z");

// MUL_VF: vec(a) * scalar(b) → vec(c). globals[43] = 3.0.
_PR_SetFloat(40, 1.0); _PR_SetFloat(41, 2.0); _PR_SetFloat(42, 4.0);
_PR_SetFloat(43, 3.0);
_t_st[1].op = OP_MUL_VF; _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46),  3.0, 0.0001, "OP_MUL_VF_x");
ASSERT_NEAR(_PR_GetFloat(47),  6.0, 0.0001, "OP_MUL_VF_y");
ASSERT_NEAR(_PR_GetFloat(48), 12.0, 0.0001, "OP_MUL_VF_z");

// EQ_V: equal vectors → 1.0; differ in any component → 0.0.
_PR_SetFloat(40, 1.0); _PR_SetFloat(41, 2.0); _PR_SetFloat(42, 3.0);
_PR_SetFloat(43, 1.0); _PR_SetFloat(44, 2.0); _PR_SetFloat(45, 3.0);
_t_st[1].op = OP_EQ_V;  _t_st[1].a = 40; _t_st[1].b = 43; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 1.0, 0.0001, "OP_EQ_V_match");
_PR_SetFloat(45, 3.5);                          // nudge z component
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 0.0, 0.0001, "OP_EQ_V_differ");

// NE_V: differs in any component → 1.0.
_t_st[1].op = OP_NE_V;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 1.0, 0.0001, "OP_NE_V_differ");
_PR_SetFloat(45, 3.0);                          // restore equality
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 0.0, 0.0001, "OP_NE_V_match");

// NOT_V: all zero → 1.0; any nonzero → 0.0.
_PR_SetFloat(40, 0.0); _PR_SetFloat(41, 0.0); _PR_SetFloat(42, 0.0);
_t_st[1].op = OP_NOT_V; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 1.0, 0.0001, "OP_NOT_V_zero_vec");
_PR_SetFloat(41, 1.0);                          // make y nonzero
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 0.0, 0.0001, "OP_NOT_V_nonzero_vec");

TEST_SUMMARY;
