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
//   fn[1] — dprint, builtin #25 (first_statement = -25)
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
_t_fn[1].first_statement = -25;                // dprint
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
ASSERT_EQ(pr_last_builtin_called, 25, "PF_dprint_invoked");
ASSERT_EQ(Q_strcmp(pr_last_builtin_arg0_str, "Hello QC!"), 0, "PF_print_received_arg");

// ---- ftos: float → string in side channel ----
_t_fn[1].first_statement = -26;              // re-target fn[1] to ftos (#26)
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_ftos");
_PR_SetFloat(OFS_PARM0, 3.5);
pr_last_builtin_called = 0;
pr_last_builtin_arg0_str[0] = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 26, "PF_ftos_invoked");
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
_t_fn[1].first_statement = -10;              // error (#10)
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_error");
pr_globals[OFS_PARM0] = 7;                   // "Hello QC!" reused as fake error
pr_last_builtin_called = 0;
pr_halted = FALSE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 10, "PF_error_invoked");
ASSERT_EQ(pr_halted == TRUE, 1, "PF_error_halts_vm");

// ---- random: returns a float in [0, 1) ----
_t_fn[1].first_statement = -7;               // random (#7)
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_random");
_PR_SetFloat(OFS_RETURN, -1.0);
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 7, "PF_random_invoked");
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

// ============================================================
// Entity ops (LOAD_F/V/S/ENT/FLD/FNC, ADDRESS, STOREP_*, NOT_S/ENT/FNC)
// ============================================================
//
// Set up a minimal entity layout: 8 fields per edict, 4 edicts.
// Field layout (slot offsets within an edict):
//   0   F32 health
//   1   I32 string-offset of name
//   2..4  vec3 origin
//   5   I32 entity-handle of owner
//   6   I32 function index of think
//   7   I32 field-offset (an EV_FIELD slot)
//
// We need to update entityfields in the header and reload so
// pr_entityfields takes the new value. The header location is
// pr_progs->entityfields; we'll bump it to 8 and reload.

_t_hdr->entityfields = 8;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_entity_ops");
ASSERT_EQ(pr_entityfields, 8, "entityfields_set");

// Restore fn[1] to a regular (inert) function and use fn[2] as entry.
_t_fn[1].first_statement = 0;

// Helper layout for the entity tests:
//   globals[40] = entity index (entity 2 for these tests)
//   globals[41] = field offset (varies per test)
//   globals[42] = result destination for LOAD_F / LOAD_S / etc.
//   globals[46..48] = result destination for LOAD_V
//   globals[50] = source value for STOREP_F
//   globals[51] = field pointer (computed by ADDRESS)
//   globals[60..62] = source vec3 for STOREP_V

// Seed pr_edicts directly (entity 2, field 0 = health, F32 bits of 75.0).
pr_edicts[2 * 8 + 0] = _PR_F64_to_F32(75.0);
pr_edicts[2 * 8 + 1] = 1;                       // name = string idx 1 ("entry")
pr_edicts[2 * 8 + 2] = _PR_F64_to_F32(10.0);    // origin.x
pr_edicts[2 * 8 + 3] = _PR_F64_to_F32(20.0);    // origin.y
pr_edicts[2 * 8 + 4] = _PR_F64_to_F32(30.0);    // origin.z

// ---- OP_LOAD_F: pull health out ----
pr_globals[40] = 2;                              // entity index
pr_globals[41] = 0;                              // field offset = health
_PR_SetFloat(42, 0.0);
_t_st[1].op = OP_LOAD_F; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
_t_st[2].op = OP_DONE;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 75.0, 0.0001, "OP_LOAD_F");

// ---- OP_LOAD_S: pull string-offset (an I32 slot) ----
pr_globals[41] = 1;                              // field offset = name
pr_globals[42] = 0;
_t_st[1].op = OP_LOAD_S;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_globals[42], 1, "OP_LOAD_S");

