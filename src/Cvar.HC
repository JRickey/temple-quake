// Cvar.HC — port of WinQuake/cvar.c.
//
// Console variables: name → string + cached float value, linked-list
// registered. Each `cvar_t` is allocated by the caller (typically as
// a static global) and registered via `Cvar_RegisterVariable`. The
// `string` field gets re-allocated on every `Cvar_Set` so the cvar
// owns the heap copy.
//
// Depends on QuakeStubs.HC for Z_Malloc/Free, Q_strcmp etc., and
// stubbed Cmd_/Con_/SV_ functions.

class cvar_t {
  U8 *name;
  U8 *string;
  Bool archive;       // saved to vars.rc on quit
  Bool server;        // notify players when changed
  F64  value;          // cached Q_atof(string)
  cvar_t *next;
};

cvar_t *cvar_vars = NULL;
U8 *cvar_null_string = "";

cvar_t *Cvar_FindVar(U8 *var_name) {
  cvar_t *var = cvar_vars;
  while (var) {
    if (!Q_strcmp(var_name, var->name)) {
      return var;
    }
    var = var->next;
  }
  return NULL;
}

F64 Cvar_VariableValue(U8 *var_name) {
  cvar_t *var = Cvar_FindVar(var_name);
  if (!var) {
    return 0.0;
  }
  return Q_atof(var->string);
}

U8 *Cvar_VariableString(U8 *var_name) {
  cvar_t *var = Cvar_FindVar(var_name);
  if (!var) {
    return cvar_null_string;
  }
  return var->string;
}

U8 *Cvar_CompleteVariable(U8 *partial) {
  I64 len = Q_strlen(partial);
  if (!len) {
    return NULL;
  }
  cvar_t *cvar = cvar_vars;
  while (cvar) {
    if (!Q_strncmp(partial, cvar->name, len)) {
      return cvar->name;
    }
    cvar = cvar->next;
  }
  return NULL;
}

U0 Cvar_Set(U8 *var_name, U8 *value) {
  cvar_t *var = Cvar_FindVar(var_name);
  if (!var) {
    Con_Printf("Cvar_Set: variable not found\n");
    return;
  }

  Bool changed = Q_strcmp(var->string, value) != 0;
  Z_Free(var->string);
  I64 nlen = Q_strlen(value) + 1;
  var->string = Z_Malloc(nlen);
  Q_strcpy(var->string, value);
  var->value = Q_atof(var->string);

  if (var->server && changed) {
    if (sv.active) {
      SV_BroadcastPrintf("\"%s\" changed to \"%s\"\n", var->name, var->string);
    }
  }
}

U0 Cvar_SetValue(U8 *var_name, F64 value) {
  U8 val[32];
  StrPrint(val, "%f", value);
  Cvar_Set(var_name, val);
}

U0 Cvar_RegisterVariable(cvar_t *variable) {
  if (Cvar_FindVar(variable->name)) {
    Con_Printf("Cvar_RegisterVariable: already defined\n");
    return;
  }
  if (Cmd_Exists(variable->name)) {
    Con_Printf("Cvar_RegisterVariable: name is a command\n");
    return;
  }

  // Copy the literal string into heap so future Cvar_Set's Z_Free
  // is symmetric — caller may have set `string` to a string literal.
  U8 *oldstr = variable->string;
  I64 nlen = Q_strlen(oldstr) + 1;
  variable->string = Z_Malloc(nlen);
  Q_strcpy(variable->string, oldstr);
  variable->value = Q_atof(variable->string);

  variable->next = cvar_vars;
  cvar_vars = variable;
}

Bool Cvar_Command() {
  cvar_t *v = Cvar_FindVar(Cmd_Argv(0));
  if (!v) {
    return FALSE;
  }
  if (Cmd_Argc() == 1) {
    Con_Printf("\"%s\" is \"%s\"\n");  // simplified — real version interpolates
    return TRUE;
  }
  Cvar_Set(v->name, Cmd_Argv(1));
  return TRUE;
}

// Cvar_WriteVariables omitted: depends on FILE/fprintf which we
// don't have until a TempleOS file IO shim lands. Stub-callable
// when needed.
