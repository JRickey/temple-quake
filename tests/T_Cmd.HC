// T_Cmd.HC — battery for src/Cmd.HC.
//
// Tests the four pieces ported so far: tokenization, registration,
// existence/lookup, prefix completion, and ExecuteString dispatch.

I64 _t_cmd_handler_called = 0;
I64 _t_cmd_other_handler_called = 0;

U0 _T_cmd_handler() {
  _t_cmd_handler_called++;
}

U0 _T_cmd_other_handler() {
  _t_cmd_other_handler_called++;
}

// ---- Cmd_TokenizeString: empty / whitespace / single / multi ----
Cmd_TokenizeString("");
ASSERT_EQ(Cmd_Argc(), 0, "tokenize_empty_argc");

Cmd_TokenizeString("    \t  ");
ASSERT_EQ(Cmd_Argc(), 0, "tokenize_whitespace_only");

Cmd_TokenizeString("foo");
ASSERT_EQ(Cmd_Argc(), 1, "tokenize_single_argc");
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "foo"), 0, "tokenize_single_arg0");

Cmd_TokenizeString("set r_draworder 1");
ASSERT_EQ(Cmd_Argc(), 3, "tokenize_three_argc");
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "set"), 0, "tokenize_three_arg0");
ASSERT_EQ(Q_strcmp(Cmd_Argv(1), "r_draworder"), 0, "tokenize_three_arg1");
ASSERT_EQ(Q_strcmp(Cmd_Argv(2), "1"), 0, "tokenize_three_arg2");

// Out-of-range argv → empty string (not NULL — Quake's invariant)
ASSERT_EQ(Q_strcmp(Cmd_Argv(99), ""), 0, "argv_out_of_range_empty");

// ---- Quoted strings inside a command ----
Cmd_TokenizeString("echo \"hello world\"");
ASSERT_EQ(Cmd_Argc(), 2, "tokenize_quoted_argc");
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "echo"), 0, "tokenize_quoted_arg0");
ASSERT_EQ(Q_strcmp(Cmd_Argv(1), "hello world"), 0, "tokenize_quoted_arg1");

// ---- Line-comment skip ----
Cmd_TokenizeString("alias foo bar // ignored tail");
ASSERT_EQ(Cmd_Argc(), 3, "tokenize_with_line_comment");
ASSERT_EQ(Q_strcmp(Cmd_Argv(2), "bar"), 0, "tokenize_arg_before_comment");

// ---- Newline terminates a command ----
Cmd_TokenizeString("first one\nsecond two");
ASSERT_EQ(Cmd_Argc(), 2, "tokenize_stops_at_newline");
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "first"), 0, "tokenize_first_command_v0");
ASSERT_EQ(Q_strcmp(Cmd_Argv(1), "one"), 0, "tokenize_first_command_v1");

// ---- Cmd_Args: text after argv[0] ----
Cmd_TokenizeString("say hello there friend");
ASSERT_EQ(Cmd_Argc(), 4, "tokenize_args_argc");
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "say"), 0, "tokenize_args_verb");
// Cmd_Args should point to "hello there friend" (rest of command).
ASSERT_EQ(Q_strncmp(Cmd_Args(), "hello there friend", 18), 0, "tokenize_args_rest");

// ---- AddCommand / Exists / lookup ----
Cmd_AddCommand("smoke_cmd", &_T_cmd_handler);
ASSERT_EQ(Cmd_Exists("smoke_cmd") == TRUE, 1, "cmd_exists_after_add");
ASSERT_EQ(Cmd_Exists("nonexistent") == FALSE, 1, "cmd_exists_negative");

// ---- AddCommand idempotency (rejects duplicates) ----
Cmd_AddCommand("smoke_cmd", &_T_cmd_other_handler);   // should NOT replace
Cmd_TokenizeString("smoke_cmd");
Cmd_ExecuteString("smoke_cmd");
ASSERT_EQ(_t_cmd_handler_called, 1, "duplicate_add_keeps_first");
ASSERT_EQ(_t_cmd_other_handler_called, 0, "duplicate_add_does_not_replace");

// ---- ExecuteString dispatches with args ----
_t_cmd_handler_called = 0;
Cmd_AddCommand("other_cmd", &_T_cmd_other_handler);
Cmd_ExecuteString("other_cmd arg1 arg2");
ASSERT_EQ(_t_cmd_other_handler_called, 1, "execute_dispatches_other");
// argv[1] / argv[2] visible from inside the handler? Verified
// indirectly: handler can access Cmd_Argv(...). We re-check from
// here since ExecuteString just returned and globals persist.
ASSERT_EQ(Q_strcmp(Cmd_Argv(0), "other_cmd"), 0, "execute_argv0");
ASSERT_EQ(Q_strcmp(Cmd_Argv(1), "arg1"), 0, "execute_argv1");
ASSERT_EQ(Q_strcmp(Cmd_Argv(2), "arg2"), 0, "execute_argv2");

// ---- CompleteCommand: prefix lookup + miss ----
ASSERT_EQ(Q_strcmp(Cmd_CompleteCommand("smo"), "smoke_cmd"), 0, "complete_prefix");
ASSERT_EQ(Cmd_CompleteCommand("xyzzy") == NULL, 1, "complete_no_match");
ASSERT_EQ(Cmd_CompleteCommand("") == NULL, 1, "complete_empty");

// (Unknown-command + cvar fall-through is deferred — Cvar.HC pushes
// after Cmd.HC, so Cvar_Command isn't in scope when Cmd.HC compiles.
// Will revisit once the host resolver flags push-order issues and we
// either reorder or sequence the files explicitly.)
Cmd_ExecuteString("never_registered");  // must not crash; prints "Unknown command\n"

TEST_SUMMARY;
