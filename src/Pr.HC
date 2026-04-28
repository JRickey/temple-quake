// Pr.HC — port of WinQuake/pr_exec.c (MVP) and pieces of pr_edict.c.
//
// QuakeC bytecode VM. Loads `progs.dat`, validates the header, and
// runs a register-based bytecode over an array of 4-byte global slots
// plus a stack of call frames.
//
// MVP SCOPE (this commit):
//   - On-disk structs: dprograms_t, dstatement_t, ddef_t, dfunction_t
//   - Constants: OP_*, OFS_*, ev_*, PROG_VERSION = 6
//   - F32 ↔ F64 bit-conversion helpers (HolyC has no F32, but the
//     bytecode treats every global slot as 4 bytes — we keep that,
//     widen/narrow only at math points)
//   - PR_LoadProgsFromBuffer(buf, len): header check + endian fix-up
//     + table pointer setup
//   - PR_ExecuteProgram(fnum): main dispatch over a subset of
//     opcodes — enough to run integer/float arithmetic, comparisons,
//     control flow, and return-from-function
//
// DEFERRED:
//   - OP_STATE — needs server context (pr_global_struct->self/time)
//   - PR_LoadStrings / PR_AllocString runtime string pool growth
//   - SaveGame, profiling

// ============================================================
// Constants
// ============================================================

#define PROG_VERSION  6
#define PROGHEADER_CRC 5927

#define MAX_PARMS    8

// Global-array reserved offsets — see pr_comp.h:29-38.
#define OFS_NULL      0
#define OFS_RETURN    1
#define OFS_PARM0     4
#define OFS_PARM1     7
#define OFS_PARM2     10
#define OFS_PARM3     13
#define OFS_PARM4     16
#define OFS_PARM5     19
#define OFS_PARM6     22
#define OFS_PARM7     25
#define RESERVED_OFS  28

// globalvars_t overlay — pr_globals[28..] match the layout of
// pr_global_struct in Quake (see quake-src/WinQuake/progdefs.q1
// lines 1-58). The first 28 slots are the OFS_NULL/RETURN/PARM*
// reserved area; from slot 28 forward, the bytecode reads/writes
// these named server globals through normal LOAD_*/STORE_* ops.
// We expose the same offsets as constants so HolyC-side helpers
// (and OP_STATE) can address them by name.
#define OFS_GS_SELF             28        // entity
#define OFS_GS_OTHER            29        // entity
#define OFS_GS_WORLD            30        // entity
#define OFS_GS_TIME             31        // float
#define OFS_GS_FRAMETIME        32        // float
#define OFS_GS_FORCE_RETOUCH    33        // float
#define OFS_GS_MAPNAME          34        // string
#define OFS_GS_DEATHMATCH       35        // float
#define OFS_GS_COOP             36
#define OFS_GS_TEAMPLAY         37
#define OFS_GS_SERVERFLAGS      38
#define OFS_GS_TOTAL_SECRETS    39
#define OFS_GS_TOTAL_MONSTERS   40
#define OFS_GS_FOUND_SECRETS    41
#define OFS_GS_KILLED_MONSTERS  42
// Slots 43..58: parm1..parm16 (16 floats — client info passed to
// SetNewParms / SetChangeParms).
#define OFS_GS_PARM1            43
// Slots 59..67: v_forward, v_up, v_right (3 vec3 from makevectors).
#define OFS_GS_V_FORWARD        59
#define OFS_GS_V_UP             62
#define OFS_GS_V_RIGHT          65
// Slots 68..80: trace_* result block (set by traceline / etc.).
#define OFS_GS_TRACE_ALLSOLID   68
#define OFS_GS_TRACE_STARTSOLID 69
#define OFS_GS_TRACE_FRACTION   70
#define OFS_GS_TRACE_ENDPOS     71        // vec3
#define OFS_GS_TRACE_PLANE_NORMAL 74      // vec3
#define OFS_GS_TRACE_PLANE_DIST 77        // float
#define OFS_GS_TRACE_ENT        78        // entity
#define OFS_GS_TRACE_INOPEN     79
#define OFS_GS_TRACE_INWATER    80
#define OFS_GS_MSG_ENTITY       81        // entity
// Slots 82..91: server callbacks (main, StartFrame, PlayerPreThink,
// PlayerPostThink, ClientKill, ClientConnect, PutClientInServer,
// ClientDisconnect, SetNewParms, SetChangeParms — all func_t).
#define OFS_GS_MAIN             82

// Type IDs from etype_t (pr_comp.h:26).
#define EV_VOID      0
#define EV_STRING    1
#define EV_FLOAT     2
#define EV_VECTOR    3
#define EV_ENTITY    4
#define EV_FIELD     5
#define EV_FUNCTION  6
#define EV_POINTER   7

// Bytecode opcodes (pr_comp.h:42-118). Numbered explicitly to match
// the on-disk layout exactly.
#define OP_DONE        0
#define OP_MUL_F       1
#define OP_MUL_V       2
#define OP_MUL_FV      3
#define OP_MUL_VF      4
#define OP_DIV_F       5
#define OP_ADD_F       6
#define OP_ADD_V       7
#define OP_SUB_F       8
#define OP_SUB_V       9
#define OP_EQ_F        10
#define OP_EQ_V        11
#define OP_EQ_S        12
#define OP_EQ_E        13
#define OP_EQ_FNC      14
#define OP_NE_F        15
#define OP_NE_V        16
#define OP_NE_S        17
#define OP_NE_E        18
#define OP_NE_FNC      19
#define OP_LE          20
#define OP_GE          21
#define OP_LT          22
#define OP_GT          23
#define OP_LOAD_F      24
#define OP_LOAD_V      25
#define OP_LOAD_S      26
#define OP_LOAD_ENT    27
#define OP_LOAD_FLD    28
#define OP_LOAD_FNC    29
#define OP_ADDRESS     30
#define OP_STORE_F     31
#define OP_STORE_V     32
#define OP_STORE_S     33
#define OP_STORE_ENT   34
#define OP_STORE_FLD   35
#define OP_STORE_FNC   36
#define OP_STOREP_F    37
#define OP_STOREP_V    38
#define OP_STOREP_S    39
#define OP_STOREP_ENT  40
#define OP_STOREP_FLD  41
#define OP_STOREP_FNC  42
#define OP_RETURN      43
#define OP_NOT_F       44
#define OP_NOT_V       45
#define OP_NOT_S       46
#define OP_NOT_ENT     47
#define OP_NOT_FNC     48
#define OP_IF          49
#define OP_IFNOT       50
#define OP_CALL0       51
#define OP_CALL1       52
#define OP_CALL2       53
#define OP_CALL3       54
#define OP_CALL4       55
#define OP_CALL5       56
#define OP_CALL6       57
#define OP_CALL7       58
#define OP_CALL8       59
#define OP_STATE       60
#define OP_GOTO        61
#define OP_AND         62
#define OP_OR          63
#define OP_BITAND      64
#define OP_BITOR       65

#define MAX_STACK_DEPTH  32
#define LOCALSTACK_SIZE  2048

// Edict pool. Vanilla Quake bumped MAX_EDICTS to 600 across releases;
// for the VM unit tests a much smaller pool is enough. Each edict
// occupies `pr_entityfields` 4-byte slots in `pr_edicts`. Total slots
// = MAX_EDICTS * MAX_ENTITY_FIELDS.
//
// MAX_ENTITY_FIELDS is sized for real progs.dat compatibility:
// QuakeWorld's qwprogs.dat declares entityfields=194; vanilla Quake
// progs.dat ~105. 256 leaves headroom and keeps the pool at
// 64 * 256 * 4 = 64 KB.
#define MAX_EDICTS         64
#define MAX_ENTITY_FIELDS  256

// ============================================================
// On-disk structures (pr_comp.h)
// ============================================================

class dstatement_t {
  U16 op;
  I16 a;
  I16 b;
  I16 c;
};

class ddef_t {
  U16 type;            // high bit (1<<15) = DEF_SAVEGLOBAL
  U16 ofs;
  I32 s_name;          // offset into string pool
};

class dfunction_t {
  I32 first_statement; // negative → builtin
  I32 parm_start;
  I32 locals;
  I32 profile;
  I32 s_name;
  I32 s_file;
  I32 numparms;
  U8  parm_size[MAX_PARMS];
};

class dprograms_t {
  I32 version;
  I32 crc;
  I32 ofs_statements;
  I32 numstatements;
  I32 ofs_globaldefs;
  I32 numglobaldefs;
  I32 ofs_fielddefs;
  I32 numfielddefs;
  I32 ofs_functions;
  I32 numfunctions;
  I32 ofs_strings;
  I32 numstrings;
  I32 ofs_globals;
  I32 numglobals;
  I32 entityfields;
};

// ============================================================
// Runtime VM state
// ============================================================

U8           *pr_progs_buf = NULL;     // raw progs.dat in memory
I64           pr_progs_buf_size = 0;
dprograms_t  *pr_progs = NULL;         // header (overlaid on buf)

dstatement_t *pr_statements = NULL;
dfunction_t  *pr_functions = NULL;
ddef_t       *pr_globaldefs = NULL;
ddef_t       *pr_fielddefs = NULL;
U8           *pr_strings = NULL;       // string pool

// Globals are 4-byte slots. We keep them as I32; floats are
// stored as the F32 bit pattern. Use _PR_GetFloat / _PR_SetFloat
// for math.
I32          *pr_globals = NULL;

I64           pr_numstatements = 0;
I64           pr_numfunctions = 0;
I64           pr_numglobals = 0;
I64           pr_numglobaldefs = 0;
I64           pr_numfielddefs = 0;
I64           pr_numstrings = 0;
I64           pr_entityfields = 0;

// VM execution state
I64           pr_xstatement = 0;       // current statement index
I64           pr_xfunction = 0;        // current function index
Bool          pr_trace = FALSE;        // diag — log every statement

class _PR_StackEntry {
  I64 s;                              // return statement
  I64 f;                              // returning function
};
_PR_StackEntry _pr_stack[MAX_STACK_DEPTH];
I64           _pr_depth = 0;

I32           _pr_localstack[LOCALSTACK_SIZE];
I64           _pr_localstack_used = 0;

