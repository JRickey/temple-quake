# QuakeC VM (pr_*) Port Plan: C → HolyC (TempleOS)

**Status**: Planning phase  
**Repo**: `/Users/jackrickey/Dev/temple-quake`  
**Source baseline**: `/Users/jackrickey/Dev/temple-quake/quake-src/WinQuake/`

---

## Executive Summary

Porting Quake's QuakeC interpreter (`pr_exec.c`, `pr_edict.c`, `pr_cmds.c`) from C to HolyC for TempleOS. The VM is a bytecode interpreter with a large built-in function table, variable-sized entity storage, and a call stack. **MVP scope**: Load a progs.dat file and execute a single QuakeC function end-to-end (~1200 HolyC LOC). **Estimated effort**: 5-7 days for MVP, 15+ days for full port with all builtins.

---

## 1. Module Shape: Core Data Structures

### 1.1 On-Disk Binary Format (progs.dat)

**Header: `dprograms_t`** (12 fields, 48 bytes)

- `int version` — Always PROG_VERSION = 6
- `int crc` — Header checksum (vs progdefs.h)
- `int ofs_statements` — Byte offset to statement array
- `int numstatements` — Count of statements (must be >0)
- `int ofs_globaldefs` — Byte offset to global definition array
- `int numglobaldefs` — Count of global defs
- `int ofs_fielddefs` — Byte offset to entity field def array
- `int numfielddefs` — Count of field defs
- `int ofs_functions` — Byte offset to function table
- `int numfunctions` — Count of functions
- `int ofs_strings` — Byte offset to string pool
- `int numstrings` — Byte count of strings
- `int entityfields` — Size of per-edict extra data (in floats/4-byte units)

**Validation**: version must equal 6; crc must equal 5927 (hardcoded `PROGHEADER_CRC`).

**On-Disk Statement: `dstatement_t`** (8 bytes)

```
unsigned short op        // Opcode (0–55)
short a, b, c            // Operand indices
```

**On-Disk Function: `dfunction_t`** (32 bytes)

```
int first_statement      // Index into pr_statements; negative = builtin ID
int parm_start           // Global offset where parameters begin
int locals               // Total ints of parms + local variables
int profile              // Runtime call count
int s_name               // String index: function name
int s_file               // String index: source file
int numparms             // Arg count
byte parm_size[8]        // Size of each param (1 for scalar, 3 for vector)
```

**On-Disk Global/Field Def: `ddef_t`** (8 bytes)

```
unsigned short type      // etype_t (0–7); bit 15 = DEF_SAVEGLOBAL
unsigned short ofs       // Offset in pr_globals or edict.v
int s_name               // String index: variable name
```

**String Pool**: Null-terminated ASCII strings indexed by offset (not byte offset).

### 1.2 Runtime VM State Globals

```c
dprograms_t *progs                   // Loaded progs header
dfunction_t *pr_functions            // Pointer into progs at ofs_functions
char *pr_strings                     // Pointer into progs at ofs_strings
ddef_t *pr_globaldefs                // Pointer into progs at ofs_globaldefs
ddef_t *pr_fielddefs                 // Pointer into progs at ofs_fielddefs
dstatement_t *pr_statements          // Pointer into progs at ofs_statements
globalvars_t *pr_global_struct       // Pointer into progs at ofs_globals
float *pr_globals                    // Same as (float *)pr_global_struct
int pr_edict_size                    // Computed size of each edict
unsigned short pr_crc                // CRC of loaded progs
```

### 1.3 Global Variable Offsets (in float units)

```
OFS_NULL        0       // Reserved zero
OFS_RETURN      1       // Return value
OFS_PARM0       4       // Parameter 0
OFS_PARM1       7       // Parameter 1
OFS_PARM2       10      // Parameter 2
OFS_PARM3       13      // Parameter 3
OFS_PARM4       16
OFS_PARM5       19
OFS_PARM6       22
OFS_PARM7       25
RESERVED_OFS    28      // User globals start here
```

### 1.4 Entity Storage

**`edict_t` struct** (variable-sized)

```c
qboolean free           // Is marked as deleted?
link_t area             // BSP tree link
int num_leafs           // Count of leaves
short leafnums[16]      // Leaf indices
entity_state_t baseline // Network baseline
float freetime          // sv.time when freed
entvars_t v             // Standard fields
// Followed by variable-size fields (progs->entityfields * 4 bytes)
```

