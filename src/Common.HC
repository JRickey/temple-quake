// Common.HC — port of WinQuake/common.c (subset).
//
// What's covered:
//   - Endian helpers: LittleLong / LittleShort / BigLong / BigShort /
//     LittleFloat / BigFloat. TempleOS is x86_64, so the Little*
//     forms are identity; the Big* forms swap bytes (rarely used,
//     kept for protocol completeness).
//   - sizebuf_t + SZ_Alloc / SZ_Free / SZ_Clear / SZ_GetSpace /
//     SZ_Write / SZ_Print (the variable-size buffer used by the
//     network protocol and a few message-encoding paths).
//   - MSG_Write* + MSG_Read* (the message codec — Char/Byte/Short/
//     Long/Float/String + the position/angle helpers that scale
//     to network resolution).
//   - link_t doubly-linked list primitives — used by edicts.
//   - COM_Parse + com_token (canonical tokenizer; the cmd-system
//     keeps an internal copy until we converge them).
//   - va() — printf-into-a-static-buffer.
//   - Path helpers: COM_SkipPath, COM_StripExtension, COM_FileBase,
//     COM_DefaultExtension.
//
// Deferred:
//   - PAK file loading
//   - File IO (COM_OpenFile / COM_LoadHunkFile / COM_LoadFile / etc.)
//   - COM_InitArgv + com_argc/com_argv + COM_CheckParm
//   - Q_MAXCHAR / Q_MININT etc. constants — add when a caller asks

#define MAX_OSPATH    128
#define MAX_NUM_ARGVS 50

// On x86_64 every multi-byte int is already little-endian.
I32 LittleLong(I32 v) { return v; }
I16 LittleShort(I16 v) { return v; }
F64 LittleFloat(F64 v) { return v; }

I32 BigLong(I32 v) {
  return ((v & 0xFF) << 24)
       | ((v & 0xFF00) << 8)
       | ((v >> 8) & 0xFF00)
       | ((v >> 24) & 0xFF);
}

I16 BigShort(I16 v) {
  // I16 in HolyC is sign-extended on read; mask before shifting.
  I64 u = v & 0xFFFF;
  return ((u & 0xFF) << 8) | ((u >> 8) & 0xFF);
}

F64 BigFloat(F64 v) {
  // Bit-reverse the IEEE754 bits. Pack via union-equivalent reads.
  // F64 is 8 bytes — we swap them.
  U8 buf[8];
  U8 swp[8];
  I64 i;
  *(buf(F64 *)) = v;
  for (i = 0; i < 8; i++) {
    swp[i] = buf[7 - i];
  }
  return *(swp(F64 *));
}

Bool bigendien = FALSE;

// ============================================================
// link_t — doubly-linked list, used for the edict free-list and
// the per-area entity lists.
// ============================================================

class link_t {
  link_t *prev;
  link_t *next;
};

U0 ClearLink(link_t *l) {
  l->prev = l;
  l->next = l;
}

U0 RemoveLink(link_t *l) {
  l->next->prev = l->prev;
  l->prev->next = l->next;
}

U0 InsertLinkBefore(link_t *l, link_t *before) {
  l->next = before;
  l->prev = before->prev;
  l->prev->next = l;
  l->next->prev = l;
}

U0 InsertLinkAfter(link_t *l, link_t *after) {
  l->next = after->next;
  l->prev = after;
  l->prev->next = l;
  l->next->prev = l;
}

// ============================================================
// sizebuf_t — variable-size byte buffer used as the network
// scratch area and by the MSG codec.
// ============================================================

class sizebuf_t {
  Bool allowoverflow;     // if FALSE, overflow → Sys_Error
  Bool overflowed;        // set TRUE if the buffer ever overflowed
  U8  *data;
  I64 maxsize;
  I64 cursize;
};

U0 SZ_Alloc(sizebuf_t *buf, I64 startsize) {
  if (startsize < 256) {
    startsize = 256;
  }
  buf->data = Z_Malloc(startsize);
  buf->maxsize = startsize;
  buf->cursize = 0;
  buf->allowoverflow = FALSE;
  buf->overflowed = FALSE;
}

U0 SZ_Free(sizebuf_t *buf) {
  if (buf->data) {
    Z_Free(buf->data);
    buf->data = NULL;
  }
  buf->maxsize = 0;
  buf->cursize = 0;
}

U0 SZ_Clear(sizebuf_t *buf) {
  buf->cursize = 0;
  buf->overflowed = FALSE;
}

U8 *SZ_GetSpace(sizebuf_t *buf, I64 length) {
  if (buf->cursize + length > buf->maxsize) {
    if (!buf->allowoverflow) {
      Print("SZ_GetSpace: overflow without allowoverflow\n");
    }
    if (length > buf->maxsize) {
      Print("SZ_GetSpace: requested length larger than maxsize\n");
    }
    buf->overflowed = TRUE;
    SZ_Clear(buf);
  }
  U8 *p = buf->data + buf->cursize;
  buf->cursize = buf->cursize + length;
  return p;
}