// Flat edict storage: [edict 0 fields...][edict 1 fields...][...]
// Sized at MAX_EDICTS * MAX_ENTITY_FIELDS slots so we don't need a
// runtime allocator. PR_LoadProgsFromBuffer caps pr_entityfields to
// MAX_ENTITY_FIELDS.
I32           pr_edicts[MAX_EDICTS * MAX_ENTITY_FIELDS];
I64           pr_max_edicts = MAX_EDICTS;

Bool          pr_halted = FALSE;       // set TRUE on OP_DONE
Bool          pr_runaway = FALSE;      // set TRUE on > 100k step limit

I64           pr_argc = 0;             // arg count for the current builtin call

// Tracks builtin invocations for tests. Each builtin sets
// `pr_last_builtin_called` and `pr_last_builtin_arg0_str` (for
// string-arg builtins) so test assertions can verify dispatch
// without relying on console capture.
I64 pr_last_builtin_called = 0;
U8  pr_last_builtin_arg0_str[256];

// OP_STATE instrumentation: records the last (frame, think) operands
// observed so tests can verify dispatch without a real server.
Bool pr_last_op_state_called = FALSE;
F64  pr_last_op_state_frame  = 0.0;
I64  pr_last_op_state_think  = 0;

// Spawn / Remove instrumentation. Real Quake links / unlinks edicts
// from the server's free-edict list. We model just enough to give
// each spawn a unique entity index past entity 0 (world).
I64 pr_next_free_edict = 1;                       // grows with each spawn
I64 pr_last_spawned    = 0;
I64 pr_last_removed    = 0;

// Network-message Write* instrumentation. Real Quake routes Write*
// builtins into one of several msg buffers (sv.datagram,
// sv.reliable_datagram, sv.signon, sv.multicast). We don't have a
// network stack; record the last call's destination + value so
// tests can verify dispatch shape. The "value" channel is
// over-typed: integer-ish builtins (Byte/Char/Short/Long/Entity)
// stash into pr_last_write_val_i; float-ish (Coord/Angle) use
// pr_last_write_val_f; WriteString fills pr_last_write_val_str.
I64 pr_last_write_dest    = 0;
I64 pr_last_write_val_i   = 0;
F64 pr_last_write_val_f   = 0.0;
U8  pr_last_write_val_str[256];

// ============================================================
// IEEE-754 F32 ↔ F64 conversion helpers
// ============================================================
//
// QC bytecode treats globals as 4-byte slots. Floats are stored as
// IEEE-754 binary32. HolyC has no F32 type, so we widen on read and
// narrow on write. Subnormals are flushed to zero for MVP — vanilla
// Quake bytecode rarely produces them and we'll add proper handling
// only if a test exercises it.

F64 _PR_F32_to_F64(I32 bits) {
  I64 sign   = (bits >> 31) & 0x1;
  I64 exp32  = (bits >> 23) & 0xFF;
  I64 mant32 = bits & 0x7FFFFF;
  I64 sign64 = sign << 63;
  I64 exp64;
  I64 mant64;
  if (exp32 == 0) {
    // zero or subnormal — flush to signed zero
    exp64 = 0;
    mant64 = 0;
  } else if (exp32 == 0xFF) {
    // inf or NaN
    exp64 = 0x7FF;
    mant64 = mant32 << 29;
  } else {
    exp64 = exp32 - 127 + 1023;
    mant64 = mant32 << 29;
  }
  I64 result = sign64 | (exp64 << 52) | mant64;
  F64 out;
  *(&out(I64 *)) = result;
  return out;
}

I32 _PR_F64_to_F32(F64 v) {
  I64 bits;
  bits = *(&v(I64 *));
  I64 sign   = (bits >> 63) & 0x1;
  I64 exp64  = (bits >> 52) & 0x7FF;
  I64 mant64 = bits & 0xFFFFFFFFFFFFF;
  I32 sign32 = sign << 31;
  I32 exp32;
  I32 mant32;
  if (exp64 == 0) {
    exp32 = 0;
    mant32 = 0;
  } else if (exp64 == 0x7FF) {
    exp32 = 0xFF;
    mant32 = mant64 >> 29;
    if (mant32 == 0 && mant64 != 0) {
      mant32 = 1;          // preserve NaN-ness
    }
  } else {
    I64 e = exp64 - 1023 + 127;
    if (e <= 0) {
      exp32 = 0;
      mant32 = 0;
    } else if (e >= 0xFF) {
      exp32 = 0xFF;
      mant32 = 0;
    } else {
      exp32 = e;
      mant32 = mant64 >> 29;
    }
  }
  return sign32 | (exp32 << 23) | mant32;
}

F64 _PR_GetFloat(I64 ofs) {
  return _PR_F32_to_F64(pr_globals[ofs]);
}

U0 _PR_SetFloat(I64 ofs, F64 v) {
  pr_globals[ofs] = _PR_F64_to_F32(v);
}

// ============================================================
// Edict / field addressing
// ============================================================
//
// An edict is a contiguous run of `pr_entityfields` 4-byte slots in
// `pr_edicts`. A "field offset" stored in a ddef_t is in 4-byte
// slot units (matches `(int *)&ed->v + ofs` arithmetic in stock
// Quake). A "field pointer" — the value produced by OP_ADDRESS and
// consumed by OP_STOREP_* — is a BYTE offset into pr_edicts (matches
// Quake's `(byte *)sv.edicts + b->_int`). Slot index = byte_ofs >> 2.

I64 _PR_EdictFieldSlot(I64 ent, I64 field_ofs) {
  return ent * pr_entityfields + field_ofs;
}

I64 _PR_FieldPointerFromEntity(I64 ent, I64 field_ofs) {
  // Encoded as a byte offset so OP_STOREP can decode with `>> 2`.
  return _PR_EdictFieldSlot(ent, field_ofs) << 2;
}

I64 _PR_FieldSlotFromPointer(I64 ptr) {
  return ptr >> 2;
}

// atan2(y, x) — TempleOS's Math library only ships single-arg ATan,
// so we compute the four-quadrant version ourselves. Returns radians
// in (-π, π]. Used by vectoyaw / vectoangles to convert direction
// vectors into Quake-format pitch/yaw.
F64 _PR_atan2(F64 y, F64 x) {
  if (x > 0.0) {
    return ATan(y / x);
  }
  if (x < 0.0) {
    if (y >= 0.0) {
      return ATan(y / x) + pi;
    }
    return ATan(y / x) - pi;
  }
  // x == 0
  if (y > 0.0) {
    return pi / 2.0;
  }
  if (y < 0.0) {
    return -pi / 2.0;
  }
  return 0.0;
}

// ============================================================
// PR_LoadProgsFromBuffer — header validation + endian fix-up.
// ============================================================
//
// Returns TRUE on success, FALSE if the header is malformed. Real
// Quake's PR_LoadProgs reads the file from disk via COM_LoadHunkFile;
// we accept a buffer the caller obtained however they like.

Bool PR_LoadProgsFromBuffer(U8 *buf, I64 buflen) {
  if (!buf || buflen < sizeof(dprograms_t)) {
    Print("PR_LoadProgs: buffer too small\n");
    return FALSE;
  }
  pr_progs_buf = buf;
  pr_progs_buf_size = buflen;
  pr_progs = buf;

  // Header byte-swap (no-op on x86_64; preserved for portability).
  I32 *raw = pr_progs;
  I64 i;
  for (i = 0; i < sizeof(dprograms_t) / 4; i++) {
    raw[i] = LittleLong(raw[i]);
  }

  if (pr_progs->version != PROG_VERSION) {
    Print("PR_LoadProgs: unexpected version (got %d, want %d)\n",
          pr_progs->version, PROG_VERSION);
    return FALSE;
  }

  // Bounds-check every table offset.
  if (pr_progs->ofs_statements < 0 ||
      pr_progs->ofs_statements + pr_progs->numstatements * sizeof(dstatement_t) > buflen) {
    Print("PR_LoadProgs: statements table out of bounds\n");
    return FALSE;
  }
  if (pr_progs->ofs_functions < 0 ||
      pr_progs->ofs_functions + pr_progs->numfunctions * sizeof(dfunction_t) > buflen) {
    Print("PR_LoadProgs: functions table out of bounds\n");
    return FALSE;
  }
  if (pr_progs->ofs_globals < 0 ||
      pr_progs->ofs_globals + pr_progs->numglobals * 4 > buflen) {
    Print("PR_LoadProgs: globals table out of bounds\n");
    return FALSE;
  }
  if (pr_progs->ofs_strings < 0 ||
      pr_progs->ofs_strings + pr_progs->numstrings > buflen) {
    Print("PR_LoadProgs: strings table out of bounds\n");
    return FALSE;
  }

  // Set table pointers (overlay onto the raw buffer).
  pr_statements = buf + pr_progs->ofs_statements;
  pr_functions  = buf + pr_progs->ofs_functions;
  pr_globaldefs = buf + pr_progs->ofs_globaldefs;
  pr_fielddefs  = buf + pr_progs->ofs_fielddefs;
  pr_strings    = buf + pr_progs->ofs_strings;
  pr_globals    = buf + pr_progs->ofs_globals;

  pr_numstatements  = pr_progs->numstatements;
  pr_numfunctions   = pr_progs->numfunctions;
  pr_numglobals     = pr_progs->numglobals;
  pr_numglobaldefs  = pr_progs->numglobaldefs;
  pr_numfielddefs   = pr_progs->numfielddefs;
  pr_numstrings     = pr_progs->numstrings;
  pr_entityfields   = pr_progs->entityfields;
  if (pr_entityfields > MAX_ENTITY_FIELDS) {
    Print("PR_LoadProgs: entityfields %d exceeds MAX_ENTITY_FIELDS %d\n",
          pr_entityfields, MAX_ENTITY_FIELDS);
    return FALSE;
  }
  // Reset the edict pool on (re)load so leftover values from a prior
  // progs don't leak into the new one.
  I64 _ei;
  for (_ei = 0; _ei < MAX_EDICTS * MAX_ENTITY_FIELDS; _ei++) {
    pr_edicts[_ei] = 0;
  }

  // Byte-swap pass on tables (statements / globaldefs / fielddefs /
  // functions / globals) is a no-op on x86_64 since LittleLong is
  // identity. The pass is preserved-by-omission here; if porting to
  // a big-endian host, walk each table and apply LittleShort /
  // LittleLong per field.

  return TRUE;
}

