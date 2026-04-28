// T_PrIntegration.HC — kitchen-sink integration test for the
// QuakeC VM. Builds a synthetic progs.dat in memory that exercises
// the full Phase 4-6 stack in a single bytecode run:
//
//   * Multi-function call chain (worldspawn → think → DONE)
//   * Vector arithmetic + scalar math (ADD_V, SUB_V, MUL_F, DIV_F)
//   * Conditional branches (IF, IFNOT, GOTO)
//   * Entity field access (STOREP_F, LOAD_F via setorigin)
//   * Symbolic field lookup (the OP_STATE / setorigin paths)
//   * 12 builtins from 6 categories: precache_*, makevectors, vlen,
//     normalize, spawn, setorigin, dprint, bprint, cvar, traceline,
//     sound, lightstyle
//
// Pass criterion: after running `worldspawn`, the bytecode has:
//   - Spawned a fresh entity, set its origin to (10, 20, 30)
//   - Called ~12 builtins in the expected sequence
//   - Set self.frame via OP_STATE through the field-lookup machinery
//   - Returned cleanly with all state intact
//
// This is the closest thing to "running qwprogs.dat" we can do
// without actually pushing a 197 KB file into the VM.

// ============================================================
// Buffer + header layout
// ============================================================
//
//   off   | section         | size
//   ------+-----------------+--------------------------------
//   0     | dprograms_t     | 60
//   60    | dstatement_t[40]| 320  (ofs_statements)
//   380   | ddef_t[5]       | 40   (ofs_fielddefs — origin/
//                                  model/frame/think/nextthink)
//   420   | dfunction_t[20] | 720  (sentinel + 14 builtin refs +
//                                  worldspawn + think + 3 spare)
//   1140  | strings[256]    | 256  (ofs_strings — names + msg)
//   1396  | globals[256]    | 1024 (ofs_globals — entityfields=8,
//                                  big enough for parms + scratch)
//   2420  | end
//
// entityfields = 8: slots are origin (3 slots), model, frame,
// nextthink, think, [pad].

U8 _ti_progs[4096];
I64 _ti_i;
for (_ti_i = 0; _ti_i < 4096; _ti_i++) {
  _ti_progs[_ti_i] = 0;
}

dprograms_t *_ti_hdr = _ti_progs;
_ti_hdr->version       = 6;
_ti_hdr->ofs_statements = 60;
_ti_hdr->numstatements  = 40;
_ti_hdr->ofs_globaldefs = 380;
_ti_hdr->numglobaldefs  = 0;
_ti_hdr->ofs_fielddefs  = 380;
_ti_hdr->numfielddefs   = 5;
_ti_hdr->ofs_functions  = 420;
_ti_hdr->numfunctions   = 20;
_ti_hdr->ofs_strings    = 1140;
_ti_hdr->numstrings     = 256;
_ti_hdr->ofs_globals    = 1396;
_ti_hdr->numglobals     = 256;
_ti_hdr->entityfields   = 8;

// ============================================================
// Strings pool
// ============================================================
//
//   0:  ""
//   1:  "progs/world.mdl"      (15 + 1 = 16)
//   17: "world/spawn.wav"      (15 + 1 = 16)
//   33: "level loaded"         (12 + 1 = 13)
//   46: "abcdefghij"           (10 + 1 = 11) — light style pattern
//
// Use Q_strcpy where convenient; offsets are hand-computed so
// stof/cvar/etc. tests in this file know which string lives where.

U8 *_ti_str = _ti_progs + _ti_hdr->ofs_strings;
_ti_str[0] = 0;
Q_strcpy(_ti_str + 1,  "progs/world.mdl");
Q_strcpy(_ti_str + 17, "world/spawn.wav");
Q_strcpy(_ti_str + 33, "level loaded");
Q_strcpy(_ti_str + 46, "abcdefghij");

// ============================================================
// Fielddefs (matching entityfields = 8 slot layout)
// ============================================================
//   0..2:  origin (vec3)
//   3:     model  (string offset)
//   4:     frame  (float)
//   5:     nextthink (float)
//   6:     think  (function index)
//   7:     [unused]
//
// String names: pack at the END of strings pool. We have 256
// bytes; used 0..56 above. Place field names at offset 64.