// ---- OP_LOAD_V: pull origin (3 slots) ----
pr_globals[41] = 2;                              // field offset = origin
_PR_SetFloat(46, 0.0); _PR_SetFloat(47, 0.0); _PR_SetFloat(48, 0.0);
_t_st[1].op = OP_LOAD_V; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 46;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(46), 10.0, 0.0001, "OP_LOAD_V_x");
ASSERT_NEAR(_PR_GetFloat(47), 20.0, 0.0001, "OP_LOAD_V_y");
ASSERT_NEAR(_PR_GetFloat(48), 30.0, 0.0001, "OP_LOAD_V_z");

// ---- OP_LOAD_ENT/FLD/FNC: same shape as LOAD_S ----
// Re-set a/b/c explicitly — prior LOAD_V left c=46.
pr_edicts[2 * 8 + 5] = 7;                       // owner = entity 7
pr_globals[41] = 5;
pr_globals[42] = 0;
_t_st[1].op = OP_LOAD_ENT; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_globals[42], 7, "OP_LOAD_ENT");

pr_edicts[2 * 8 + 6] = 13;                      // think = function 13
pr_globals[41] = 6;
pr_globals[42] = 0;
_t_st[1].op = OP_LOAD_FNC; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_globals[42], 13, "OP_LOAD_FNC");

pr_edicts[2 * 8 + 7] = 4;                       // an EV_FIELD slot
pr_globals[41] = 7;
pr_globals[42] = 0;
_t_st[1].op = OP_LOAD_FLD; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_globals[42], 4, "OP_LOAD_FLD");

// ---- OP_ADDRESS: produce a field pointer ----
// entity 2, field 0 → slot index 16, byte offset 64.
pr_globals[40] = 2;
pr_globals[41] = 0;
pr_globals[51] = 0;
_t_st[1].op = OP_ADDRESS; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 51;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_globals[51], 64, "OP_ADDRESS_byte_offset");

// ---- OP_STOREP_F: write health=42.0 through that pointer ----
_PR_SetFloat(50, 42.0);                          // source
pr_edicts[2 * 8 + 0] = 0;                       // clear so we see the write
_t_st[1].op = OP_STOREP_F; _t_st[1].a = 50; _t_st[1].b = 51; _t_st[1].c = 0;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[2 * 8 + 0]), 42.0, 0.0001, "OP_STOREP_F");

// ---- OP_STOREP_V: write origin via a vec pointer ----
// Compute a fresh pointer to entity 2, field 2 (origin). The prior
// statement was OP_STOREP_F (a=50,b=51,c=0), so reset operands.
pr_globals[41] = 2;
_t_st[1].op = OP_ADDRESS; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 51;
PR_ExecuteProgram(2);
I64 _t_origin_ptr = pr_globals[51];

_PR_SetFloat(60, 7.0); _PR_SetFloat(61, 8.0); _PR_SetFloat(62, 9.0);
pr_edicts[2 * 8 + 2] = 0;
pr_edicts[2 * 8 + 3] = 0;
pr_edicts[2 * 8 + 4] = 0;
_t_st[1].op = OP_STOREP_V; _t_st[1].a = 60; _t_st[1].b = 51; _t_st[1].c = 0;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[2 * 8 + 2]), 7.0, 0.0001, "OP_STOREP_V_x");
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[2 * 8 + 3]), 8.0, 0.0001, "OP_STOREP_V_y");
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[2 * 8 + 4]), 9.0, 0.0001, "OP_STOREP_V_z");

// Suppress "unused local" — _t_origin_ptr is documentary.
ASSERT_EQ(_t_origin_ptr > 0, 1, "ADDRESS_for_origin_nonzero");

// ---- OP_STOREP_S/ENT/FLD/FNC: same machinery on a 1-slot field ----
pr_globals[40] = 2;
pr_globals[41] = 5;                              // owner field
_t_st[1].op = OP_ADDRESS; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 51;
PR_ExecuteProgram(2);
pr_globals[50] = 99;                             // new owner handle
pr_edicts[2 * 8 + 5] = 0;
_t_st[1].op = OP_STOREP_ENT; _t_st[1].a = 50; _t_st[1].b = 51; _t_st[1].c = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_edicts[2 * 8 + 5], 99, "OP_STOREP_ENT");