// ============================================================
// PR_LoadProgsFromFile — read a `.dat` off disk and load it.
// ============================================================
//
// TempleOS's FileRead returns a heap-allocated buffer; we hand it
// straight to PR_LoadProgsFromBuffer (which retains the pointer
// for the lifetime of the loaded progs — every table is overlaid
// on the buffer, not copied). Caller owns the buffer; do NOT
// free it while the VM is live.

Bool PR_LoadProgsFromFile(U8 *path) {
  I64 size = 0;
  U8 *buf = FileRead(path, &size);
  if (!buf) {
    Print("PR_LoadProgsFromFile: cannot read '%s'\n", path);
    return FALSE;
  }
  return PR_LoadProgsFromBuffer(buf, size);
}

// ============================================================
// Helpers for the executor
// ============================================================

U8 *_PR_GetString(I64 num) {
  if (num < 0 || num >= pr_numstrings) {
    return cvar_null_string;            // defined in Cvar.HC
  }
  return pr_strings + num;
}

U8 *PR_FunctionName(I64 fnum) {
  if (fnum < 0 || fnum >= pr_numfunctions) {
    return "<bad-function>";
  }
  return _PR_GetString(pr_functions[fnum].s_name);
}

// Walk pr_fielddefs looking for a name match. Returns the field
// offset (in 4-byte slot units within an entity's field block) or
// -1 if not found. Linear scan — Quake's progs typically have
// ~200 fielddefs so this is fine; cache call sites if it ever
// matters. Used by OP_STATE to resolve symbolic names like
// "frame" / "nextthink" / "think" to their layout offsets without
// hardcoding the entvars_t struct.
I64 _PR_FieldOfsByName(U8 *name) {
  I64 i;
  for (i = 0; i < pr_numfielddefs; i++) {
    U8 *fname = _PR_GetString(pr_fielddefs[i].s_name);
    if (Q_strcmp(fname, name) == 0) {
      return pr_fielddefs[i].ofs;
    }
  }
  return -1;
}

U0 _PR_StackTrace() {
  Print("--- pr stack ---\n");
  I64 i;
  for (i = _pr_depth - 1; i >= 0; i--) {
    Print("  [%d] in %s @ stmt %d\n",
          i, PR_FunctionName(_pr_stack[i].f), _pr_stack[i].s);
  }
}

// Push a return frame, allocate locals on _pr_localstack.
I64 _PR_EnterFunction(I64 fnum) {
  if (_pr_depth >= MAX_STACK_DEPTH) {
    Print("PR_ExecuteProgram: stack overflow\n");
    pr_halted = TRUE;
    return -1;
  }
  _pr_stack[_pr_depth].s = pr_xstatement;
  _pr_stack[_pr_depth].f = pr_xfunction;
  _pr_depth++;

  dfunction_t *f = &pr_functions[fnum];
  if (_pr_localstack_used + f->locals > LOCALSTACK_SIZE) {
    Print("PR_ExecuteProgram: locals stack overflow\n");
    pr_halted = TRUE;
    return -1;
  }
  // Save current values of [parm_start..parm_start+locals) globals
  // into the local stack so recursion is safe.
  I64 i;
  for (i = 0; i < f->locals; i++) {
    _pr_localstack[_pr_localstack_used + i] = pr_globals[f->parm_start + i];
  }
  _pr_localstack_used = _pr_localstack_used + f->locals;

  // Copy parm values from OFS_PARMn into the function's locals.
  I64 j;
  I64 src = OFS_PARM0;
  I64 dst = f->parm_start;
  for (i = 0; i < f->numparms; i++) {
    for (j = 0; j < f->parm_size[i]; j++) {
      pr_globals[dst] = pr_globals[src];
      dst++;
      src++;
    }
  }

  pr_xfunction = fnum;
  return f->first_statement - 1;        // -1 because dispatch will ++ first
}

I64 _PR_LeaveFunction() {
  if (_pr_depth <= 0) {
    Print("PR_ExecuteProgram: stack underflow\n");
    pr_halted = TRUE;
    return -1;
  }
  // Restore caller's locals from _pr_localstack.
  dfunction_t *f = &pr_functions[pr_xfunction];
  _pr_localstack_used = _pr_localstack_used - f->locals;
  if (_pr_localstack_used < 0) {
    _pr_localstack_used = 0;
  }
  I64 i;
  for (i = 0; i < f->locals; i++) {
    pr_globals[f->parm_start + i] = _pr_localstack[_pr_localstack_used + i];
  }
  _pr_depth--;
  pr_xfunction = _pr_stack[_pr_depth].f;
  return _pr_stack[_pr_depth].s;
}

// ============================================================
// Builtins (Tier 1)
// ============================================================
//
// Builtins are dispatched through a switch keyed on the builtin
// index. Real Quake uses a function-pointer table; HolyC's array-
// of-fn-pointers shape is fragile, and a switch ports cleaner.
//
// Builtin indices now match Quake's canonical `pr_cmds.c` table
// (e.g. random=#7, error=#10, vlen=#12, dprint=#25, ftos=#26),
// so a real progs.dat compiled by qcc/fteqcc can be loaded and
// dispatched. Stateless math/utility builtins are implemented;
// server-side ones (setorigin, setmodel, spawn, sound, traceline,
// etc.) are recordable stubs that preserve the dispatch path
// without simulating the world.
//
// Param convention (Quake's): each parameter occupies 3 global
// slots (room for vec3); param N is at OFS_PARM0 + N*3. String
// parameters store an i32 offset into pr_strings in the FIRST
// slot of their param trio.

// #6 — break() — debugger breakpoint; no-op stub.
U0 _PR_PF_break() {
  pr_last_builtin_called = 6;
}

// #7 — random() → float in [0, 1)
U0 _PR_PF_random() {
  _PR_SetFloat(OFS_RETURN, Rand);
  pr_last_builtin_called = 7;
}

// #9 — normalize(vec3) → vec3 in OFS_RETURN
U0 _PR_PF_normalize() {
  F64 x = _PR_GetFloat(OFS_PARM0);
  F64 y = _PR_GetFloat(OFS_PARM0 + 1);
  F64 z = _PR_GetFloat(OFS_PARM0 + 2);
  F64 len_sq = x * x + y * y + z * z;
  F64 len = Sqrt(len_sq);
  if (len > 0.0) {
    _PR_SetFloat(OFS_RETURN,     x / len);
    _PR_SetFloat(OFS_RETURN + 1, y / len);
    _PR_SetFloat(OFS_RETURN + 2, z / len);
  } else {
    _PR_SetFloat(OFS_RETURN,     0.0);
    _PR_SetFloat(OFS_RETURN + 1, 0.0);
    _PR_SetFloat(OFS_RETURN + 2, 0.0);
  }
  pr_last_builtin_called = 9;
}