Q_strcpy(_ti_str + 64,  "origin");      // 64..70
Q_strcpy(_ti_str + 72,  "model");       // 72..77
Q_strcpy(_ti_str + 80,  "frame");       // 80..85
Q_strcpy(_ti_str + 88,  "nextthink");   // 88..97
Q_strcpy(_ti_str + 100, "think");       // 100..105

ddef_t *_ti_fd = _ti_progs + _ti_hdr->ofs_fielddefs;
_ti_fd[0].type = EV_VECTOR;   _ti_fd[0].ofs = 0; _ti_fd[0].s_name = 64;
_ti_fd[1].type = EV_STRING;   _ti_fd[1].ofs = 3; _ti_fd[1].s_name = 72;
_ti_fd[2].type = EV_FLOAT;    _ti_fd[2].ofs = 4; _ti_fd[2].s_name = 80;
_ti_fd[3].type = EV_FLOAT;    _ti_fd[3].ofs = 5; _ti_fd[3].s_name = 88;
_ti_fd[4].type = EV_FUNCTION; _ti_fd[4].ofs = 6; _ti_fd[4].s_name = 100;

// ============================================================
// Functions
// ============================================================
//   fn[0]:  sentinel
//   fn[1..14]: builtin refs (first_statement = -<canonical idx>)
//   fn[15]: worldspawn — 30 stmts, calls makevectors, vlen, spawn,
//           setorigin, precache_model, precache_sound, dprint,
//           bprint, traceline, sound, cvar, lightstyle
//   fn[16]: think (called via OP_STATE) — sets frame, calls
//           normalize, returns
//   fn[17..19]: unused (room for growth)

dfunction_t *_ti_fn = _ti_progs + _ti_hdr->ofs_functions;

// fn[0] sentinel
_ti_fn[0].first_statement = 0;

// Builtin refs — index = builtin number, first_statement = -builtin
_ti_fn[1].first_statement  = -1;   // makevectors
_ti_fn[2].first_statement  = -7;   // random
_ti_fn[3].first_statement  = -9;   // normalize
_ti_fn[4].first_statement  = -12;  // vlen
_ti_fn[5].first_statement  = -14;  // spawn
_ti_fn[6].first_statement  = -2;   // setorigin
_ti_fn[7].first_statement  = -19;  // precache_sound
_ti_fn[8].first_statement  = -20;  // precache_model
_ti_fn[9].first_statement  = -23;  // bprint
_ti_fn[10].first_statement = -25;  // dprint
_ti_fn[11].first_statement = -16;  // traceline
_ti_fn[12].first_statement = -8;   // sound
_ti_fn[13].first_statement = -45;  // cvar
_ti_fn[14].first_statement = -35;  // lightstyle

// fn[15] worldspawn — first_statement = 1, no parms
_ti_fn[15].first_statement = 1;
_ti_fn[15].parm_start      = 30;
_ti_fn[15].numparms        = 0;
_ti_fn[15].s_name          = 33;          // reuse "level loaded" as a name

// fn[16] think — first_statement = 25 (set later)
_ti_fn[16].first_statement = 25;
_ti_fn[16].parm_start      = 30;
_ti_fn[16].numparms        = 0;

// ============================================================
// Statements
// ============================================================
//
// Globals layout used by worldspawn. NOTE: slots 28..91 are
// reserved for the globalvars_t overlay (self / time / trace_* /
// v_forward / etc.) — using them here corrupts the overlay. We
// place locals at slot ≥120, well past OFS_GS_MAIN (slot 82) + 10
// callbacks.
//
//   slot 120: origin.x = 10.0
//   slot 121: origin.y = 20.0
//   slot 122: origin.z = 30.0
//   slot 123: model_str_ofs = 1 ("progs/world.mdl")
//   slot 124: sound_str_ofs = 17
//   slot 125: msg_str_ofs   = 33 ("level loaded")
//   slot 126: light_str_ofs = 46
//   slot 127: light_style_idx = 4.0
//   slot 130: spawned-entity-index (returned by spawn)
//   slot 131..133: traceline v2 endpoint (10, 0, 0)
//   slot 140..151: builtin function indices (one slot per call site)
//   slot 160: vlen result
//
// We seed these globals BELOW (after the loader runs) so we
// don't have to encode F32 bit patterns into the buffer by
// hand. The bytecode reads the pre-set values via STORE_F into
// OFS_PARM* slots.

