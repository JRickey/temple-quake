// Wad.HC — port of WinQuake/wad.c.
//
// WAD2 archive format: a fixed-size header, a flat lump-info table,
// and a packed bytes section. Quake uses one global WAD (gfx.wad) for
// HUD pictures and a few label assets; the BSP file embeds its own
// miptex WAD.
//
// File layout:
//
//   wadinfo_t       header at offset 0
//                     identification[4] = "WAD2"
//                     numlumps           little-endian I32
//                     infotableofs       little-endian I32 (byte offset
//                                        from start of file)
//   <bulk data>     lump bodies, packed back-to-back
//   lumpinfo_t[N]   info table at infotableofs:
//                     filepos   little-endian I32 (byte offset)
//                     disksize  little-endian I32
//                     size      little-endian I32 (uncompressed)
//                     type      U8 (TYP_*)
//                     compression U8 (CMP_*)
//                     pad1, pad2 U8 each
//                     name[16]  ASCII, NUL or space padded, lowercased
//
// Behavior gaps vs vanilla Quake (the file-loading half):
//
//   - W_LoadWadFile (the file-IO entry point) is stubbed. It logs and
//     returns. Real implementation needs COM_LoadHunkFile, which lands
//     when common.c's file IO is ported. Until then, tests + callers
//     should use W_LoadWadFromBuffer with a buffer they obtained
//     through TempleOS's own file APIs.
//
//   - LZSS decompression is not implemented (Quake never used it in
//     practice — every shipped lump is CMP_NONE). Z_DumpHeap level
//     code-paths.

#define CMP_NONE     0
#define CMP_LZSS     1

#define TYP_NONE     0
#define TYP_LABEL    1
#define TYP_LUMPY    64
#define TYP_PALETTE  64
#define TYP_QTEX     65
#define TYP_QPIC     66
#define TYP_SOUND    67
#define TYP_MIPTEX   68

class qpic_t {
  I32 width;
  I32 height;
  // Trailing variable-size pixel array. Quake declares `byte data[4]`
  // and indexes off `data` to cover the whole picture; we mirror with
  // a 4-byte minimum so member access stays valid, and callers reach
  // beyond via pointer arithmetic.
  U8 data[4];
};

class wadinfo_t {
  U8  identification[4];      // "WAD2"
  I32 numlumps;
  I32 infotableofs;
};

class lumpinfo_t {
  I32 filepos;
  I32 disksize;
  I32 size;                   // uncompressed
  U8  type;
  U8  compression;
  U8  pad1;
  U8  pad2;
  U8  name[16];               // NUL-padded after lowercase + space pad
};

I64         wad_numlumps = 0;
lumpinfo_t *wad_lumps = NULL;
U8         *wad_base = NULL;

// Endian helpers: LittleLong / LittleShort live in Common.HC, which
// sorts before Wad.HC in push order so they're already in scope.

// Lowercase + pad with NUL to exactly 16 bytes. Used for the name
// field on every lookup and on every lump in the loaded table so a
// 4-bytes-at-a-time compare is safe.
U0 W_CleanupName(U8 *in, U8 *out) {
  I64 i;
  I64 c;
  for (i = 0; i < 16; i++) {
    c = in[i];
    if (!c) {
      break;
    }
    if (c >= 'A' && c <= 'Z') {
      c = c + ('a' - 'A');
    }
    out[i] = c;
  }
  while (i < 16) {
    out[i] = 0;
    i++;
  }
}

U0 SwapPic(qpic_t *pic) {
  pic->width = LittleLong(pic->width);
  pic->height = LittleLong(pic->height);
}

// Initialize the global WAD state from a pre-loaded buffer. The
// buffer must remain live for the lifetime of WAD lookups (callers
// hold pointers into it via wad_base and wad_lumps).
//
// Returns TRUE on success, FALSE if the header is malformed.
Bool W_LoadWadFromBuffer(U8 *buf, I64 buflen) {
  if (!buf || buflen < sizeof(wadinfo_t)) {
    Print("W_LoadWadFromBuffer: buffer too small\n");
    return FALSE;
  }
  wad_base = buf;
  wadinfo_t *header = buf;
  if (header->identification[0] != 'W' ||
      header->identification[1] != 'A' ||
      header->identification[2] != 'D' ||
      header->identification[3] != '2') {
    Print("W_LoadWadFromBuffer: not a WAD2 file\n");
    wad_base = NULL;
    return FALSE;
  }
  wad_numlumps = LittleLong(header->numlumps);
  I64 infotableofs = LittleLong(header->infotableofs);
  if (infotableofs + wad_numlumps * sizeof(lumpinfo_t) > buflen) {
    Print("W_LoadWadFromBuffer: info table out of bounds\n");
    wad_base = NULL;
    wad_numlumps = 0;
    return FALSE;
  }
  wad_lumps = buf + infotableofs;
  // Walk the info table: byte-swap fields (no-op on x86_64) and
  // canonicalize names for fast lookup.
  I64 i;
  lumpinfo_t *lump;
  for (i = 0; i < wad_numlumps; i++) {
    lump = &wad_lumps[i];
    lump->filepos = LittleLong(lump->filepos);
    lump->size = LittleLong(lump->size);
    W_CleanupName(lump->name, lump->name);
    if (lump->type == TYP_QPIC) {
      SwapPic(buf + lump->filepos);
    }
  }
  return TRUE;
}

// File-IO entry: stub until common.c lands.
U0 W_LoadWadFile(U8 *filename) {
  Print("W_LoadWadFile: file IO not yet ported (filename=%s)\n", filename);
}

lumpinfo_t *W_GetLumpinfo(U8 *name) {
  U8 clean[16];
  W_CleanupName(name, clean);
  I64 i;
  lumpinfo_t *lump;
  for (i = 0; i < wad_numlumps; i++) {
    lump = &wad_lumps[i];
    // Name fields are 16 bytes NUL-padded; StrCmp ends at the first
    // NUL on either side which is fine for canonical names.
    if (!StrCmp(clean, lump->name)) {
      return lump;
    }
  }
  Print("W_GetLumpinfo: %s not found\n", name);
  return NULL;
}

U8 *W_GetLumpName(U8 *name) {
  lumpinfo_t *lump = W_GetLumpinfo(name);
  if (!lump) {
    return NULL;
  }
  return wad_base + lump->filepos;
}

U8 *W_GetLumpNum(I64 num) {
  if (num < 0 || num >= wad_numlumps) {
    Print("W_GetLumpNum: bad number\n");
    return NULL;
  }
  lumpinfo_t *lump = &wad_lumps[num];
  return wad_base + lump->filepos;
}