// #10 — error(string s) — Sys_Error equivalent; halts the VM.
U0 _PR_PF_error() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *s = _PR_GetString(strofs);
  U8 errbuf[320];
  StrPrint(errbuf, "PR_PF_error: %s\n", s);
  Con_Printf(errbuf);
  pr_last_builtin_called = 10;
  I64 i = 0;
  while (i < 255 && s[i]) {
    pr_last_builtin_arg0_str[i] = s[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
  pr_halted = TRUE;
}

// #11 — objerror(string s) — like error but normally would clear
// the offending entity. We treat it the same as error for now.
U0 _PR_PF_objerror() {
  _PR_PF_error();
  pr_last_builtin_called = 11;
}

// #12 — vlen(vec3) → float in OFS_RETURN
U0 _PR_PF_vlen() {
  F64 x = _PR_GetFloat(OFS_PARM0);
  F64 y = _PR_GetFloat(OFS_PARM0 + 1);
  F64 z = _PR_GetFloat(OFS_PARM0 + 2);
  _PR_SetFloat(OFS_RETURN, Sqrt(x * x + y * y + z * z));
  pr_last_builtin_called = 12;
}

// #13 — vectoyaw(vec3) → float (yaw in degrees)
U0 _PR_PF_vectoyaw() {
  F64 x = _PR_GetFloat(OFS_PARM0);
  F64 y = _PR_GetFloat(OFS_PARM0 + 1);
  F64 yaw;
  if (x == 0.0 && y == 0.0) {
    yaw = 0.0;
  } else {
    yaw = _PR_atan2(y, x) * 180.0 / pi;
    if (yaw < 0.0) {
      yaw = yaw + 360.0;
    }
  }
  _PR_SetFloat(OFS_RETURN, yaw);
  pr_last_builtin_called = 13;
}

// #19 — precache_sound(string s) — no-op stub; record string.
U0 _PR_PF_precache_sound() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *s = _PR_GetString(strofs);
  pr_globals[OFS_RETURN] = strofs;        // returns the same string
  pr_last_builtin_called = 19;
  I64 i = 0;
  while (i < 255 && s[i]) {
    pr_last_builtin_arg0_str[i] = s[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
}

// #20 — precache_model(string s) — no-op stub; record string.
U0 _PR_PF_precache_model() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *s = _PR_GetString(strofs);
  pr_globals[OFS_RETURN] = strofs;
  pr_last_builtin_called = 20;
  I64 i = 0;
  while (i < 255 && s[i]) {
    pr_last_builtin_arg0_str[i] = s[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
}

// #25 — dprint(string s) — debug print; same path as console out.
U0 _PR_PF_dprint() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *s = _PR_GetString(strofs);
  Con_Printf(s);
  pr_last_builtin_called = 25;
  I64 i = 0;
  while (i < 255 && s[i]) {
    pr_last_builtin_arg0_str[i] = s[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
}

// #26 — ftos(float f) → string
U0 _PR_PF_ftos() {
  F64 f = _PR_GetFloat(OFS_PARM0);
  static U8 ftos_buf[64];
  StrPrint(ftos_buf, "%5.1f", f);
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 26;
  I64 i = 0;
  while (i < 255 && ftos_buf[i]) {
    pr_last_builtin_arg0_str[i] = ftos_buf[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
}

// #36 — rint(float f) → float (round to nearest int).
// HolyC's `expr(I64)` postfix is BIT REINTERPRETATION, not a
// numeric conversion — `(2.7)(I64)` returns the F64 bit pattern
// as I64, not the integer 2. So we lean on TempleOS's `Floor`
// and `Ceil` builtins to do real rounding.
U0 _PR_PF_rint() {
  F64 f = _PR_GetFloat(OFS_PARM0);
  F64 r;
  if (f >= 0.0) {
    r = Floor(f + 0.5);
  } else {
    r = Ceil(f - 0.5);
  }
  _PR_SetFloat(OFS_RETURN, r);
  pr_last_builtin_called = 36;
}

// #37 — floor(float f) → float
U0 _PR_PF_floor() {
  _PR_SetFloat(OFS_RETURN, Floor(_PR_GetFloat(OFS_PARM0)));
  pr_last_builtin_called = 37;
}

// #38 — ceil(float f) → float
U0 _PR_PF_ceil() {
  _PR_SetFloat(OFS_RETURN, Ceil(_PR_GetFloat(OFS_PARM0)));
  pr_last_builtin_called = 38;
}

// #43 — fabs(float f) → float
U0 _PR_PF_fabs() {
  F64 f = _PR_GetFloat(OFS_PARM0);
  if (f < 0.0) {
    f = -f;
  }
  _PR_SetFloat(OFS_RETURN, f);
  pr_last_builtin_called = 43;
}

// #51 — vectoangles(vec3) → vec3 (pitch, yaw, 0)
U0 _PR_PF_vectoangles() {
  F64 x = _PR_GetFloat(OFS_PARM0);
  F64 y = _PR_GetFloat(OFS_PARM0 + 1);
  F64 z = _PR_GetFloat(OFS_PARM0 + 2);
  F64 yaw;
  F64 pitch;
  if (x == 0.0 && y == 0.0) {
    yaw = 0.0;
    if (z > 0.0) {
      pitch = 90.0;
    } else {
      pitch = 270.0;
    }
  } else {
    yaw = _PR_atan2(y, x) * 180.0 / pi;
    if (yaw < 0.0) {
      yaw = yaw + 360.0;
    }
    F64 forward = Sqrt(x * x + y * y);
    pitch = _PR_atan2(z, forward) * 180.0 / pi;
    if (pitch < 0.0) {
      pitch = pitch + 360.0;
    }
  }
  _PR_SetFloat(OFS_RETURN,     pitch);
  _PR_SetFloat(OFS_RETURN + 1, yaw);
  _PR_SetFloat(OFS_RETURN + 2, 0.0);
  pr_last_builtin_called = 51;
}

// ============================================================
// Phase 6 Batch 1 — trivial debug/no-op + simple math.
//
// The qwprogs.dat audit (`scripts/inspect-progs.py`) flagged 52
// builtins not yet installed. This batch ships the easiest 10:
// pure-math (#27 vtos, #81 stof) and recordable no-op stubs
// (#28-31 debug, #68/75/76/77 precache variants). Each just
// records dispatch + a side channel where applicable so tests
// can verify routing without the full Quake server context.

// #27 — vtos(vec3) → string. Format as "'X Y Z'" (Quake's exact
// shape) into a static scratch buffer; return offset 0 since we
// don't grow pr_strings yet, but record the formatted text.
U0 _PR_PF_vtos() {
  F64 x = _PR_GetFloat(OFS_PARM0);
  F64 y = _PR_GetFloat(OFS_PARM0 + 1);
  F64 z = _PR_GetFloat(OFS_PARM0 + 2);
  static U8 vtos_buf[80];
  StrPrint(vtos_buf, "'%5.1f %5.1f %5.1f'", x, y, z);
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 27;
  I64 i = 0;
  while (i < 255 && vtos_buf[i]) {
    pr_last_builtin_arg0_str[i] = vtos_buf[i];
    i++;
  }
  pr_last_builtin_arg0_str[i] = 0;
}

// #28 — coredump() — prints diag dump in Quake; we just record.
U0 _PR_PF_coredump() {
  pr_last_builtin_called = 28;
}

// #29 — traceon() — toggle bytecode trace on; flip pr_trace.
U0 _PR_PF_traceon() {
  pr_trace = TRUE;
  pr_last_builtin_called = 29;
}

// #30 — traceoff() — flip pr_trace off.
U0 _PR_PF_traceoff() {
  pr_trace = FALSE;
  pr_last_builtin_called = 30;
}

// #31 — eprint(entity) — debug-print an entity's fields. We don't
// have a pretty-printer for arbitrary edicts yet; record only.
U0 _PR_PF_eprint() {
  pr_last_builtin_called = 31;
}

// #68 — precache_file(string) — no-op stub. Returns the same
// string. Same shape as #19 / #20 precache_sound/model.
U0 _PR_PF_precache_file() {
  I64 strofs = pr_globals[OFS_PARM0];
  pr_globals[OFS_RETURN] = strofs;
  pr_last_builtin_called = 68;
}

// #75 — precache_model2(string) — alias for precache_model in
// QuakeWorld; same no-op semantics for us.
U0 _PR_PF_precache_model2() {
  I64 strofs = pr_globals[OFS_PARM0];
  pr_globals[OFS_RETURN] = strofs;
  pr_last_builtin_called = 75;
}

// #76 — precache_sound2(string) — alias for precache_sound in QW.
U0 _PR_PF_precache_sound2() {
  I64 strofs = pr_globals[OFS_PARM0];
  pr_globals[OFS_RETURN] = strofs;
  pr_last_builtin_called = 76;
}

// #77 — precache_file2(string) — alias for precache_file in QW.
U0 _PR_PF_precache_file2() {
  I64 strofs = pr_globals[OFS_PARM0];
  pr_globals[OFS_RETURN] = strofs;
  pr_last_builtin_called = 77;
}

// ============================================================
// Phase 6 Batch 2 — math + entity-scan stubs.
// ============================================================
// #1 (makevectors) is the only real-math one — writes the
// v_forward / v_up / v_right vec3s into the globalvars_t overlay
// slots from a pitch/yaw/roll input. The rest (#18 find,
// #22 findradius, #44 aim, #49 ChangeYaw) need a real Quake
// server context; they ship as recordable stubs that return
// sensible defaults (world entity / zero vec) so dispatch routes.

// #1 — makevectors(vec3 angles) — angles[0]=pitch, [1]=yaw, [2]=roll
// in degrees. Writes the standard right-handed orthonormal basis
// to v_forward / v_up / v_right. Mirror of WinQuake's
// AngleVectors() in mathlib.c.
U0 _PR_PF_makevectors() {
  F64 pitch_deg = _PR_GetFloat(OFS_PARM0);
  F64 yaw_deg   = _PR_GetFloat(OFS_PARM0 + 1);
  F64 roll_deg  = _PR_GetFloat(OFS_PARM0 + 2);
  F64 deg2rad   = pi * 2.0 / 360.0;
  F64 sp = Sin(pitch_deg * deg2rad); F64 cp = Cos(pitch_deg * deg2rad);
  F64 sy = Sin(yaw_deg   * deg2rad); F64 cy = Cos(yaw_deg   * deg2rad);
  F64 sr = Sin(roll_deg  * deg2rad); F64 cr = Cos(roll_deg  * deg2rad);

  // forward = (cp*cy, cp*sy, -sp)
  _PR_SetFloat(OFS_GS_V_FORWARD,     cp * cy);
  _PR_SetFloat(OFS_GS_V_FORWARD + 1, cp * sy);
  _PR_SetFloat(OFS_GS_V_FORWARD + 2, -sp);
  // right = (-sr*sp*cy + cr*sy, -sr*sp*sy + -cr*cy, -sr*cp)
  _PR_SetFloat(OFS_GS_V_RIGHT,     -sr * sp * cy + cr * sy);
  _PR_SetFloat(OFS_GS_V_RIGHT + 1, -sr * sp * sy - cr * cy);
  _PR_SetFloat(OFS_GS_V_RIGHT + 2, -sr * cp);
  // up = (cr*sp*cy + sr*sy, cr*sp*sy - sr*cy, cr*cp)
  _PR_SetFloat(OFS_GS_V_UP,     cr * sp * cy + sr * sy);
  _PR_SetFloat(OFS_GS_V_UP + 1, cr * sp * sy - sr * cy);
  _PR_SetFloat(OFS_GS_V_UP + 2, cr * cp);
  pr_last_builtin_called = 1;
}

// #18 — find(start_entity, .field, value) → entity. Walks the edict
// pool starting from start+1 looking for an entity whose `.field`
// equals `value`. Returns 0 (the world entity) if none found.
// `.field` is passed as a field offset (slot units) in OFS_PARM1.
// `value` is the comparison target in OFS_PARM2 — for string
// fields this is a string offset.
U0 _PR_PF_find() {
  I64 start_ent = pr_globals[OFS_PARM0];
  I64 fld_ofs   = pr_globals[OFS_PARM1];
  I32 needle    = pr_globals[OFS_PARM2];
  I64 ent;
  for (ent = start_ent + 1; ent < pr_max_edicts; ent++) {
    if (pr_edicts[_PR_EdictFieldSlot(ent, fld_ofs)] == needle) {
      pr_globals[OFS_RETURN] = ent;
      pr_last_builtin_called = 18;
      return;
    }
  }
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 18;
}

// #22 — findradius(origin, radius) → entity. Returns the head of
// a linked list of entities within `radius` of `origin`. Real Quake
// chains them via the `chain` field. We don't yet model chain
// linking; return 0 (world) and record the call.
U0 _PR_PF_findradius() {
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 22;
}

// #44 — aim(entity, missile_speed) → vec3 forward. Used for
// auto-aim assistance in Quake. We return v_forward verbatim so
// the caller gets a sensible direction; full aim-cone logic
// requires traceline.
U0 _PR_PF_aim() {
  _PR_SetFloat(OFS_RETURN,     _PR_GetFloat(OFS_GS_V_FORWARD));
  _PR_SetFloat(OFS_RETURN + 1, _PR_GetFloat(OFS_GS_V_FORWARD + 1));
  _PR_SetFloat(OFS_RETURN + 2, _PR_GetFloat(OFS_GS_V_FORWARD + 2));
  pr_last_builtin_called = 44;
}

// #49 — ChangeYaw() — rotate self.angles[YAW] toward
// self.ideal_yaw at self.yaw_speed. Needs server-side per-frame
// state; record dispatch and leave self untouched.
U0 _PR_PF_ChangeYaw() {
  pr_last_builtin_called = 49;
}

// #81 — stof(string) → float. Parse a numeric string into F64.
// Q_atof exists in Bootstrap.HC.
U0 _PR_PF_stof() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *s = _PR_GetString(strofs);
  _PR_SetFloat(OFS_RETURN, Q_atof(s));
  pr_last_builtin_called = 81;
}

// ============================================================
// Phase 6 Batch 3 — network message bus (#52–#59 Write*)
// ============================================================
//
// All eight Write* builtins take `(float dest, X val)` where dest
// is the destination msg buffer (MSG_BROADCAST=0, MSG_ONE=1,
// MSG_ALL=2, MSG_INIT=3, MSG_MULTICAST=4 in Quake). Real Quake
// packs `val` into the appropriate network buffer. We don't have
// a network stack; capture (dest, val) into the side channels so
// tests can verify dispatch + the last write's shape.

// #52 — WriteByte(dest, val) — pack 1 byte (0..255 truncated).
// Note: HolyC's `&` on F64 operands acts on IEEE-754 bit patterns,
// so we MUST go through a typed I64 local before masking.
U0 _PR_PF_WriteByte() {
  pr_last_write_dest = _PR_GetFloat(OFS_PARM0);
  I64 vi = _PR_GetFloat(OFS_PARM1);
  pr_last_write_val_i = vi & 0xFF;
  pr_last_builtin_called = 52;
}

// #53 — WriteChar(dest, val) — pack 1 signed byte (-128..127)
U0 _PR_PF_WriteChar() {
  pr_last_write_dest = _PR_GetFloat(OFS_PARM0);
  I64 vi = _PR_GetFloat(OFS_PARM1);
  pr_last_write_val_i = vi;
  pr_last_builtin_called = 53;
}

// #54 — WriteShort(dest, val) — pack 2 bytes (16-bit short)
U0 _PR_PF_WriteShort() {
  pr_last_write_dest = _PR_GetFloat(OFS_PARM0);
  I64 vi = _PR_GetFloat(OFS_PARM1);
  pr_last_write_val_i = vi & 0xFFFF;
  pr_last_builtin_called = 54;
}

// #55 — WriteLong(dest, val) — pack 4 bytes
U0 _PR_PF_WriteLong() {
  pr_last_write_dest = _PR_GetFloat(OFS_PARM0);
  I64 vi = _PR_GetFloat(OFS_PARM1);
  pr_last_write_val_i = vi;
  pr_last_builtin_called = 55;
}

// #56 — WriteCoord(dest, coord) — pack a coord (Quake packs these
// as 16.3 fixed-point shorts; we just record the float).
U0 _PR_PF_WriteCoord() {
  pr_last_write_dest  = _PR_GetFloat(OFS_PARM0);
  pr_last_write_val_f = _PR_GetFloat(OFS_PARM1);
  pr_last_builtin_called = 56;
}

// #57 — WriteAngle(dest, angle) — pack an angle (Quake: 0..255
// representing 0°..360°). Record the float as-is.
U0 _PR_PF_WriteAngle() {
  pr_last_write_dest  = _PR_GetFloat(OFS_PARM0);
  pr_last_write_val_f = _PR_GetFloat(OFS_PARM1);
  pr_last_builtin_called = 57;
}

// #58 — WriteString(dest, string) — pack a NUL-terminated string.
// Resolve the string offset and copy into pr_last_write_val_str.
U0 _PR_PF_WriteString() {
  pr_last_write_dest = _PR_GetFloat(OFS_PARM0);
  I64 strofs = pr_globals[OFS_PARM1];
  U8 *s = _PR_GetString(strofs);
  Q_strncpy(pr_last_write_val_str, s, 255);
  pr_last_write_val_str[255] = 0;                  // belt-and-braces NUL
  pr_last_builtin_called = 58;
}

// #59 — WriteEntity(dest, entity) — pack an entity index as a short.
U0 _PR_PF_WriteEntity() {
  pr_last_write_dest  = _PR_GetFloat(OFS_PARM0);
  pr_last_write_val_i = pr_globals[OFS_PARM1] & 0xFFFF;
  pr_last_builtin_called = 59;
}

// ============================================================
// Phase 6 Batch 4 — server state mutators (#2/#3/#4, #14/#15,
// #69/#74/#78)
// ============================================================
//
// Setorigin / setmodel / setsize write into an entity's field
// block via symbolic field lookup; spawn allocates a fresh edict
// index; remove records the index. Real Quake also links the
// entity into the BSP collision tree, plays sounds, etc. — those
// behaviors are server-side and out of scope for the VM.

// #2 — setorigin(entity, vec3) — write into the entity's origin
// field (first 3 slots of "origin" by name lookup, fall back to
// fielddef-free no-op when the layout has no origin).
U0 _PR_PF_setorigin() {
  I64 ent = pr_globals[OFS_PARM0];
  I64 ofs = _PR_FieldOfsByName("origin");
  if (ofs >= 0) {
    I64 base = _PR_EdictFieldSlot(ent, ofs);
    pr_edicts[base]     = pr_globals[OFS_PARM1];
    pr_edicts[base + 1] = pr_globals[OFS_PARM1 + 1];
    pr_edicts[base + 2] = pr_globals[OFS_PARM1 + 2];
  }
  pr_last_builtin_called = 2;
}

// #3 — setmodel(entity, string) — write the string offset into
// the entity's "model" field. Real Quake also resolves the model,
// loads collision hulls, etc.
U0 _PR_PF_setmodel() {
  I64 ent = pr_globals[OFS_PARM0];
  I64 ofs = _PR_FieldOfsByName("model");
  if (ofs >= 0) {
    pr_edicts[_PR_EdictFieldSlot(ent, ofs)] = pr_globals[OFS_PARM1];
  }
  pr_last_builtin_called = 3;
}

// #4 — setsize(entity, vec3 mins, vec3 maxs) — write mins/maxs
// fields and recompute size as (maxs - mins). HolyC's PrsType
// shares scope across if-bodies (similar to its switch-case
// quirk), so the per-block `I64 b_*` names must all differ.
U0 _PR_PF_setsize() {
  I64 ent  = pr_globals[OFS_PARM0];
  I64 omn  = _PR_FieldOfsByName("mins");
  I64 omx  = _PR_FieldOfsByName("maxs");
  I64 osz  = _PR_FieldOfsByName("size");
  if (omn >= 0) {
    I64 b_mn = _PR_EdictFieldSlot(ent, omn);
    pr_edicts[b_mn]     = pr_globals[OFS_PARM1];
    pr_edicts[b_mn + 1] = pr_globals[OFS_PARM1 + 1];
    pr_edicts[b_mn + 2] = pr_globals[OFS_PARM1 + 2];
  }
  if (omx >= 0) {
    I64 b_mx = _PR_EdictFieldSlot(ent, omx);
    pr_edicts[b_mx]     = pr_globals[OFS_PARM2];
    pr_edicts[b_mx + 1] = pr_globals[OFS_PARM2 + 1];
    pr_edicts[b_mx + 2] = pr_globals[OFS_PARM2 + 2];
  }
  if (osz >= 0) {
    F64 mnx = _PR_GetFloat(OFS_PARM1);
    F64 mny = _PR_GetFloat(OFS_PARM1 + 1);
    F64 mnz = _PR_GetFloat(OFS_PARM1 + 2);
    F64 mxx = _PR_GetFloat(OFS_PARM2);
    F64 mxy = _PR_GetFloat(OFS_PARM2 + 1);
    F64 mxz = _PR_GetFloat(OFS_PARM2 + 2);
    I64 b_sz = _PR_EdictFieldSlot(ent, osz);
    pr_edicts[b_sz]     = _PR_F64_to_F32(mxx - mnx);
    pr_edicts[b_sz + 1] = _PR_F64_to_F32(mxy - mny);
    pr_edicts[b_sz + 2] = _PR_F64_to_F32(mxz - mnz);
  }
  pr_last_builtin_called = 4;
}

// #14 — spawn() → entity. Allocate a fresh edict index. Real
// Quake reuses freed slots; we just advance a monotonic counter
// for simplicity (capped at MAX_EDICTS).
U0 _PR_PF_spawn() {
  if (pr_next_free_edict >= MAX_EDICTS) {
    pr_globals[OFS_RETURN] = 0;                   // world (fail)
  } else {
    pr_globals[OFS_RETURN] = pr_next_free_edict;
    pr_last_spawned = pr_next_free_edict;
    pr_next_free_edict++;
  }
  pr_last_builtin_called = 14;
}

// #15 — remove(entity) — record the freed entity index. Real
// Quake clears the edict and adds it to the free list.
U0 _PR_PF_remove() {
  pr_last_removed = pr_globals[OFS_PARM0];
  pr_last_builtin_called = 15;
}

// #69 — makestatic(entity) — broadcasts a baseline-only entity
// (decorations). Stub records dispatch.
U0 _PR_PF_makestatic() {
  pr_last_builtin_called = 69;
}

// #74 — ambientsound(origin, sample, vol, attenuation) — adds an
// ambient sound to the level. Stub records dispatch.
U0 _PR_PF_ambientsound() {
  pr_last_builtin_called = 74;
}

// #78 — setspawnparms(client) — copies serverflags into the
// client's parm1..parm16 globals. Stub records dispatch.
U0 _PR_PF_setspawnparms() {
  pr_last_builtin_called = 78;
}

// ============================================================
// Phase 6 Batch 5 — collision / tracing (#16, #32, #34, #40, #41)
// ============================================================
//
// Real Quake walks the BSP collision tree to compute trace
// results; we don't have a map. Stubs return "no hit" defaults
// (trace_fraction = 1.0, allsolid = startsolid = 0, endpos =
// requested end, plane_normal = (0,0,1), trace_ent = 0=world).
// pointcontents returns CONTENTS_EMPTY (-1). walkmove /
// droptofloor / checkbottom return 0 (no movement / not OK).

#define CONTENTS_EMPTY  -1

// #16 — traceline(v1, v2, nomonsters, ignore_ent) — set the
// trace_* result slots to "no hit, end at v2".
U0 _PR_PF_traceline() {
  _PR_SetFloat(OFS_GS_TRACE_ALLSOLID,   0.0);
  _PR_SetFloat(OFS_GS_TRACE_STARTSOLID, 0.0);
  _PR_SetFloat(OFS_GS_TRACE_FRACTION,   1.0);
  // endpos = OFS_PARM1 (the v2 endpoint)
  _PR_SetFloat(OFS_GS_TRACE_ENDPOS,     _PR_GetFloat(OFS_PARM1));
  _PR_SetFloat(OFS_GS_TRACE_ENDPOS + 1, _PR_GetFloat(OFS_PARM1 + 1));
  _PR_SetFloat(OFS_GS_TRACE_ENDPOS + 2, _PR_GetFloat(OFS_PARM1 + 2));
  // plane_normal = up (0,0,1) — sensible default for a "no hit"
  _PR_SetFloat(OFS_GS_TRACE_PLANE_NORMAL,     0.0);
  _PR_SetFloat(OFS_GS_TRACE_PLANE_NORMAL + 1, 0.0);
  _PR_SetFloat(OFS_GS_TRACE_PLANE_NORMAL + 2, 1.0);
  _PR_SetFloat(OFS_GS_TRACE_PLANE_DIST, 0.0);
  pr_globals[OFS_GS_TRACE_ENT]    = 0;
  _PR_SetFloat(OFS_GS_TRACE_INOPEN,  1.0);
  _PR_SetFloat(OFS_GS_TRACE_INWATER, 0.0);
  pr_last_builtin_called = 16;
}

// #32 — walkmove(yaw, dist) → float (1=success, 0=blocked)
U0 _PR_PF_walkmove() {
  _PR_SetFloat(OFS_RETURN, 0.0);                  // blocked (no map)
  pr_last_builtin_called = 32;
}

// #34 — droptofloor() → float (1=on floor, 0=stuck/falling)
U0 _PR_PF_droptofloor() {
  _PR_SetFloat(OFS_RETURN, 1.0);                  // pretend on floor
  pr_last_builtin_called = 34;
}

// #40 — checkbottom(entity) → float (1=ok, 0=not standing on solid)
U0 _PR_PF_checkbottom() {
  _PR_SetFloat(OFS_RETURN, 1.0);                  // pretend ok
  pr_last_builtin_called = 40;
}

// #41 — pointcontents(point) → float (CONTENTS_*: -1 empty, -2 solid)
U0 _PR_PF_pointcontents() {
  _PR_SetFloat(OFS_RETURN, CONTENTS_EMPTY);
  pr_last_builtin_called = 41;
}

// ============================================================
// Phase 6 Batch 6 — cvar/console (#21, #45, #46, #72, #80)
// ============================================================
//
// cvar / cvar_set delegate to the existing Cvar_VariableValue /
// Cvar_Set in Cvar.HC. stuffcmd / localcmd / infokey are
// recordable stubs — real Quake queues network messages or
// console commands; for VM-side bytecode validation we just
// capture (client, payload) into pr_last_console_*.

I64 pr_last_stuffcmd_client = 0;
U8  pr_last_stuffcmd_str[256];
U8  pr_last_localcmd_str[256];

// #21 — stuffcmd(client, string) — record dispatch + payload.
U0 _PR_PF_stuffcmd() {
  pr_last_stuffcmd_client = pr_globals[OFS_PARM0];
  I64 strofs = pr_globals[OFS_PARM1];
  Q_strncpy(pr_last_stuffcmd_str, _PR_GetString(strofs), 255);
  pr_last_stuffcmd_str[255] = 0;
  pr_last_builtin_called = 21;
}

// #45 — cvar(string name) → float
U0 _PR_PF_cvar() {
  I64 strofs = pr_globals[OFS_PARM0];
  U8 *name = _PR_GetString(strofs);
  _PR_SetFloat(OFS_RETURN, Cvar_VariableValue(name));
  pr_last_builtin_called = 45;
}

// #46 — localcmd(string) — append a server console command.
U0 _PR_PF_localcmd() {
  I64 strofs = pr_globals[OFS_PARM0];
  Q_strncpy(pr_last_localcmd_str, _PR_GetString(strofs), 255);
  pr_last_localcmd_str[255] = 0;
  pr_last_builtin_called = 46;
}

// #72 — cvar_set(name_str, value_str) — delegate to Cvar_Set.
U0 _PR_PF_cvar_set() {
  I64 nofs = pr_globals[OFS_PARM0];
  I64 vofs = pr_globals[OFS_PARM1];
  Cvar_Set(_PR_GetString(nofs), _PR_GetString(vofs));
  pr_last_builtin_called = 72;
}

// #80 — infokey(client, keyname) → string. Real Quake parses the
// client's userinfo string. We have no client state; return the
// null string (offset 0).
U0 _PR_PF_infokey() {
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 80;
}

// ============================================================
// Phase 6 Batch 7 — multiplayer messaging (#23, #24, #73, #79, #82)
// ============================================================
// All are print/broadcast-shaped. Single shared pr_last_msg_*
// channel records the most recent text + addressed client (when
// applicable). pr_last_builtin_called distinguishes which kind.

I64 pr_last_msg_client = 0;
U8  pr_last_msg_str[256];
I64 pr_last_logfrag_killer = 0;
I64 pr_last_logfrag_victim = 0;
I64 pr_last_multicast_dest = 0;

// #23 — bprint(msg) — broadcast to all clients.
U0 _PR_PF_bprint() {
  I64 strofs = pr_globals[OFS_PARM0];
  Q_strncpy(pr_last_msg_str, _PR_GetString(strofs), 255);
  pr_last_msg_str[255] = 0;
  pr_last_msg_client = -1;                         // sentinel: broadcast
  pr_last_builtin_called = 23;
}

// #24 — sprint(client, msg) — print to one client.
U0 _PR_PF_sprint() {
  pr_last_msg_client = pr_globals[OFS_PARM0];
  I64 strofs = pr_globals[OFS_PARM1];
  Q_strncpy(pr_last_msg_str, _PR_GetString(strofs), 255);
  pr_last_msg_str[255] = 0;
  pr_last_builtin_called = 24;
}

// #73 — centerprint(client, msg) — center-screen text.
U0 _PR_PF_centerprint() {
  pr_last_msg_client = pr_globals[OFS_PARM0];
  I64 strofs = pr_globals[OFS_PARM1];
  Q_strncpy(pr_last_msg_str, _PR_GetString(strofs), 255);
  pr_last_msg_str[255] = 0;
  pr_last_builtin_called = 73;
}

// #79 — logfrag(killer_ent, victim_ent) — record killer/victim.
U0 _PR_PF_logfrag() {
  pr_last_logfrag_killer = pr_globals[OFS_PARM0];
  pr_last_logfrag_victim = pr_globals[OFS_PARM1];
  pr_last_builtin_called = 79;
}

// #82 — multicast(origin, sendto) — flush multicast buffer.
// We don't queue messages, just record the destination tag.
U0 _PR_PF_multicast() {
  pr_last_multicast_dest = _PR_GetFloat(OFS_PARM1);
  pr_last_builtin_called = 82;
}

// ============================================================
// Phase 6 Batch 8 — closeout (#8, #17, #35, #47, #67, #70)
// ============================================================
//
// Closes out the qwprogs.dat dispatch table: 100% of the 68
// referenced builtins now have a handler. Most are recordable
// stubs; #47 nextent walks the edict pool for real.

I64 pr_last_sound_ent     = 0;
I64 pr_last_sound_chan    = 0;
I64 pr_last_sound_sample  = 0;        // string offset
I64 pr_last_lightstyle    = 0;        // style index
U8  pr_last_lightstyle_str[64];
I64 pr_last_changelevel_str = 0;      // string offset of map name
F64 pr_last_movetogoal_dist = 0.0;

// #8 — sound(entity, channel, sample, volume, attenuation) — capture
// (entity, channel, sample-offset). Real Quake plays a sound; we
// just record dispatch.
U0 _PR_PF_sound() {
  pr_last_sound_ent    = pr_globals[OFS_PARM0];
  pr_last_sound_chan   = _PR_GetFloat(OFS_PARM1);
  pr_last_sound_sample = pr_globals[OFS_PARM2];
  pr_last_builtin_called = 8;
}

// #17 — checkclient() → entity. Real Quake returns a random
// client visible from the current entity for AI line-of-sight.
// No clients in our VM — return world (0).
U0 _PR_PF_checkclient() {
  pr_globals[OFS_RETURN] = 0;
  pr_last_builtin_called = 17;
}

// #35 — lightstyle(style, value_str) — set a light animation
// pattern (e.g. "abcdefghijklmnopqrst" for a smooth fade). Capture
// the style index + string for tests.
U0 _PR_PF_lightstyle() {
  pr_last_lightstyle = _PR_GetFloat(OFS_PARM0);
  I64 strofs = pr_globals[OFS_PARM1];
  Q_strncpy(pr_last_lightstyle_str, _PR_GetString(strofs), 63);
  pr_last_lightstyle_str[63] = 0;
  pr_last_builtin_called = 35;
}

// #47 — nextent(start) → entity. Walks the edict pool for the
// next allocated index past `start`. Real Quake skips
// freed/inhibited edicts; we don't model freed-list state, so we
// return start+1 capped at pr_next_free_edict (the highwater
// from spawn). Returns 0 (world) when past the end.
U0 _PR_PF_nextent() {
  I64 start = pr_globals[OFS_PARM0];
  I64 next  = start + 1;
  if (next >= pr_next_free_edict) {
    pr_globals[OFS_RETURN] = 0;
  } else {
    pr_globals[OFS_RETURN] = next;
  }
  pr_last_builtin_called = 47;
}

// #67 — movetogoal(dist) — monster-AI step toward goal_entity.
// Real Quake walks/blocks based on geometry; record dist + return
// 1 (moved successfully).
U0 _PR_PF_movetogoal() {
  pr_last_movetogoal_dist = _PR_GetFloat(OFS_PARM0);
  _PR_SetFloat(OFS_RETURN, 1.0);
  pr_last_builtin_called = 67;
}

// #70 — changelevel(map_name) — schedule a map change. Record
// the requested name string offset.
U0 _PR_PF_changelevel() {
  pr_last_changelevel_str = pr_globals[OFS_PARM0];
  pr_last_builtin_called = 70;
}

// Builtin dispatch — invoked when a function call hits a
// dfunction_t with first_statement < 0. The negation is the
// builtin index.
U0 _PR_DispatchBuiltin(I64 idx) {
  switch (idx) {
    case  1: _PR_PF_makevectors();       break;
    case  2: _PR_PF_setorigin();         break;
    case  3: _PR_PF_setmodel();          break;
    case  4: _PR_PF_setsize();           break;
    case  6: _PR_PF_break();             break;
    case  7: _PR_PF_random();            break;
    case  8: _PR_PF_sound();             break;
    case  9: _PR_PF_normalize();         break;
    case 10: _PR_PF_error();             break;
    case 11: _PR_PF_objerror();          break;
    case 12: _PR_PF_vlen();              break;
    case 13: _PR_PF_vectoyaw();          break;
    case 14: _PR_PF_spawn();             break;
    case 15: _PR_PF_remove();            break;
    case 16: _PR_PF_traceline();         break;
    case 17: _PR_PF_checkclient();       break;
    case 18: _PR_PF_find();              break;
    case 19: _PR_PF_precache_sound();    break;
    case 20: _PR_PF_precache_model();    break;
    case 21: _PR_PF_stuffcmd();          break;
    case 22: _PR_PF_findradius();        break;
    case 23: _PR_PF_bprint();            break;
    case 24: _PR_PF_sprint();            break;
    case 25: _PR_PF_dprint();            break;
    case 26: _PR_PF_ftos();              break;
    case 27: _PR_PF_vtos();              break;
    case 28: _PR_PF_coredump();          break;
    case 29: _PR_PF_traceon();           break;
    case 30: _PR_PF_traceoff();          break;
    case 31: _PR_PF_eprint();            break;
    case 32: _PR_PF_walkmove();          break;
    case 34: _PR_PF_droptofloor();       break;
    case 35: _PR_PF_lightstyle();        break;
    case 36: _PR_PF_rint();              break;
    case 37: _PR_PF_floor();             break;
    case 38: _PR_PF_ceil();              break;
    case 40: _PR_PF_checkbottom();       break;
    case 41: _PR_PF_pointcontents();     break;
    case 43: _PR_PF_fabs();              break;
    case 44: _PR_PF_aim();               break;
    case 45: _PR_PF_cvar();              break;
    case 46: _PR_PF_localcmd();          break;
    case 47: _PR_PF_nextent();           break;
    case 49: _PR_PF_ChangeYaw();         break;
    case 51: _PR_PF_vectoangles();       break;
    case 52: _PR_PF_WriteByte();         break;
    case 53: _PR_PF_WriteChar();         break;
    case 54: _PR_PF_WriteShort();        break;
    case 55: _PR_PF_WriteLong();         break;
    case 56: _PR_PF_WriteCoord();        break;
    case 57: _PR_PF_WriteAngle();        break;
    case 58: _PR_PF_WriteString();       break;
    case 59: _PR_PF_WriteEntity();       break;
    case 67: _PR_PF_movetogoal();        break;
    case 68: _PR_PF_precache_file();     break;
    case 69: _PR_PF_makestatic();        break;
    case 70: _PR_PF_changelevel();       break;
    case 72: _PR_PF_cvar_set();          break;
    case 73: _PR_PF_centerprint();       break;
    case 74: _PR_PF_ambientsound();      break;
    case 75: _PR_PF_precache_model2();   break;
    case 76: _PR_PF_precache_sound2();   break;
    case 77: _PR_PF_precache_file2();    break;
    case 78: _PR_PF_setspawnparms();     break;
    case 79: _PR_PF_logfrag();           break;
    case 80: _PR_PF_infokey();           break;
    case 81: _PR_PF_stof();              break;
    case 82: _PR_PF_multicast();         break;
    default:
      Print("PR: builtin #%d not installed\n", idx);
      pr_halted = TRUE;
      break;
  }
}

// ============================================================
// PR_ExecuteProgram — main interpreter loop
// ============================================================

#define PR_MAX_STEPS 100000          // runaway loop guard

U0 PR_ExecuteProgram(I64 fnum) {
  if (fnum < 0 || fnum >= pr_numfunctions) {
    Print("PR_ExecuteProgram: bad function index %d\n", fnum);
    return;
  }
  dfunction_t *f = &pr_functions[fnum];
  if (f->first_statement < 0) {
    Print("PR_ExecuteProgram: cannot directly call builtin function\n");
    return;
  }

  pr_halted = FALSE;
  pr_runaway = FALSE;
  I64 exit_depth = _pr_depth;
  pr_xstatement = _PR_EnterFunction(fnum);

  I64 steps = 0;
  // Hoisted scratch for cases that need temporaries (HolyC switch
  // case bodies share scope, so per-case decls collide).
  I64 bitop_a;
  I64 bitop_b;

  while (!pr_halted) {
    pr_xstatement++;
    if (pr_xstatement < 0 || pr_xstatement >= pr_numstatements) {
      Print("PR_ExecuteProgram: bad pc=%d\n", pr_xstatement);
      _PR_StackTrace();
      pr_halted = TRUE;
      break;
    }
    steps++;
    if (steps > PR_MAX_STEPS) {
      Print("PR_ExecuteProgram: runaway loop\n");
      _PR_StackTrace();
      pr_runaway = TRUE;
      pr_halted = TRUE;
      break;
    }

    dstatement_t *s = &pr_statements[pr_xstatement];
    I16 op = s->op;
    I64 a = s->a;
    I64 b = s->b;
    I64 c = s->c;

    if (pr_trace) {
      Print("[%d] op=%d a=%d b=%d c=%d\n", pr_xstatement, op, a, b, c);
    }

    switch (op) {
      // ---- arithmetic (float-only for MVP) ----
      case OP_ADD_F:
        _PR_SetFloat(c, _PR_GetFloat(a) + _PR_GetFloat(b));
        break;
      case OP_SUB_F:
        _PR_SetFloat(c, _PR_GetFloat(a) - _PR_GetFloat(b));
        break;
      case OP_MUL_F:
        _PR_SetFloat(c, _PR_GetFloat(a) * _PR_GetFloat(b));
        break;
      case OP_DIV_F:
        _PR_SetFloat(c, _PR_GetFloat(a) / _PR_GetFloat(b));
        break;

      // ---- handle compare (strings, entities, functions) ----
      // Strings live in pr_strings; the slot value is the offset.
      // EQ_S / NE_S compare the resolved bytes via strcmp. Entities
      // and function handles are bare integers — compare directly.
      case OP_EQ_S:
        _PR_SetFloat(c,
            Q_strcmp(_PR_GetString(pr_globals[a]),
                     _PR_GetString(pr_globals[b])) == 0);
        break;
      case OP_NE_S:
        _PR_SetFloat(c,
            Q_strcmp(_PR_GetString(pr_globals[a]),
                     _PR_GetString(pr_globals[b])) != 0);
        break;
      case OP_EQ_E:
      case OP_EQ_FNC:
        _PR_SetFloat(c, pr_globals[a] == pr_globals[b]);
        break;
      case OP_NE_E:
      case OP_NE_FNC:
        _PR_SetFloat(c, pr_globals[a] != pr_globals[b]);
        break;

      // ---- vector arithmetic ----
      // Vec3 lives in three consecutive 4-byte global slots, so we
      // address componentwise (a, a+1, a+2) — matches OP_STORE_V.
      case OP_ADD_V:
        _PR_SetFloat(c,     _PR_GetFloat(a)     + _PR_GetFloat(b));
        _PR_SetFloat(c + 1, _PR_GetFloat(a + 1) + _PR_GetFloat(b + 1));
        _PR_SetFloat(c + 2, _PR_GetFloat(a + 2) + _PR_GetFloat(b + 2));
        break;
      case OP_SUB_V:
        _PR_SetFloat(c,     _PR_GetFloat(a)     - _PR_GetFloat(b));
        _PR_SetFloat(c + 1, _PR_GetFloat(a + 1) - _PR_GetFloat(b + 1));
        _PR_SetFloat(c + 2, _PR_GetFloat(a + 2) - _PR_GetFloat(b + 2));
        break;
      case OP_MUL_V:
        // Dot product → scalar.
        _PR_SetFloat(
            c,
            _PR_GetFloat(a)     * _PR_GetFloat(b)
          + _PR_GetFloat(a + 1) * _PR_GetFloat(b + 1)
          + _PR_GetFloat(a + 2) * _PR_GetFloat(b + 2));
        break;
      case OP_MUL_FV:
        // scalar(a) * vec(b) → vec(c).
        _PR_SetFloat(c,     _PR_GetFloat(a) * _PR_GetFloat(b));
        _PR_SetFloat(c + 1, _PR_GetFloat(a) * _PR_GetFloat(b + 1));
        _PR_SetFloat(c + 2, _PR_GetFloat(a) * _PR_GetFloat(b + 2));
        break;
      case OP_MUL_VF:
        // vec(a) * scalar(b) → vec(c).
        _PR_SetFloat(c,     _PR_GetFloat(a)     * _PR_GetFloat(b));
        _PR_SetFloat(c + 1, _PR_GetFloat(a + 1) * _PR_GetFloat(b));
        _PR_SetFloat(c + 2, _PR_GetFloat(a + 2) * _PR_GetFloat(b));
        break;

      // ---- vector compare / not ----
      case OP_EQ_V:
        _PR_SetFloat(c,
            (_PR_GetFloat(a)     == _PR_GetFloat(b))
         && (_PR_GetFloat(a + 1) == _PR_GetFloat(b + 1))
         && (_PR_GetFloat(a + 2) == _PR_GetFloat(b + 2)));
        break;
      case OP_NE_V:
        _PR_SetFloat(c,
            (_PR_GetFloat(a)     != _PR_GetFloat(b))
         || (_PR_GetFloat(a + 1) != _PR_GetFloat(b + 1))
         || (_PR_GetFloat(a + 2) != _PR_GetFloat(b + 2)));
        break;
      case OP_NOT_V:
        _PR_SetFloat(c,
            (_PR_GetFloat(a)     == 0.0)
         && (_PR_GetFloat(a + 1) == 0.0)
         && (_PR_GetFloat(a + 2) == 0.0));
        break;

      // ---- compare (float-only for MVP) ----
      case OP_EQ_F:
        _PR_SetFloat(c, _PR_GetFloat(a) == _PR_GetFloat(b));
        break;
      case OP_NE_F:
        _PR_SetFloat(c, _PR_GetFloat(a) != _PR_GetFloat(b));
        break;
      case OP_LE:
        _PR_SetFloat(c, _PR_GetFloat(a) <= _PR_GetFloat(b));
        break;
      case OP_GE:
        _PR_SetFloat(c, _PR_GetFloat(a) >= _PR_GetFloat(b));
        break;
      case OP_LT:
        _PR_SetFloat(c, _PR_GetFloat(a) < _PR_GetFloat(b));
        break;
      case OP_GT:
        _PR_SetFloat(c, _PR_GetFloat(a) > _PR_GetFloat(b));
        break;

      // ---- logical ----
      case OP_NOT_F:
        _PR_SetFloat(c, _PR_GetFloat(a) == 0.0);
        break;
      case OP_AND:
        _PR_SetFloat(c, (_PR_GetFloat(a) != 0.0) && (_PR_GetFloat(b) != 0.0));
        break;
      case OP_OR:
        _PR_SetFloat(c, (_PR_GetFloat(a) != 0.0) || (_PR_GetFloat(b) != 0.0));
        break;

      // ---- bitwise: Quake truncates each float to int BEFORE
      // ANDing/ORing (pr_exec.c semantics). HolyC's `&` on F64 would
      // AND the IEEE-754 bit patterns — not what we want. Reuses
      // the hoisted bitop_a / bitop_b temporaries (case blocks share
      // scope in HolyC, so per-case decls aren't legal).
      case OP_BITAND:
        bitop_a = _PR_GetFloat(a);
        bitop_b = _PR_GetFloat(b);
        _PR_SetFloat(c, bitop_a & bitop_b);
        break;
      case OP_BITOR:
        bitop_a = _PR_GetFloat(a);
        bitop_b = _PR_GetFloat(b);
        _PR_SetFloat(c, bitop_a | bitop_b);
        break;

      // ---- entity field load ----
      // a = global slot holding entity index
      // b = global slot holding field offset (in 4-byte units)
      // c = destination global slot
      case OP_LOAD_F:
      case OP_LOAD_S:
      case OP_LOAD_ENT:
      case OP_LOAD_FLD:
      case OP_LOAD_FNC:
        pr_globals[c] = pr_edicts[
            _PR_EdictFieldSlot(pr_globals[a], pr_globals[b])];
        break;
      case OP_LOAD_V: {
        I64 _slot = _PR_EdictFieldSlot(pr_globals[a], pr_globals[b]);
        pr_globals[c]     = pr_edicts[_slot];
        pr_globals[c + 1] = pr_edicts[_slot + 1];
        pr_globals[c + 2] = pr_edicts[_slot + 2];
      } break;

      // ---- entity field address ----
      // c = field pointer (byte offset into pr_edicts) for entity
      // pr_globals[a] at field offset pr_globals[b]. The byte-offset
      // encoding matches Quake's `(byte *)sv.edicts + b->_int` so a
      // real progs.dat's pre-baked pointers Just Work.
      case OP_ADDRESS:
        pr_globals[c] = _PR_FieldPointerFromEntity(
            pr_globals[a], pr_globals[b]);
        break;

      // ---- pointer store: write through a field pointer ----
      // a = source global slot
      // b = global slot holding field pointer (byte offset)
      case OP_STOREP_F:
      case OP_STOREP_S:
      case OP_STOREP_ENT:
      case OP_STOREP_FLD:
      case OP_STOREP_FNC:
        pr_edicts[_PR_FieldSlotFromPointer(pr_globals[b])] = pr_globals[a];
        break;
      case OP_STOREP_V: {
        I64 _pslot = _PR_FieldSlotFromPointer(pr_globals[b]);
        pr_edicts[_pslot]     = pr_globals[a];
        pr_edicts[_pslot + 1] = pr_globals[a + 1];
        pr_edicts[_pslot + 2] = pr_globals[a + 2];
      } break;

      // ---- not (non-float scalar variants) ----
      // OP_NOT_S/ENT/FNC operate on integer slots — they're "is this
      // handle zero?" checks, not float compares. Result is a float
      // boolean (1.0 / 0.0) per Quake convention.
      case OP_NOT_S:
      case OP_NOT_ENT:
      case OP_NOT_FNC:
        _PR_SetFloat(c, pr_globals[a] == 0);
        break;

      // ---- store (no type conversion needed at this layer) ----
      case OP_STORE_F:
      case OP_STORE_S:
      case OP_STORE_FNC:
      case OP_STORE_ENT:
      case OP_STORE_FLD:
        pr_globals[b] = pr_globals[a];
        break;
      case OP_STORE_V:
        pr_globals[b] = pr_globals[a];
        pr_globals[b + 1] = pr_globals[a + 1];
        pr_globals[b + 2] = pr_globals[a + 2];
        break;

      // ---- control flow ----
      case OP_IF:
        if (_PR_GetFloat(a) != 0.0) {
          pr_xstatement = pr_xstatement + b - 1;     // -1 because of pr_xstatement++ at loop head
        }
        break;
      case OP_IFNOT:
        if (_PR_GetFloat(a) == 0.0) {
          pr_xstatement = pr_xstatement + b - 1;
        }
        break;
      case OP_GOTO:
        pr_xstatement = pr_xstatement + a - 1;
        break;

      // ---- return ----
      case OP_RETURN:
        // RETURN copies 3 floats from `a` into OFS_RETURN.
        pr_globals[OFS_RETURN]     = pr_globals[a];
        pr_globals[OFS_RETURN + 1] = pr_globals[a + 1];
        pr_globals[OFS_RETURN + 2] = pr_globals[a + 2];
        pr_xstatement = _PR_LeaveFunction();
        if (_pr_depth == exit_depth) {
          pr_halted = TRUE;
        }
        break;
      // ---- OP_STATE — animation think-state setter ----
      // Mirrors Quake's pr_exec.c: reads `self` and `time` from the
      // server-globals overlay, then writes through to the entity's
      // frame/nextthink/think fields. Field offsets are resolved
      // symbolically via `_PR_FieldOfsByName` against the progs's
      // ddef_t fielddefs table — no hardcoded entvars_t layout.
      // If any of the three names isn't in the table (e.g. a
      // synthetic test fixture), the corresponding write is
      // skipped; the recordable side channels still update so
      // dispatch-only tests stay green.
      case OP_STATE: {
        pr_last_op_state_called = TRUE;
        pr_last_op_state_frame  = _PR_GetFloat(a);
        pr_last_op_state_think  = pr_globals[b];
        I64 _self_ent = pr_globals[OFS_GS_SELF];
        F64 _time     = _PR_GetFloat(OFS_GS_TIME);
        I64 _ofs_frame     = _PR_FieldOfsByName("frame");
        I64 _ofs_nextthink = _PR_FieldOfsByName("nextthink");
        I64 _ofs_think     = _PR_FieldOfsByName("think");
        if (_ofs_frame >= 0) {
          pr_edicts[_PR_EdictFieldSlot(_self_ent, _ofs_frame)] =
              _PR_F64_to_F32(pr_last_op_state_frame);
        }
        if (_ofs_nextthink >= 0) {
          pr_edicts[_PR_EdictFieldSlot(_self_ent, _ofs_nextthink)] =
              _PR_F64_to_F32(_time + 0.1);
        }
        if (_ofs_think >= 0) {
          pr_edicts[_PR_EdictFieldSlot(_self_ent, _ofs_think)] =
              pr_last_op_state_think;
        }
      } break;

      case OP_DONE:
        pr_xstatement = _PR_LeaveFunction();
        if (_pr_depth == exit_depth) {
          pr_halted = TRUE;
        }
        break;

      // ---- function call (CALL0..CALL8) ----
      // `a` indexes into globals; globals[a] holds the callee's
      // function index. The opcode value encodes the param count
      // (CALL0 = 0 args, CALL1 = 1 arg, …, CALL8 = 8 args). Args
      // are already in OFS_PARMn slots — the caller set them up.
      case OP_CALL0:
      case OP_CALL1:
      case OP_CALL2:
      case OP_CALL3:
      case OP_CALL4:
      case OP_CALL5:
      case OP_CALL6:
      case OP_CALL7:
      case OP_CALL8: {
        pr_argc = op - OP_CALL0;
        I64 fnum_callee = pr_globals[a];
        if (fnum_callee == 0) {
          Print("PR_ExecuteProgram: NULL function call\n");
          _PR_StackTrace();
          pr_halted = TRUE;
          break;
        }
        if (fnum_callee < 0 || fnum_callee >= pr_numfunctions) {
          Print("PR_ExecuteProgram: bad function index %d\n", fnum_callee);
          pr_halted = TRUE;
          break;
        }
        dfunction_t *newf = &pr_functions[fnum_callee];
        if (newf->first_statement < 0) {
          // Builtin: dispatch through the switch.
          _PR_DispatchBuiltin(-newf->first_statement);
        } else {
          // User function: enter normally.
          pr_xstatement = _PR_EnterFunction(fnum_callee);
        }
      } break;

      default:
        Print("PR_ExecuteProgram: opcode %d not yet implemented\n", op);
        _PR_StackTrace();
        pr_halted = TRUE;
        break;
    }
  }
}