U0 SZ_Write(sizebuf_t *buf, U8 *data, I64 length) {
  Q_memcpy(SZ_GetSpace(buf, length), data, length);
}

U0 SZ_Print(sizebuf_t *buf, U8 *data) {
  // Strcat-style: if the buffer's last byte is a NUL we overwrite
  // it; otherwise we append. Quake's behavior.
  I64 len = Q_strlen(data) + 1;
  if (buf->cursize > 0 && buf->data[buf->cursize - 1] == 0) {
    Q_memcpy(SZ_GetSpace(buf, len - 1) - 1, data, len);
  } else {
    Q_memcpy(SZ_GetSpace(buf, len), data, len);
  }
}

// ============================================================
// MSG_Write*: append codec.
// ============================================================

U0 MSG_WriteChar(sizebuf_t *sb, I64 c) {
  U8 *buf = SZ_GetSpace(sb, 1);
  buf[0] = c;
}

U0 MSG_WriteByte(sizebuf_t *sb, I64 c) {
  U8 *buf = SZ_GetSpace(sb, 1);
  buf[0] = c & 0xFF;
}

U0 MSG_WriteShort(sizebuf_t *sb, I64 c) {
  U8 *buf = SZ_GetSpace(sb, 2);
  buf[0] = c & 0xFF;
  buf[1] = (c >> 8) & 0xFF;
}

U0 MSG_WriteLong(sizebuf_t *sb, I64 c) {
  U8 *buf = SZ_GetSpace(sb, 4);
  buf[0] = c & 0xFF;
  buf[1] = (c >> 8) & 0xFF;
  buf[2] = (c >> 16) & 0xFF;
  buf[3] = (c >> 24) & 0xFF;
}

U0 MSG_WriteFloat(sizebuf_t *sb, F64 f) {
  // PROTOCOL DEVIATION: vanilla Quake stores 32-bit floats on the
  // wire. HolyC has no F32 type, and bit-twiddling F64→F32 isn't
  // worth the cost when the codec is internal to this port. We
  // store full F64 (8 bytes, little-endian native). The conversion
  // to/from Quake-network 4-byte floats happens at the network
  // boundary — not implemented yet, lands when net code is ported.
  U8 *src = &f(U8 *);
  U8 *buf = SZ_GetSpace(sb, 8);
  I64 i;
  for (i = 0; i < 8; i++) {
    buf[i] = src[i];
  }
}

U0 MSG_WriteString(sizebuf_t *sb, U8 *s) {
  // Includes the trailing NUL.
  if (!s) {
    SZ_Write(sb, "", 1);
    return;
  }
  SZ_Write(sb, s, Q_strlen(s) + 1);
}

U0 MSG_WriteCoord(sizebuf_t *sb, F64 f) {
  // Coordinates are scaled to 1/8 unit and stored as 16-bit.
  MSG_WriteShort(sb, f * 8.0);
}

U0 MSG_WriteAngle(sizebuf_t *sb, F64 f) {
  // Angles are encoded as 1/256 of a full rotation in a byte.
  I64 v = f * 256.0 / 360.0;
  MSG_WriteByte(sb, v & 255);
}

// ============================================================
// MSG_Read*: streaming decoder. State lives in module globals.
// ============================================================

I64 msg_readcount = 0;
Bool msg_badread = FALSE;
sizebuf_t *_msg_current = NULL;

U0 MSG_BeginReading(sizebuf_t *sb) {
  // Quake's signature is `MSG_BeginReading(void)` and it operates
  // on a fixed `net_message`. We accept a sizebuf so the codec is
  // testable in isolation; callers that want the Quake-shape will
  // wrap this with `MSG_BeginReading()` once net_message exists.
  _msg_current = sb;
  msg_readcount = 0;
  msg_badread = FALSE;
}

I64 MSG_ReadChar() {
  if (!_msg_current || msg_readcount + 1 > _msg_current->cursize) {
    msg_badread = TRUE;
    return -1;
  }
  I64 v = _msg_current->data[msg_readcount];
  // Sign-extend an 8-bit value into I64.
  if (v & 0x80) {
    v = v | -256;  // promotes through I64 to fill upper bits
  }
  msg_readcount++;
  return v;
}

I64 MSG_ReadByte() {
  if (!_msg_current || msg_readcount + 1 > _msg_current->cursize) {
    msg_badread = TRUE;
    return -1;
  }
  I64 v = _msg_current->data[msg_readcount];
  msg_readcount++;
  return v;
}

I64 MSG_ReadShort() {
  if (!_msg_current || msg_readcount + 2 > _msg_current->cursize) {
    msg_badread = TRUE;
    return -1;
  }
  I64 a = _msg_current->data[msg_readcount];
  I64 b = _msg_current->data[msg_readcount + 1];
  msg_readcount = msg_readcount + 2;
  I64 v = (b << 8) | a;
  // Sign-extend 16 bits.
  if (v & 0x8000) {
    v = v | -65536;
  }
  return v;
}