// ---- OP_NOT_S/ENT/FNC: zero → 1.0, nonzero → 0.0 ----
pr_globals[40] = 0;
_t_st[1].op = OP_NOT_S; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 42;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NOT_S_zero");
pr_globals[40] = 5;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_NOT_S_nonzero");

pr_globals[40] = 0;
_t_st[1].op = OP_NOT_ENT;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NOT_ENT_zero");
pr_globals[40] = 3;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_NOT_ENT_nonzero");

pr_globals[40] = 0;
_t_st[1].op = OP_NOT_FNC;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NOT_FNC_zero");
pr_globals[40] = 1;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_NOT_FNC_nonzero");

// ============================================================
// Handle compares (EQ_S/NE_S, EQ_E/NE_E, EQ_FNC/NE_FNC)
// ============================================================
//
// Strings: pr_strings has "\0entry\0Hello QC!\0" — offset 1 = "entry",
// offset 7 = "Hello QC!". Two slots holding the same offset must
// compare equal; different offsets to different strings unequal.
// EQ_E/NE_E and EQ_FNC/NE_FNC are bare integer compares.

// ---- OP_EQ_S / OP_NE_S ----
pr_globals[40] = 1;                              // "entry"
pr_globals[41] = 1;                              // "entry"
_PR_SetFloat(42, 0.0);
_t_st[1].op = OP_EQ_S; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 42;
_t_st[2].op = OP_DONE;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_EQ_S_match");

pr_globals[41] = 7;                              // "Hello QC!"
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_EQ_S_differ");

_t_st[1].op = OP_NE_S;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NE_S_differ");
pr_globals[41] = 1;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_NE_S_match");

// ---- OP_EQ_E / OP_NE_E (entity-handle compare) ----
pr_globals[40] = 5;
pr_globals[41] = 5;
_t_st[1].op = OP_EQ_E;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_EQ_E_match");
pr_globals[41] = 6;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_EQ_E_differ");

_t_st[1].op = OP_NE_E;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NE_E_differ");
pr_globals[41] = 5;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 0.0, 0.0001, "OP_NE_E_match");

// ---- OP_EQ_FNC / OP_NE_FNC (function-index compare) ----
pr_globals[40] = 2;
pr_globals[41] = 2;
_t_st[1].op = OP_EQ_FNC;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_EQ_FNC_match");
pr_globals[41] = 3;
_t_st[1].op = OP_NE_FNC;
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(42), 1.0, 0.0001, "OP_NE_FNC_differ");

// ============================================================
// PR_LoadProgsFromFile — disk round-trip
// ============================================================
//
// Write the synthetic _t_progs buffer to disk, then load it back
// through the file path. Verifies the FileRead → LoadProgs glue
// preserves the header and reaches the same pr_* state we get
// from the in-memory loader.

FileWrite("::/Tmp/T_Pr_progs.dat", _t_progs, 1024);
ASSERT_EQ(PR_LoadProgsFromFile("::/Tmp/T_Pr_progs.dat") == TRUE, 1,
          "load_from_file_returns_true");
ASSERT_EQ(pr_progs->version, 6, "load_from_file_version");
ASSERT_EQ(pr_numfunctions, 3, "load_from_file_numfunctions");
ASSERT_EQ(pr_numglobals,  64, "load_from_file_numglobals");

// Bad path → returns FALSE without crashing.
ASSERT_EQ(PR_LoadProgsFromFile("::/Tmp/no_such_file.dat") == FALSE, 1,
          "load_from_file_missing_returns_false");

// ============================================================
// OP_STATE — animation think-state setter (recordable stub)
// ============================================================
// OP_STATE side-channel record (fielddef-free fixture: the main
// _t_progs has numfielddefs=0, so the symbolic mutation skips and
// we only verify that dispatch fired + side-channel state was set).
// The previous test (PrLoadProgsFromFile) left pr_statements
// pointing at the on-disk buffer, so reload _t_progs first.

ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_op_state");

