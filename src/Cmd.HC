// Cmd.HC — port of WinQuake/cmd.c (subset).
//
// Ports the reusable command-system surface: tokenization, the
// command registry, argv/argc/args accessors, and a minimal
// ExecuteString that dispatches to a registered command or falls
// through to Cvar_Command. Buffered execution (Cbuf_*), built-in
// console commands (alias, echo, exec, stuffcmds), Cmd_ForwardToServer,
// Cmd_CheckParm, and parameter handling (com_argv) are deferred to
// later phases — they require file IO, sizebuf, host main-loop hooks,
// and command-line argument parsing we don't have yet.
//
// Replaces Bootstrap.HC stubs for Cmd_Argc / Cmd_Argv / Cmd_Exists.
// Sorts after Bootstrap.HC and before Cvar.HC so the real impls are
// in scope when Cvar.HC's RegisterVariable / Cvar_Command run.

#define MAX_ARGS  80

class cmd_function_t {
  cmd_function_t *next;
  U8 *name;
  U0 (*function)();          // xcommand_t — no args, called for execution
};

cmd_function_t *cmd_functions = NULL;

I64 cmd_argc = 0;
U8 *cmd_argv[MAX_ARGS];
U8 *cmd_args = NULL;
U8 *cmd_null_string = "";

// Static scratch for COM_Parse's return value. Quake uses a single
// `com_token` global and copies out into per-arg heap buffers.
U8 com_token[1024];

I64 Cmd_Argc() {
  return cmd_argc;
}

U8 *Cmd_Argv(I64 arg) {
  if (arg < 0 || arg >= cmd_argc) {
    return cmd_null_string;
  }
  return cmd_argv[arg];
}

U8 *Cmd_Args() {
  if (!cmd_args) {
    return cmd_null_string;
  }
  return cmd_args;
}

// COM_Parse-equivalent: read the next whitespace-separated token from
// `*data`, write it (NUL-terminated, ≤sizeof(com_token)-1 bytes) to
// `com_token`, and return the cursor advanced past the token. Returns
// NULL when the stream is exhausted.
//
// Behaviors mirroring Quake's COM_Parse:
//   - Skips spaces, tabs, CR. Newlines are consumed too (we use this
//     for cmd-line tokenization where Cmd_TokenizeString stops at \n
//     before calling here).
//   - "//" line comments skip to the next \n (then loop).
//   - Quoted strings ("...") are taken literally up to the closing ".
//   - Otherwise: read bytes until whitespace or NUL.
U8 *_Cmd_COM_Parse(U8 *data) {
  // I64 (not U8) for char locals — HolyC warns about 64-bit reg var
  // when storage is narrower than the register width. Char comparisons
  // still fit since we only handle ASCII bytes.
  I64 len = 0;
  I64 c;
  com_token[0] = 0;
  if (!data) {
    return NULL;
  }
skipwhite:
  while (TRUE) {
    c = *data;
    if (c == 0) {
      return NULL;
    }
    if (c > ' ') {
      break;
    }
    data++;
  }
  // Skip "// line comment"
  if (c == '/' && data[1] == '/') {
    while (*data && *data != '\n') {
      data++;
    }
    goto skipwhite;
  }
  // Quoted string.
  if (c == '"') {
    data++;
    while (TRUE) {
      c = *data;
      data++;
      if (c == '"' || !c) {
        com_token[len] = 0;
        return data;
      }
      if (len < 1023) {
        com_token[len] = c;
        len++;
      }
    }
  }
  // Bare token: read until whitespace or NUL.
  while (TRUE) {
    c = *data;
    if (c <= ' ') {
      break;
    }
    if (len < 1023) {
      com_token[len] = c;
      len++;
    }
    data++;
  }
  com_token[len] = 0;
  return data;
}

U0 Cmd_TokenizeString(U8 *text) {
  I64 i;
  for (i = 0; i < cmd_argc; i++) {
    Z_Free(cmd_argv[i]);
    cmd_argv[i] = NULL;
  }
  cmd_argc = 0;
  cmd_args = NULL;

  while (TRUE) {
    // Skip whitespace up to a newline.
    while (*text && *text <= ' ' && *text != '\n') {
      text++;
    }
    if (*text == '\n') {
      text++;
      break;
    }
    if (!*text) {
      return;
    }
    // After arg[0] we record the unparsed remainder as cmd_args, so
    // command handlers can grab the original string after the verb.
    if (cmd_argc == 1) {
      cmd_args = text;
    }
    text = _Cmd_COM_Parse(text);
    if (!text) {
      return;
    }
    if (cmd_argc < MAX_ARGS) {
      I64 toklen = Q_strlen(com_token) + 1;
      cmd_argv[cmd_argc] = Z_Malloc(toklen);
      Q_strcpy(cmd_argv[cmd_argc], com_token);
      cmd_argc++;
    }
  }
}

U0 Cmd_AddCommand(U8 *cmd_name, U0 (*function)()) {
  cmd_function_t *cmd;

  // TODO: reject collision with a registered cvar. Cvar.HC sorts
  // AFTER Cmd.HC in our push order, so Cvar_VariableString isn't in
  // scope here yet. Either reorder or rebind via a sequencing file
  // once the host resolver flags the cycle. For now we don't guard.

  // Reject duplicate command.
  cmd = cmd_functions;
  while (cmd) {
    if (!Q_strcmp(cmd_name, cmd->name)) {
      Con_Printf("Cmd_AddCommand: name already defined\n");
      return;
    }
    cmd = cmd->next;
  }

  // Real Quake uses Hunk_Alloc; we use MAlloc until zone.c lands.
  cmd = MAlloc(sizeof(cmd_function_t));
  cmd->name = cmd_name;
  cmd->function = function;
  cmd->next = cmd_functions;
  cmd_functions = cmd;
}

Bool Cmd_Exists(U8 *cmd_name) {
  cmd_function_t *cmd = cmd_functions;
  while (cmd) {
    if (!Q_strcmp(cmd_name, cmd->name)) {
      return TRUE;
    }
    cmd = cmd->next;
  }
  return FALSE;
}

U8 *Cmd_CompleteCommand(U8 *partial) {
  I64 len = Q_strlen(partial);
  if (!len) {
    return NULL;
  }
  cmd_function_t *cmd = cmd_functions;
  while (cmd) {
    if (!Q_strncmp(partial, cmd->name, len)) {
      return cmd->name;
    }
    cmd = cmd->next;
  }
  return NULL;
}

// Minimal ExecuteString: tokenize, look up by argv[0], dispatch to
// the registered handler. Returns nothing (matches Quake's signature).
//
// TODO: fall through to Cvar_Command for var reads/writes if no
// command matches. Same push-order constraint as Cmd_AddCommand —
// Cvar.HC isn't yet in scope when Cmd.HC compiles.
U0 Cmd_ExecuteString(U8 *text) {
  Cmd_TokenizeString(text);
  if (cmd_argc == 0) {
    return;
  }
  cmd_function_t *cmd = cmd_functions;
  while (cmd) {
    if (!Q_strcmp(cmd_argv[0], cmd->name)) {
      cmd->function();
      return;
    }
    cmd = cmd->next;
  }
  Con_Printf("Unknown command\n");
}
