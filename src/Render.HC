// Render.HC — software-renderer foundation for the Quake port.
//
// Quake renders into a 320×200 buffer of 8-bit palette indices.
// TempleOS draws to a 640×480 framebuffer with a 16-color palette
// per DC. To bridge that:
//
//   * We allocate `render_buf[320 * 200]` of U8 palette indices —
//     the canonical Quake render target. All ported r_*.c / d_*.c
//     code writes here.
//   * On each frame, `Render_Flush` walks the buffer and emits
//     dither-quantized 16-color output to TempleOS via the DC
//     primitives. This pass is deliberately separated so the port
//     of WinQuake's pixel-pushing code doesn't have to know about
//     TempleOS's palette.
//   * The 256→16 quantization uses a fixed lookup table
//     `_render_quant_table` that maps each Quake palette index to
//     the closest TempleOS color (0..15). Built once at init from
//     a representative Quake palette.
//
// Phase 9.0 ships only the in-memory primitives (Render_Init,
// Render_Clear, Render_DrawRect, Render_GetPixel) — no display
// blit yet. Tests verify the buffer mutations against expected
// pixel values; the actual `Render_Flush` to TempleOS DC lands
// once we have a real frame to draw.

#define RENDER_W 320
#define RENDER_H 200

// Static buffer. 320 * 200 = 64,000 bytes — fits comfortably in
// the BSS. Palette indices 0..255; meaning depends on the
// Quake palette loaded at runtime (deferred to Phase 9.1+).
U8 render_buf[RENDER_W * RENDER_H];

// Initialize: zero the buffer (palette index 0 = pure black in
// Quake's standard palette).
U0 Render_Init() {
  Q_memset(render_buf, 0, RENDER_W * RENDER_H);
}

// Clear to a specific palette index. Useful for backdrops + test
// fixtures.
U0 Render_Clear(U8 color) {
  Q_memset(render_buf, color, RENDER_W * RENDER_H);
}

// Read a single pixel. Out-of-bounds reads return 0 (matching
// Quake's clamping semantics).
U8 Render_GetPixel(I64 x, I64 y) {
  if (x < 0 || x >= RENDER_W || y < 0 || y >= RENDER_H) {
    return 0;
  }
  return render_buf[y * RENDER_W + x];
}

// Write a single pixel. Out-of-bounds writes silently no-op.
U0 Render_PutPixel(I64 x, I64 y, U8 color) {
  if (x < 0 || x >= RENDER_W || y < 0 || y >= RENDER_H) {
    return;
  }
  render_buf[y * RENDER_W + x] = color;
}

// Filled axis-aligned rectangle. Clips to the buffer bounds.
// (x, y) is the top-left; (w, h) is the size.
U0 Render_DrawRect(I64 x, I64 y, I64 w, I64 h, U8 color) {
  // Clip
  I64 x0 = x;
  I64 y0 = y;
  I64 x1 = x + w;
  I64 y1 = y + h;
  if (x0 < 0) {
    x0 = 0;
  }
  if (y0 < 0) {
    y0 = 0;
  }
  if (x1 > RENDER_W) {
    x1 = RENDER_W;
  }
  if (y1 > RENDER_H) {
    y1 = RENDER_H;
  }
  if (x0 >= x1 || y0 >= y1) {
    return;
  }
  I64 row;
  I64 col;
  for (row = y0; row < y1; row++) {
    U8 *p = render_buf + row * RENDER_W + x0;
    for (col = x0; col < x1; col++) {
      *p = color;
      p++;
    }
  }
}

// Horizontal line — single row, fast-path for the surface drawer
// later. Clips x to [0, RENDER_W).
U0 Render_HLine(I64 x, I64 y, I64 len, U8 color) {
  if (y < 0 || y >= RENDER_H) {
    return;
  }
  I64 x0 = x;
  I64 x1 = x + len;
  if (x0 < 0) {
    x0 = 0;
  }
  if (x1 > RENDER_W) {
    x1 = RENDER_W;
  }
  if (x0 >= x1) {
    return;
  }
  Q_memset(render_buf + y * RENDER_W + x0, color, x1 - x0);
}