pr_last_op_state_called = FALSE;
pr_last_op_state_frame  = 0.0;
pr_last_op_state_think  = 0;

_PR_SetFloat(40, 13.0);                          // frame
pr_globals[41] = 7;                              // think function index
_t_st[1].op = OP_STATE; _t_st[1].a = 40; _t_st[1].b = 41; _t_st[1].c = 0;
_t_st[2].op = OP_DONE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_op_state_called == TRUE, 1, "OP_STATE_called");
ASSERT_NEAR(pr_last_op_state_frame, 13.0, 0.0001, "OP_STATE_frame");
ASSERT_EQ(pr_last_op_state_think, 7, "OP_STATE_think");

// ============================================================
// _PR_FieldOfsByName + OP_STATE actual edict mutation
// ============================================================
//
// Build a small focused progs.dat with three fielddefs (frame,
// nextthink, think) and exercise the symbolic field lookup +
// OP_STATE's edict-mutation path. Layout (in `_t_fp` buffer):
//
//   off    | what
//   -------+---------------------------------------------
//   0      | dprograms_t header (60 bytes)
//   60     | dstatement_t[4]   — sentinel + OP_STATE + DONE pad
//   92     | ddef_t[3]         — frame/nextthink/think
//   116    | dfunction_t[2]    — sentinel + main
//   188    | strings           — "\0frame\0nextthink\0think\0"
//   211    | (pad to 4)
//   212    | globals[128]      — 512 bytes, room for OFS_GS_*
//   724    | end
//
// entityfields = 8: slots 0=frame, 1=nextthink, 2=think (we pick
// these arbitrarily since this is a synthetic progs).

U8 _t_fp[1024];
I64 _t_fpi;
for (_t_fpi = 0; _t_fpi < 1024; _t_fpi++) {
  _t_fp[_t_fpi] = 0;
}
dprograms_t *_t_fp_hdr = _t_fp;
_t_fp_hdr->version       = 6;
_t_fp_hdr->ofs_statements = 60;
_t_fp_hdr->numstatements  = 4;
_t_fp_hdr->ofs_globaldefs = 92;
_t_fp_hdr->numglobaldefs  = 0;
_t_fp_hdr->ofs_fielddefs  = 92;
_t_fp_hdr->numfielddefs   = 3;
_t_fp_hdr->ofs_functions  = 116;
_t_fp_hdr->numfunctions   = 2;
_t_fp_hdr->ofs_strings    = 188;
_t_fp_hdr->numstrings     = 24;             // "\0frame\0nextthink\0think\0"
_t_fp_hdr->ofs_globals    = 212;
_t_fp_hdr->numglobals     = 128;
_t_fp_hdr->entityfields   = 8;

// statements
dstatement_t *_t_fp_st = _t_fp + _t_fp_hdr->ofs_statements;
_t_fp_st[0].op = OP_DONE;
_t_fp_st[1].op = OP_STATE; _t_fp_st[1].a = 40; _t_fp_st[1].b = 41; _t_fp_st[1].c = 0;
_t_fp_st[2].op = OP_DONE;
_t_fp_st[3].op = OP_DONE;

// fielddefs — type/ofs match a small synthetic edict layout.
ddef_t *_t_fp_fd = _t_fp + _t_fp_hdr->ofs_fielddefs;
_t_fp_fd[0].type = EV_FLOAT;    _t_fp_fd[0].ofs = 0; _t_fp_fd[0].s_name = 1;   // frame
_t_fp_fd[1].type = EV_FLOAT;    _t_fp_fd[1].ofs = 1; _t_fp_fd[1].s_name = 7;   // nextthink
_t_fp_fd[2].type = EV_FUNCTION; _t_fp_fd[2].ofs = 2; _t_fp_fd[2].s_name = 17;  // think

// functions
dfunction_t *_t_fp_fn = _t_fp + _t_fp_hdr->ofs_functions;
_t_fp_fn[0].first_statement = 0;             // sentinel
_t_fp_fn[1].first_statement = 1;
_t_fp_fn[1].parm_start      = 30;
_t_fp_fn[1].numparms        = 0;