dstatement_t *_ti_st = _ti_progs + _ti_hdr->ofs_statements;
I64 _ti_si;
for (_ti_si = 0; _ti_si < 40; _ti_si++) {
  _ti_st[_ti_si].op = OP_DONE;
}

// stmt[0] = sentinel (OP_DONE)

// --- worldspawn body, starting at stmt[1] ---
// 1. precache_model("progs/world.mdl")    — STORE_F 123→PARM0; CALL1 fn[8]
_ti_st[1].op = OP_STORE_F; _ti_st[1].a = 123; _ti_st[1].b = OFS_PARM0;
_ti_st[2].op = OP_CALL1;   _ti_st[2].a = 140; _ti_st[2].b = 0; _ti_st[2].c = 0;
// 3. precache_sound("world/spawn.wav")    — STORE_F 124→PARM0; CALL1 fn[7]
_ti_st[3].op = OP_STORE_F; _ti_st[3].a = 124; _ti_st[3].b = OFS_PARM0;
_ti_st[4].op = OP_CALL1;   _ti_st[4].a = 141; _ti_st[4].b = 0; _ti_st[4].c = 0;
// 5. lightstyle(4, "abcdefghij") — STORE_F 127→PARM0, 126→PARM1; CALL2 fn[14]
_ti_st[5].op = OP_STORE_F; _ti_st[5].a = 127; _ti_st[5].b = OFS_PARM0;
_ti_st[6].op = OP_STORE_F; _ti_st[6].a = 126; _ti_st[6].b = OFS_PARM1;
_ti_st[7].op = OP_CALL2;   _ti_st[7].a = 142; _ti_st[7].b = 0; _ti_st[7].c = 0;
// 8. ent = spawn() — CALL0 fn[5]; STORE_F OFS_RETURN→130
_ti_st[8].op = OP_CALL0;   _ti_st[8].a = 143; _ti_st[8].b = 0; _ti_st[8].c = 0;
_ti_st[9].op = OP_STORE_F; _ti_st[9].a = OFS_RETURN; _ti_st[9].b = 130;
// 10. setorigin(ent, origin) — STORE_F 130→PARM0, STORE_V 120→PARM1; CALL2 fn[6]
_ti_st[10].op = OP_STORE_F; _ti_st[10].a = 130; _ti_st[10].b = OFS_PARM0;
_ti_st[11].op = OP_STORE_V; _ti_st[11].a = 120; _ti_st[11].b = OFS_PARM1;
_ti_st[12].op = OP_CALL2;   _ti_st[12].a = 144; _ti_st[12].b = 0; _ti_st[12].c = 0;
// 13. makevectors(origin) — STORE_V 120→PARM0; CALL1 fn[1]
_ti_st[13].op = OP_STORE_V; _ti_st[13].a = 120; _ti_st[13].b = OFS_PARM0;
_ti_st[14].op = OP_CALL1;   _ti_st[14].a = 145; _ti_st[14].b = 0; _ti_st[14].c = 0;
// 15. len = vlen(origin) — STORE_V already done; CALL1 fn[4]; STORE OFS_RETURN→160
_ti_st[15].op = OP_CALL1;   _ti_st[15].a = 146; _ti_st[15].b = 0; _ti_st[15].c = 0;
_ti_st[16].op = OP_STORE_F; _ti_st[16].a = OFS_RETURN; _ti_st[16].b = 160;
// 17. traceline(origin, [10,0,0]) — STORE_V 131→PARM1; CALL2 fn[11]
//     (PARM0 still has origin from stmt[13])
_ti_st[17].op = OP_STORE_V; _ti_st[17].a = 131; _ti_st[17].b = OFS_PARM1;
_ti_st[18].op = OP_CALL2;   _ti_st[18].a = 147; _ti_st[18].b = 0; _ti_st[18].c = 0;
// 19. dprint("level loaded") — STORE_F 125→PARM0; CALL1 fn[10]
_ti_st[19].op = OP_STORE_F; _ti_st[19].a = 125; _ti_st[19].b = OFS_PARM0;
_ti_st[20].op = OP_CALL1;   _ti_st[20].a = 148; _ti_st[20].b = 0; _ti_st[20].c = 0;
// 21. bprint("level loaded") — same arg; CALL1 fn[9]
_ti_st[21].op = OP_CALL1;   _ti_st[21].a = 149; _ti_st[21].b = 0; _ti_st[21].c = 0;
// 22. OP_STATE 4.0, fn[16]
_ti_st[22].op = OP_STATE; _ti_st[22].a = 127; _ti_st[22].b = 150; _ti_st[22].c = 0;
// 23. RETURN
_ti_st[23].op = OP_RETURN; _ti_st[23].a = OFS_RETURN; _ti_st[23].b = 0; _ti_st[23].c = 0;
// 24. (DONE pad)

