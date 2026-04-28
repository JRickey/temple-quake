// T_PrInject.HC — round-trip test for PR_InjectChunk + PR_InjectFinish.
//
// We don't have a way to run the actual host injector (scripts/
// inject-progs.py) inside the test framework — it needs the daemon
// idle and the VM filesystem writable across a separate `send.py`
// invocation. Instead, we exercise the same code path here:
//
//   1. Call PR_InjectChunk in-process with a known hex string,
//      simulating what the host script would do.
//   2. Call PR_InjectFinish to write the buffer to disk.
//   3. Load it back via PR_LoadProgsFromFile and verify the
//      header round-trips.
//
// This validates the hex decoder + the FileWrite/FileRead glue
// without binary-over-serial transport. The host script's
// behavior is mechanical concatenation; if the in-process round-
// trip works, the real qwprogs.dat injection works too.

// ============================================================
// Build a 256-byte synthetic progs in hex form
// ============================================================
//
// Header-only, just enough that PR_LoadProgsFromBuffer accepts
// it. We only validate version + numglobals on read-back.

// Layout (bytes, little-endian):
//   0x00..03  version    = 6
//   0x04..07  crc        = 0
//   0x08..0B  ofs_stmts  = 60
//   0x0C..0F  numstmts   = 1
//   0x10..13  ofs_globaldefs = 68
//   0x14..17  numgldfs   = 0
//   0x18..1B  ofs_fielddefs  = 68
//   0x1C..1F  numfielddefs   = 0
//   0x20..23  ofs_funcs  = 68
//   0x24..27  numfuncs   = 1
//   0x28..2B  ofs_strings = 104
//   0x2C..2F  numstrings = 1
//   0x30..33  ofs_globals = 105
//   0x34..37  numglobals = 8
//   0x38..3B  entityfields = 0
//
// Pad to 256 bytes total. Every byte becomes 2 hex chars.

// Inject the header (60 bytes) as one chunk. Each 8 hex chars =
// one little-endian i32 of the dprograms_t struct.
//   version=6, crc=0, ofs_stmts=60(3C), numstmts=1,
//   ofs_globaldefs=68(44), numgldfs=0, ofs_fielddefs=68, numfd=0,
//   ofs_funcs=68, numfuncs=1, ofs_strings=104(68), numstrings=1,
//   ofs_globals=105(69), numglobals=8, entityfields=0
PR_InjectChunk("06000000000000003c000000010000004400000000000000440000000000000044000000010000006800000001000000690000000800000000000000", 0, 60);

// Statements at offset 60 — one OP_DONE (op=0, a=b=c=0), 8 bytes
PR_InjectChunk("0000000000000000", 60, 8);

// Functions at offset 68 — one dfunction_t (36 bytes), all-zero
// (first_statement=0 = sentinel). 36 bytes = 72 hex chars.
PR_InjectChunk("000000000000000000000000000000000000000000000000000000000000000000000000", 68, 36);

// Strings at offset 104 — single NUL byte
PR_InjectChunk("00", 104, 1);

// Globals at offset 105 — 8 zero slots = 32 bytes (64 hex chars)
PR_InjectChunk("0000000000000000000000000000000000000000000000000000000000000000", 105, 32);

ASSERT_EQ(_pr_inject_len, 137, "inject.buffer_len");

// Write to disk. TempleOS's FileWrite returns truthy-but-not-1
// on success, so we just check the call doesn't return 0.
Bool _inj_ok = PR_InjectFinish("::/Tmp/T_PrInject.dat");
ASSERT_EQ(_inj_ok != 0, 1, "inject.finish_writes");

// _pr_inject_len should reset to 0 after finish
ASSERT_EQ(_pr_inject_len, 0, "inject.length_resets");

// Load back through the existing file IO path
ASSERT_EQ(PR_LoadProgsFromFile("::/Tmp/T_PrInject.dat") == TRUE, 1,
          "inject.load_from_file");
ASSERT_EQ(pr_progs->version,    6, "inject.version_round_trips");
ASSERT_EQ(pr_progs->numglobals, 8, "inject.numglobals_round_trips");
ASSERT_EQ(pr_progs->numfunctions, 1, "inject.numfunctions_round_trips");

// Bytecode round-trip: execute the (sentinel) function 0 — should
// halt cleanly on OP_DONE.
PR_ExecuteProgram(0);
ASSERT_EQ(pr_halted == TRUE, 1, "inject.exec_after_load");