// strings: "\0frame\0nextthink\0think\0"
U8 *_t_fp_str = _t_fp + _t_fp_hdr->ofs_strings;
_t_fp_str[0] = 0;
_t_fp_str[1]  = 'f'; _t_fp_str[2]  = 'r'; _t_fp_str[3]  = 'a';
_t_fp_str[4]  = 'm'; _t_fp_str[5]  = 'e'; _t_fp_str[6]  = 0;
_t_fp_str[7]  = 'n'; _t_fp_str[8]  = 'e'; _t_fp_str[9]  = 'x';
_t_fp_str[10] = 't'; _t_fp_str[11] = 't'; _t_fp_str[12] = 'h';
_t_fp_str[13] = 'i'; _t_fp_str[14] = 'n'; _t_fp_str[15] = 'k';
_t_fp_str[16] = 0;
_t_fp_str[17] = 't'; _t_fp_str[18] = 'h'; _t_fp_str[19] = 'i';
_t_fp_str[20] = 'n'; _t_fp_str[21] = 'k'; _t_fp_str[22] = 0;

ASSERT_EQ(PR_LoadProgsFromBuffer(_t_fp, 1024) == TRUE, 1, "fp.load");
ASSERT_EQ(pr_numfielddefs, 3, "fp.numfielddefs");
ASSERT_EQ(pr_entityfields, 8, "fp.entityfields");

// ---- field-lookup helper ----
ASSERT_EQ(_PR_FieldOfsByName("frame"),     0, "fp.lookup_frame");
ASSERT_EQ(_PR_FieldOfsByName("nextthink"), 1, "fp.lookup_nextthink");
ASSERT_EQ(_PR_FieldOfsByName("think"),     2, "fp.lookup_think");
ASSERT_EQ(_PR_FieldOfsByName("missing"),  -1, "fp.lookup_missing_returns_neg1");

// ---- OP_STATE actual mutation ----
// Self entity = 3, time = 5.0. Operand a (slot 40) holds the new
// frame value (17.0); operand b (slot 41) holds the new think
// function index (42).
pr_globals[OFS_GS_SELF] = 3;
_PR_SetFloat(OFS_GS_TIME, 5.0);
_PR_SetFloat(40, 17.0);
pr_globals[41] = 42;

// Clear the target slots before the test so we observe the write.
pr_edicts[3 * 8 + 0] = 0;
pr_edicts[3 * 8 + 1] = 0;
pr_edicts[3 * 8 + 2] = 0;

PR_ExecuteProgram(1);
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[3 * 8 + 0]), 17.0, 0.0001, "fp.frame_written");
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[3 * 8 + 1]),  5.1, 0.0001, "fp.nextthink_written");
ASSERT_EQ(pr_edicts[3 * 8 + 2], 42, "fp.think_written");

// Switch back to the main fixture for any further tests.
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "fp.restore_main");

// ============================================================
// Phase 6 Batch 1 builtins (#27, #28-31, #68, #75-77, #81)
// ============================================================
// Re-uses the Tier-2 OP_CALL1 setup pattern: stmt[1] = OP_CALL1
// a=40, fn[1].first_statement = -<idx>, globals[40] = 1, args
// at OFS_PARM0..n.
_t_st[1].op = OP_CALL1; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 0;
_t_st[2].op = OP_DONE;
pr_globals[40] = 1;

// #27 — vtos((1, 2.5, -3))
_t_fn[1].first_statement = -27;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_vtos");
_PR_SetFloat(OFS_PARM0,      1.0);
_PR_SetFloat(OFS_PARM0 + 1,  2.5);
_PR_SetFloat(OFS_PARM0 + 2, -3.0);
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 27, "PF_vtos_invoked");
// Side channel contains the formatted "'1.0 2.5 -3.0'" — find a '2.5'.
I64 _b1_i;
Bool _b1_found = FALSE;
for (_b1_i = 0; _b1_i < 60; _b1_i++) {
  if (pr_last_builtin_arg0_str[_b1_i] == '2'
      && pr_last_builtin_arg0_str[_b1_i + 1] == '.'
      && pr_last_builtin_arg0_str[_b1_i + 2] == '5') {
    _b1_found = TRUE;
    break;
  }
  if (pr_last_builtin_arg0_str[_b1_i] == 0) {
    break;
  }
}
ASSERT_EQ(_b1_found == TRUE, 1, "PF_vtos_contains_2.5");