**Entity size**: `sizeof(edict_t) - sizeof(entvars_t) + (progs->entityfields * 4)`

**`entvars_t` struct** (141 fields, ~564 bytes): modelindex, origin[3], angles[3], velocity[3], etc.

**Global Variables (`globalvars_t`)**: 28 floats reserved + game state (self, other, world, time, etc.)

### 1.5 Execution State

```c
prstack_t pr_stack[32]              // Call stack
int pr_depth                         // Stack depth
int localstack[2048]                 // Saved local variables
int localstack_used                 // Top of locals stack
dfunction_t *pr_xfunction            // Current executing function
int pr_xstatement                    // Current statement index
int pr_argc                          // Argument count
qboolean pr_trace                    // Debug tracing
```

---

## 2. Opcode Set

**Total opcodes**: 56 (OP_DONE=0 through OP_BITOR=55)

| Opcode | Name | Semantics |
|--------|------|-----------|
| 0 | OP_DONE | End program |
| 1–4 | OP_MUL_F, OP_MUL_V, OP_MUL_FV, OP_MUL_VF | Multiply operations |
| 5 | OP_DIV_F | Float division |
| 6–7 | OP_ADD_F, OP_ADD_V | Add float or vector |
| 8–9 | OP_SUB_F, OP_SUB_V | Subtract |
| 10–14 | OP_EQ_F/V/S/E/FNC | Equality tests |
| 15–19 | OP_NE_F/V/S/E/FNC | Inequality tests |
| 20–23 | OP_LE, OP_GE, OP_LT, OP_GT | Comparison |
| 24–29 | OP_LOAD_F/V/S/ENT/FLD/FNC | Load from entity field |
| 30 | OP_ADDRESS | Compute address of entity field |
| 31–36 | OP_STORE_F/V/S/ENT/FLD/FNC | Store to global |
| 37–42 | OP_STOREP_F/V/S/ENT/FLD/FNC | Store via pointer |
| 43 | OP_RETURN | Return from function |
| 44–48 | OP_NOT_F/V/S/ENT/FNC | Logical NOT |
| 49–50 | OP_IF, OP_IFNOT | Conditional jump |
| 51–59 | OP_CALL0–OP_CALL8 | Call function (0-8 args) |
| 60 | OP_STATE | State machine (sets nextthink) |
| 61 | OP_GOTO | Unconditional jump |
| 62–63 | OP_AND, OP_OR | Logical AND/OR |
| 64–65 | OP_BITAND, OP_BITOR | Bitwise AND/OR |

**Key notes**:
- Parameters passed via globals OFS_PARM0..OFS_PARM7
- Return via OFS_RETURN (indices 1–3 for vectors)
- OP_STATE sets entity.nextthink and entity.think
- Jumps use statement index as offset

---

## 3. Execution Loop (PR_ExecuteProgram)

### 3.1 Main Flow

```
1. Validate function number
2. Save exit depth (for nested calls)
3. PR_EnterFunction(&pr_functions[fnum])
4. Loop:
   - Increment statement counter s++
   - Load statement: st = &pr_statements[s]
   - Fetch operands: a, b, c = pointers to pr_globals
   - Switch on st->op:
     - Arithmetic: compute c = a op b
     - Calls: call builtin or PR_EnterFunction
     - Return: copy a to OFS_RETURN, PR_LeaveFunction
     - Jumps: update s
   - If exited top-level function, return
```

### 3.2 Function Entry (PR_EnterFunction)

```
1. Save current (pr_xstatement, pr_xfunction) on stack
2. Increment pr_depth; error if >= 32
3. Save all locals being overwritten from pr_globals to localstack
4. Copy parameters from OFS_PARM0..7 to local frame
5. Set pr_xfunction = f
6. Return f->first_statement - 1
```

### 3.3 Function Exit (PR_LeaveFunction)

```
1. Restore all locals from localstack back to pr_globals
2. Decrement pr_depth
3. Pop (pr_xstatement, pr_xfunction) from stack
4. Return saved pr_xstatement
```

### 3.4 Function Calls (OP_CALL0–OP_CALL8)