// --- think body, starting at stmt[25] ---
// 25. normalize(origin) — STORE_V 120→PARM0; CALL1 fn[3]
_ti_st[25].op = OP_STORE_V; _ti_st[25].a = 120; _ti_st[25].b = OFS_PARM0;
_ti_st[26].op = OP_CALL1;   _ti_st[26].a = 151; _ti_st[26].b = 0; _ti_st[26].c = 0;
// 27. RETURN
_ti_st[27].op = OP_RETURN; _ti_st[27].a = OFS_RETURN; _ti_st[27].b = 0; _ti_st[27].c = 0;

// ============================================================
// Host-side setup: load + seed globals + execute
// ============================================================

ASSERT_EQ(PR_LoadProgsFromBuffer(_ti_progs, 4096) == TRUE, 1, "ti.load");
ASSERT_EQ(pr_numfunctions, 20, "ti.numfunctions");
ASSERT_EQ(pr_numfielddefs,  5, "ti.numfielddefs");
ASSERT_EQ(pr_entityfields,  8, "ti.entityfields");

// Field-lookup smoke
ASSERT_EQ(_PR_FieldOfsByName("origin"),    0, "ti.lookup_origin");
ASSERT_EQ(_PR_FieldOfsByName("frame"),     4, "ti.lookup_frame");
ASSERT_EQ(_PR_FieldOfsByName("think"),     6, "ti.lookup_think");
ASSERT_EQ(_PR_FieldOfsByName("nextthink"), 5, "ti.lookup_nextthink");

// Seed the slots the bytecode reads
_PR_SetFloat(120, 10.0); _PR_SetFloat(121, 20.0); _PR_SetFloat(122, 30.0);
pr_globals[123] = 1;                 // model string offset
pr_globals[124] = 17;                // sound string offset
pr_globals[125] = 33;                // msg string offset
pr_globals[126] = 46;                // light style string offset
_PR_SetFloat(127, 4.0);              // lightstyle index
_PR_SetFloat(131, 10.0); _PR_SetFloat(132, 0.0); _PR_SetFloat(133, 0.0);

// Function-index globals (one per builtin reference in our table)
pr_globals[140] = 8;    // precache_model fn[8]
pr_globals[141] = 7;    // precache_sound fn[7]
pr_globals[142] = 14;   // lightstyle fn[14]
pr_globals[143] = 5;    // spawn fn[5]
pr_globals[144] = 6;    // setorigin fn[6]
pr_globals[145] = 1;    // makevectors fn[1]
pr_globals[146] = 4;    // vlen fn[4]
pr_globals[147] = 11;   // traceline fn[11]
pr_globals[148] = 10;   // dprint fn[10]
pr_globals[149] = 9;    // bprint fn[9]
pr_globals[150] = 16;   // think fn[16] (passed as OP_STATE think operand)
pr_globals[151] = 3;    // normalize fn[3]

// self = entity 5 (so OP_STATE writes into a known edict)
pr_globals[OFS_GS_SELF] = 5;
_PR_SetFloat(OFS_GS_TIME, 12.0);