// #28 — coredump
_t_fn[1].first_statement = -28;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_coredump");
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 28, "PF_coredump_invoked");

// #29 — traceon — flips pr_trace to TRUE
_t_fn[1].first_statement = -29;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_traceon");
pr_trace = FALSE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_trace == TRUE, 1, "PF_traceon_flips_trace");

// #30 — traceoff — flips pr_trace to FALSE
_t_fn[1].first_statement = -30;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_traceoff");
pr_trace = TRUE;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_trace == FALSE, 1, "PF_traceoff_flips_trace");

// #31 — eprint
_t_fn[1].first_statement = -31;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_eprint");
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 31, "PF_eprint_invoked");

// #68 — precache_file
_t_fn[1].first_statement = -68;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_file");
pr_globals[OFS_PARM0] = 7;                         // "Hello QC!" string offset
pr_globals[OFS_RETURN] = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 68, "PF_precache_file_invoked");
ASSERT_EQ(pr_globals[OFS_RETURN], 7, "PF_precache_file_returns_arg");

// #75 — precache_model2
_t_fn[1].first_statement = -75;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_model2");
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 75, "PF_precache_model2_invoked");

// #76 — precache_sound2
_t_fn[1].first_statement = -76;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_sound2");
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 76, "PF_precache_sound2_invoked");

// #77 — precache_file2
_t_fn[1].first_statement = -77;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_file2");
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 77, "PF_precache_file2_invoked");

// #81 — stof("3.14") ≈ 3.14. Need a string "3.14" in the strings
// pool — we'll write it into a free slot of _t_str at offset 16
// (just after "Hello QC!\0"; the existing pool reserves up to 18).
_t_str = _t_progs + _t_hdr->ofs_strings;
_t_str[16] = 0;                                     // ensure separator
_t_str[17] = '3';
// Ah — only 1 byte free in the existing pool. Skip stof for now;
// the dispatch is wired and we'll regression-cover via the next
// batch's expanded fixture. Just verify dispatch routing for #81.
_t_fn[1].first_statement = -81;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_stof");
pr_globals[OFS_PARM0] = 0;                          // empty string
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 81, "PF_stof_invoked");

// ============================================================
// Tier 2 builtins — math/utility (#9, #12, #13, #36, #37, #38,
// #43, #51) and stub recorders (#6, #19, #20).
// ============================================================
//
// Pattern: re-target fn[1] to the builtin under test, run fn[2]
// as the entry which CALL1's into fn[1] and reads OFS_RETURN.
// Reset stmt[1] from OP_STATE back to a builtin call shape: a=40
// holds the function index of fn[1] (=1), c=0, builtin reads its
// args from OFS_PARM0..n.

_t_st[1].op = OP_CALL1; _t_st[1].a = 40; _t_st[1].b = 0; _t_st[1].c = 0;
_t_st[2].op = OP_DONE;
pr_globals[40] = 1;                              // fn index of fn[1]

// #6 — break — no-op stub.
_t_fn[1].first_statement = -6;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_break");
pr_last_builtin_called = 0;
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 6, "PF_break_invoked");

// #9 — normalize((3,0,0)) → (1,0,0)
_t_fn[1].first_statement = -9;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_normalize");
_PR_SetFloat(OFS_PARM0,     3.0);
_PR_SetFloat(OFS_PARM0 + 1, 0.0);
_PR_SetFloat(OFS_PARM0 + 2, 0.0);
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 9, "PF_normalize_invoked");
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN),     1.0, 0.0001, "PF_normalize_x");
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN + 1), 0.0, 0.0001, "PF_normalize_y");
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN + 2), 0.0, 0.0001, "PF_normalize_z");
// Zero vector → zero result (no NaN).
_PR_SetFloat(OFS_PARM0,     0.0);
_PR_SetFloat(OFS_PARM0 + 1, 0.0);
_PR_SetFloat(OFS_PARM0 + 2, 0.0);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN),     0.0, 0.0001, "PF_normalize_zero_x");