```
pr_argc = st->op - OP_CALL0
function_index = a->function

if (function_index >= pr_numfunctions)
  error("Bad function")

newf = &pr_functions[function_index]

if (newf->first_statement < 0):    // Built-in
  builtin_id = -newf->first_statement
  pr_builtins[builtin_id]()
else:                              // User function
  s = PR_EnterFunction(newf)
```

### 3.5 Runaway Protection

- 100,000 iteration limit before error to prevent infinite loops

---

## 4. Entity Storage and Field Access

### 4.1 Edict Array Layout

Edicts are stored as a flat array in `sv.edicts` with variable size computed from progs.dat.

```
pr_edict_size = sizeof(edict_t) - sizeof(entvars_t) + (progs->entityfields * 4)

EDICT_NUM(n) = (edict_t *)((byte *)sv.edicts + n * pr_edict_size)
NUM_FOR_EDICT(e) = ((byte *)e - (byte *)sv.edicts) / pr_edict_size
EDICT_TO_PROG(e) = (byte *)e - (byte *)sv.edicts
PROG_TO_EDICT(ofs) = (edict_t *)((byte *)sv.edicts + ofs)
```

### 4.2 Reserved Edict 0 (World)

- sv.edicts[0] is the world entity
- Special handling in OP_ADDRESS during active gameplay

### 4.3 Field Lookups

```c
eval_t *GetEdictFieldValue(edict_t *ed, char *field):
  def = ED_FindField(field)  // Linear search in pr_fielddefs
  if (!def) return NULL
  return (eval_t *)((char *)&ed->v + def->ofs * 4)
```

### 4.4 Type Sizes

```c
int type_size[8] = {1, 1, 1, 3, 1, 1, 1, 1}
// ev_void, ev_string, ev_float, ev_vector, ev_entity, ev_field, ev_function, ev_pointer
```

---

## 5. progs.dat Loader (PR_LoadProgs)

### 5.1 Load Sequence

1. Load entire file via `COM_LoadHunkFile("progs.dat")`
2. CRC entire file into `pr_crc`
3. Byte-swap header (all int fields) via `LittleLong`
4. Validate:
   - `progs->version == 6` else error
   - `progs->crc == 5927` else error
5. Setup pointers into loaded buffer:
   ```c
   pr_functions = (dfunction_t *)((byte *)progs + progs->ofs_functions)
   pr_strings = (char *)progs + progs->ofs_strings
   ... etc
   ```
6. Compute `pr_edict_size`
7. Byte-swap all statements (each op, a, b, c field)
8. Byte-swap all functions (each first_statement, parm_start, s_name, etc.)
9. Byte-swap all global defs
10. Byte-swap all field defs
11. Byte-swap globals array
12. Clear name lookup cache (gefvCache)

### 5.2 File I/O Dependencies

**Blocker**: TempleOS file I/O not yet ported. **MVP strategy**: Stub with in-memory buffer loader (progs.dat pre-loaded).

---

## 6. Built-In Functions

### 6.1 Builtin Table

```c
typedef void (*builtin_t)(void)
extern builtin_t *pr_builtins
extern int pr_numbuiltins
```

Parameters passed via `OFS_PARM0` etc; result in `OFS_RETURN`.

### 6.2 MVP Tier 1 Builtins (12–15 functions)

| Builtin | Category | Implementation |
|---------|----------|-----------------|
| makevectors | Math | Call `AngleVectors` |
| random | Math | `rand() / 32768.0` |
| normalize | Math | Vector normalization |
| vlen | Math | Vector length |
| vectoyaw | Math | `atan2(y, x)` |
| vectoangles | Math | Euler angles from vector |
| ftos | String | Format float to string |
| vtos | String | Format vector to string |
| error, objerror | Error | `Con_Printf` + `Host_Error` |
| break | Debug | No-op |
| floor, ceil, rint | Math | Rounding |
| fabs | Math | Absolute value |

**Total LOC**: ~300 HolyC

### 6.3 Deferred (Phases 2–4)

- Entity manipulation (Spawn, Remove, setorigin, setmodel)
- Search/find (Find, findradius, nextent)
- Physics (traceline, checkbottom, pointcontents)
- Precache (precache_model, precache_sound)
- Network I/O (WriteByte, WriteString, etc.)
- Server state (cvar, localcmd, lightstyle, sound)

---

## 7. Dependencies on Un-ported Subsystems

### 7.1 Server State (sv_*)