I64 MSG_ReadLong() {
  if (!_msg_current || msg_readcount + 4 > _msg_current->cursize) {
    msg_badread = TRUE;
    return -1;
  }
  I64 a = _msg_current->data[msg_readcount];
  I64 b = _msg_current->data[msg_readcount + 1];
  I64 c = _msg_current->data[msg_readcount + 2];
  I64 d = _msg_current->data[msg_readcount + 3];
  msg_readcount = msg_readcount + 4;
  I64 v = (d << 24) | (c << 16) | (b << 8) | a;
  if (v & 0x80000000) {
    v = v | -4294967296;  // sign-extend 32→64
  }
  return v;
}

F64 MSG_ReadFloat() {
  // Matched to MSG_WriteFloat: 8 bytes, F64 native. See note there.
  if (!_msg_current || msg_readcount + 8 > _msg_current->cursize) {
    msg_badread = TRUE;
    return -1.0;
  }
  F64 bits;
  U8 *dst = &bits(U8 *);
  I64 i;
  for (i = 0; i < 8; i++) {
    dst[i] = _msg_current->data[msg_readcount + i];
  }
  msg_readcount = msg_readcount + 8;
  return bits;
}

U8 _msg_string_buf[2048];

U8 *MSG_ReadString() {
  I64 len = 0;
  I64 c;
  while (TRUE) {
    c = MSG_ReadByte();
    if (c == -1 || c == 0) {
      break;
    }
    if (len < 2047) {
      _msg_string_buf[len] = c;
      len++;
    }
  }
  _msg_string_buf[len] = 0;
  return _msg_string_buf;
}

F64 MSG_ReadCoord() {
  return MSG_ReadShort() * (1.0 / 8.0);
}

F64 MSG_ReadAngle() {
  return MSG_ReadChar() * (360.0 / 256.0);
}

// ============================================================
// COM_Parse + com_token — canonical tokenizer.
// Cmd.HC keeps an internal _Cmd_COM_Parse copy until we converge;
// this is the public version other modules will adopt.
// ============================================================

U8 com_token[1024];
Bool com_eof = FALSE;

U8 *COM_Parse(U8 *data) {
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
  if (c == '/' && data[1] == '/') {
    while (*data && *data != '\n') {
      data++;
    }
    goto skipwhite;
  }
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

// ============================================================
// va() — printf into a rotating set of static buffers. Quake
// uses 4 rotating slots so calls can compose like
// `Print("%s/%s", va("foo"), va("bar"))` without aliasing.
// ============================================================

#define VA_NUM_BUFFERS 4
#define VA_BUFFER_SIZE 1024

// HolyC's parser doesn't accept `Type name[N][M];` for a 2D global
// array. Use a flat array and index manually.
U8  _va_buffers[VA_NUM_BUFFERS * VA_BUFFER_SIZE];
I64 _va_index = 0;

U8 *va(U8 *fmt, U8 *a, U8 *b, U8 *c, U8 *d) {
  // HolyC variadic isn't `...`; we accept 4 fmt args (covers the
  // forms va is actually called with in Quake's code paths that
  // we'll port). Each slot rotates.
  U8 *out = &_va_buffers[_va_index * VA_BUFFER_SIZE];
  _va_index = (_va_index + 1) % VA_NUM_BUFFERS;
  StrPrint(out, fmt, a, b, c, d);
  return out;
}

// ============================================================
// Path helpers
// ============================================================

U8 *COM_SkipPath(U8 *pathname) {
  // Return a pointer to the basename (after the last '/').
  U8 *last = pathname;
  while (*pathname) {
    if (*pathname == '/') {
      last = pathname + 1;
    }
    pathname++;
  }
  return last;
}

U0 COM_StripExtension(U8 *in, U8 *out) {
  // Copy `in` into `out`, then truncate at the last '.'.
  Q_strcpy(out, in);
  I64 i = Q_strlen(out);
  while (i > 0) {
    i--;
    if (out[i] == '.') {
      out[i] = 0;
      return;
    }
    if (out[i] == '/') {
      // a '.' in a directory name doesn't count
      return;
    }
  }
}

U0 COM_FileBase(U8 *in, U8 *out) {
  // Quake's COM_FileBase: extract the basename without extension
  // (e.g. "maps/start.bsp" → "start").
  //
  // `end` is a HolyC keyword (sub-switch start/end), so locals get
  // named `lim` here.
  U8 *base = COM_SkipPath(in);
  I64 nlen = Q_strlen(base);
  I64 lim = nlen;
  while (lim > 0 && base[lim - 1] != '.') {
    lim--;
  }
  if (lim > 0) {
    lim--;          // step past the '.'
  } else {
    lim = nlen;     // no extension
  }
  I64 i;
  for (i = 0; i < lim; i++) {
    out[i] = base[i];
  }
  out[lim] = 0;
}

U0 COM_DefaultExtension(U8 *path, U8 *extension) {
  // If `path` already has an extension, leave it. Otherwise append
  // `extension`. Quake's behavior: walks back from the end looking
  // for a '.' or '/'.
  I64 i = Q_strlen(path);
  while (i > 0) {
    i--;
    if (path[i] == '/') {
      break;
    }
    if (path[i] == '.') {
      return;
    }
  }
  Q_strcat(path, extension);
}