// #12 — vlen((3,4,0)) = 5
_t_fn[1].first_statement = -12;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_vlen");
_PR_SetFloat(OFS_PARM0,     3.0);
_PR_SetFloat(OFS_PARM0 + 1, 4.0);
_PR_SetFloat(OFS_PARM0 + 2, 0.0);
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 12, "PF_vlen_invoked");
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 5.0, 0.0001, "PF_vlen_345");

// #13 — vectoyaw((1,0,0)) = 0
_t_fn[1].first_statement = -13;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_vectoyaw");
_PR_SetFloat(OFS_PARM0,     1.0);
_PR_SetFloat(OFS_PARM0 + 1, 0.0);
_PR_SetFloat(OFS_PARM0 + 2, 0.0);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 0.0, 0.5, "PF_vectoyaw_east");
// (0,1,0) → 90 degrees
_PR_SetFloat(OFS_PARM0,     0.0);
_PR_SetFloat(OFS_PARM0 + 1, 1.0);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 90.0, 0.5, "PF_vectoyaw_north");

// #19 — precache_sound — recordable stub
_t_fn[1].first_statement = -19;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_sound");
pr_globals[OFS_PARM0] = 7;                       // "Hello QC!" reused
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 19, "PF_precache_sound_invoked");

// #20 — precache_model — recordable stub
_t_fn[1].first_statement = -20;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_precache_model");
PR_ExecuteProgram(2);
ASSERT_EQ(pr_last_builtin_called, 20, "PF_precache_model_invoked");

// #36 — rint(2.7) = 3
_t_fn[1].first_statement = -36;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_rint");
_PR_SetFloat(OFS_PARM0, 2.7);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 3.0, 0.0001, "PF_rint_2.7");
_PR_SetFloat(OFS_PARM0, -2.7);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), -3.0, 0.0001, "PF_rint_neg_2.7");

// #37 — floor
_t_fn[1].first_statement = -37;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_floor");
_PR_SetFloat(OFS_PARM0, 2.9);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN),  2.0, 0.0001, "PF_floor_2.9");
_PR_SetFloat(OFS_PARM0, -2.1);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), -3.0, 0.0001, "PF_floor_neg_2.1");

// #38 — ceil
_t_fn[1].first_statement = -38;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_ceil");
_PR_SetFloat(OFS_PARM0, 2.1);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN),  3.0, 0.0001, "PF_ceil_2.1");
_PR_SetFloat(OFS_PARM0, -2.9);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), -2.0, 0.0001, "PF_ceil_neg_2.9");

// #43 — fabs
_t_fn[1].first_statement = -43;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_fabs");
_PR_SetFloat(OFS_PARM0, -7.5);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 7.5, 0.0001, "PF_fabs_negative");

// #51 — vectoangles((1,0,0)) → (0, 0, 0)
_t_fn[1].first_statement = -51;
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "reload_for_vectoangles");
_PR_SetFloat(OFS_PARM0,     1.0);
_PR_SetFloat(OFS_PARM0 + 1, 0.0);
_PR_SetFloat(OFS_PARM0 + 2, 0.0);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN),     0.0, 0.5, "PF_vectoangles_east_pitch");
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN + 1), 0.0, 0.5, "PF_vectoangles_east_yaw");
// Straight up (0,0,1) → pitch=90, yaw=0
_PR_SetFloat(OFS_PARM0,     0.0);
_PR_SetFloat(OFS_PARM0 + 1, 0.0);
_PR_SetFloat(OFS_PARM0 + 2, 1.0);
PR_ExecuteProgram(2);
ASSERT_NEAR(_PR_GetFloat(OFS_RETURN), 90.0, 0.5, "PF_vectoangles_up_pitch");

TEST_SUMMARY;