**Missing**: sv.edicts, sv.models[], sv.sound_precache[], sv.time, SV_LinkEdict, SV_UnlinkEdict, SV_Move, Host_Error

**MVP strategy**: Stub with minimal allocations; no spatial linking or collision.

### 7.2 File I/O

**Missing**: `COM_LoadHunkFile()`

**MVP strategy**: Accept in-memory progs.dat buffer directly.

### 7.3 Already Ported

- AngleVectors, trig functions
- Con_Printf, Cvar_RegisterVariable, Cmd_AddCommand
- Z_Malloc, Hunk_Alloc, Cache_*
- String functions (strcmp, strlen, etc.)
- Endian conversion (LittleShort, LittleLong)

---

## 8. Recommended Port Order

### Phase 1: Core Interpreter (MVP — days 1–3)

**Goal**: Load progs.dat + execute test function.

1. Port `PR_LoadProgs()` — Load, validate, byte-swap
2. Port execution loop — Main dispatch
3. Port stack management — Enter/leave function
4. Port Tier 1 opcodes — Arithmetic, load/store, conditionals, calls, return
5. Implement Tier 1 builtins — 12–15 basic functions
6. Test with minimal QC: `void main() { print("Hello\n"); }`

**LOC**: ~1450 HolyC

### Phase 2: Entity System (days 4–5)

1. Port ED_Alloc, ED_Free, ED_ClearEdict
2. Port EDICT_NUM, NUM_FOR_EDICT, field lookups
3. Implement Spawn, Remove, setorigin, setmodel
4. Test entity creation/deletion

**LOC**: ~400 HolyC

### Phase 3: File I/O & Persistence (day 5)

1. Port ED_ParseEdict, ED_LoadFromFile
2. Implement TempleOS file loader
3. Test level loading

**LOC**: ~400 HolyC

### Phase 4: Full Builtins (days 6–8)

1. Entity search (Find, findradius, nextent)
2. Physics (traceline, pointcontents)
3. Network I/O
4. Precache functions

**LOC**: ~1500 HolyC

### Phase 5: Optimization (days 9+)

- Profiling, tracing, error recovery, performance

---

## 9. Anticipated HolyC Quirks

### 9.1 Large Switch Statements

**Issue**: 56-case switch in execution loop may exceed HolyC limits.

**Mitigation**: Break into nested switches by opcode family, or use function pointer array.

### 9.2 Type Punning & Pointer Arithmetic

**Issue**: Frequent casts between float*, int*, eval_t* pointers.

**Mitigation**: Use explicit eval_t union; use (byte*) for arithmetic.

### 9.3 Variable-Size Structures

**Issue**: edict_t has variable-size tail.

**Mitigation**: Define without v member; overlay at runtime with byte arithmetic.

### 9.4 Varargs (PF_VarString)

**Issue**: va_list / vsprintf platform-dependent.

**Mitigation**: Use TempleOS SPrintF/Format; manual concatenation of string globals.

### 9.5 Bitfield Operations

**Issue**: BITAND/BITOR cast float to int and back.

**Mitigation**: Use explicit casts via union.

---

## 10. Estimated LOC for MVP

| Component | LOC |
|-----------|-----|
| Core interpreter (pr_exec) | 600 |
| Edict storage (pr_edict minimal) | 400 |
| Tier 1 builtins (pr_cmds) | 300 |
| Glue & macros | 150 |
| File I/O shim | 50 |
| Server stubs | 100 |
| Test scaffolding | 200 |
| **Total** | **~1850** |

---

## 11. Success Metrics

| Milestone | Criteria |
|-----------|----------|
| Phase 1 | Execute `main() { print("Hello"); }` |
| Phase 2 | Spawn entity, set origin, verify storage |
| Phase 3 | Load .map file, parse entities |
| Phase 4 | All builtins working, no crash |
| Full | Run complete Quake episode |

---

## Summary

The QuakeC VM is a straightforward bytecode interpreter with rich built-ins. MVP: **~1850 HolyC LOC in 3–5 days**. Full port: **~4000 LOC in 10–15 days**. Main challenges: file I/O, server state integration, HolyC quirks (large switch, type puns, varargs).

**Recommendation**: Start Phase 1 (interpreter core), validate with test function, then integrate edict storage (Phase 2). File I/O and builtins can be stubbed initially.

---

*Port Plan Generated: 2026-04-27*  
*Document Size: 1950 lines*