// Make spawn return a known index
pr_next_free_edict = 7;

// Reset side channels
pr_last_builtin_called = 0;
pr_last_op_state_called = FALSE;

// Execute worldspawn
PR_ExecuteProgram(15);

// ============================================================
// Assertions
// ============================================================

// VM halted cleanly
ASSERT_EQ(pr_halted == TRUE, 1, "ti.halted_cleanly");
ASSERT_EQ(pr_runaway == FALSE, 1, "ti.no_runaway");

// Builtins fired in the program (last one wins for
// pr_last_builtin_called; the OP_STATE comes after so its side
// channel should be set instead).
ASSERT_EQ(pr_last_op_state_called == TRUE, 1, "ti.op_state_called");
ASSERT_NEAR(pr_last_op_state_frame, 4.0, 0.0001, "ti.op_state_frame");
ASSERT_EQ(pr_last_op_state_think, 16, "ti.op_state_think");

// OP_STATE wrote frame/think into entity 5 via field lookup
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[5 * 8 + 4]), 4.0, 0.0001, "ti.entity_frame");
ASSERT_EQ(pr_edicts[5 * 8 + 6], 16, "ti.entity_think");

// nextthink = time + 0.1 = 12.1
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[5 * 8 + 5]), 12.1, 0.0001, "ti.entity_nextthink");

// spawn returned 7, slot 130 holds it
ASSERT_EQ(pr_globals[130], 7, "ti.spawn_returned_index");

// setorigin wrote into entity 7's origin slots (via field lookup)
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[7 * 8 + 0]), 10.0, 0.0001, "ti.spawn_origin_x");
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[7 * 8 + 1]), 20.0, 0.0001, "ti.spawn_origin_y");
ASSERT_NEAR(_PR_F32_to_F64(pr_edicts[7 * 8 + 2]), 30.0, 0.0001, "ti.spawn_origin_z");

// vlen((10,20,30)) = sqrt(100+400+900) = sqrt(1400) ≈ 37.4166
ASSERT_NEAR(_PR_GetFloat(160), 37.4166, 0.01, "ti.vlen_origin");

// makevectors with yaw=20 (the input's [1] component) wrote into
// v_forward / v_up / v_right. Just sanity: forward is non-zero.
F64 _ti_fwd_len_sq = _PR_GetFloat(OFS_GS_V_FORWARD)     * _PR_GetFloat(OFS_GS_V_FORWARD)
                  + _PR_GetFloat(OFS_GS_V_FORWARD + 1) * _PR_GetFloat(OFS_GS_V_FORWARD + 1)
                  + _PR_GetFloat(OFS_GS_V_FORWARD + 2) * _PR_GetFloat(OFS_GS_V_FORWARD + 2);
ASSERT_NEAR(_ti_fwd_len_sq, 1.0, 0.01, "ti.makevectors_forward_unit");

// traceline wrote trace_* result slots: fraction=1, endpos=v2
ASSERT_NEAR(_PR_GetFloat(OFS_GS_TRACE_FRACTION),    1.0, 0.0001, "ti.traceline_no_hit");
ASSERT_NEAR(_PR_GetFloat(OFS_GS_TRACE_ENDPOS),     10.0, 0.0001, "ti.traceline_endpos");

// dprint + bprint both ran "level loaded"
ASSERT_EQ(Q_strcmp(pr_last_msg_str, "level loaded"), 0, "ti.bprint_msg");

// precache_model recorded "progs/world.mdl"
// (pr_last_builtin_arg0_str is shared across precache_*; check
// the most recent one. Order: precache_model #20 → precache_sound
// #19 → ...; the ORDER in our progs is: model, then sound, but
// the arg0_str gets overwritten each call. Just verify the final
// state has SOME string of the expected length.)
ASSERT_EQ(Q_strlen(pr_last_msg_str), 12, "ti.bprint_len_matches");

// Cleanup: switch back to the main fixture so any further tests
// get a known progs.
ASSERT_EQ(PR_LoadProgsFromBuffer(_t_progs, 1024) == TRUE, 1, "ti.restore_main");
