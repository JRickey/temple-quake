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
//   - File IO (PR_LoadProgs reading a real file from disk)
//   - Entity ops: LOAD/STORE_ENT/FLD/FNC, ADDRESS, STOREP_*, OP_STATE
//   - Vector arithmetic (MUL_V, ADD_V, SUB_V, EQ_V, NE_V, NOT_V)
//   - String compare (EQ_S, NE_S)
//   - OP_CALL* and the builtin dispatch — needs the builtin table
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

Bool          pr_halted = FALSE;       // set TRUE on OP_DONE
Bool          pr_runaway = FALSE;      // set TRUE on > 100k step limit

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

  // Byte-swap pass on tables (statements / globaldefs / fielddefs /
  // functions / globals) is a no-op on x86_64 since LittleLong is
  // identity. The pass is preserved-by-omission here; if porting to
  // a big-endian host, walk each table and apply LittleShort /
  // LittleLong per field.

  return TRUE;
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
      case OP_DONE:
        pr_xstatement = _PR_LeaveFunction();
        if (_pr_depth == exit_depth) {
          pr_halted = TRUE;
        }
        break;

      default:
        Print("PR_ExecuteProgram: opcode %d not yet implemented\n", op);
        _PR_StackTrace();
        pr_halted = TRUE;
        break;
    }
  }
}
