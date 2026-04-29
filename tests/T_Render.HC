// T_Render.HC — tests for Render.HC's pixel buffer primitives.
//
// Phase 9.0 scope: just the in-memory buffer manipulation. The
// actual blit-to-TempleOS-DC pass (Render_Flush) hasn't been
// written yet; testing it requires a live screen and pixel
// readback we don't have yet.

// ---- init clears to 0 ----
Render_Init();
ASSERT_EQ(Render_GetPixel(0, 0),     0, "render.init_clears_topleft");
ASSERT_EQ(Render_GetPixel(159, 99),  0, "render.init_clears_middle");
ASSERT_EQ(Render_GetPixel(319, 199), 0, "render.init_clears_botright");

// ---- clear with arbitrary color ----
Render_Clear(0xAB);
ASSERT_EQ(Render_GetPixel(0,   0),  0xAB, "render.clear_topleft");
ASSERT_EQ(Render_GetPixel(159, 99), 0xAB, "render.clear_middle");
ASSERT_EQ(Render_GetPixel(319,199), 0xAB, "render.clear_botright");

// ---- single pixel write/read ----
Render_Init();
Render_PutPixel(10, 20, 0x42);
ASSERT_EQ(Render_GetPixel(10, 20), 0x42, "render.put_then_get");
ASSERT_EQ(Render_GetPixel(11, 20), 0,    "render.adjacent_unchanged");
ASSERT_EQ(Render_GetPixel(10, 21), 0,    "render.row_below_unchanged");

// ---- out-of-bounds: read returns 0, write silently no-ops ----
Render_PutPixel(-1, 50, 0xFF);                 // off left edge
Render_PutPixel(RENDER_W,     50, 0xFF);       // off right edge
Render_PutPixel(50, -1,       0xFF);           // off top edge
Render_PutPixel(50, RENDER_H, 0xFF);           // off bottom edge
ASSERT_EQ(Render_GetPixel(-1, 50), 0,            "render.read_left_oob");
ASSERT_EQ(Render_GetPixel(RENDER_W,     50), 0,  "render.read_right_oob");
ASSERT_EQ(Render_GetPixel(50, -1), 0,            "render.read_top_oob");
ASSERT_EQ(Render_GetPixel(50, RENDER_H),     0,  "render.read_bot_oob");

// ---- DrawRect: mid-buffer ----
Render_Init();
Render_DrawRect(100, 50, 20, 10, 0x33);
// Inside the rect
ASSERT_EQ(Render_GetPixel(100, 50), 0x33, "render.rect_topleft");
ASSERT_EQ(Render_GetPixel(119, 59), 0x33, "render.rect_botright_inclusive");
// One past the bounds (rect is exclusive on the far edge)
ASSERT_EQ(Render_GetPixel(120, 50), 0,    "render.rect_right_edge_exclusive");
ASSERT_EQ(Render_GetPixel(100, 60), 0,    "render.rect_bot_edge_exclusive");
// One before
ASSERT_EQ(Render_GetPixel(99,  50), 0,    "render.rect_left_edge_unchanged");
ASSERT_EQ(Render_GetPixel(100, 49), 0,    "render.rect_top_edge_unchanged");

// ---- DrawRect: clip on left/top edges ----
Render_Init();
Render_DrawRect(-5, -5, 10, 10, 0x77);         // 5x5 visible at (0,0)
ASSERT_EQ(Render_GetPixel(0, 0), 0x77, "render.rect_clipped_topleft");
ASSERT_EQ(Render_GetPixel(4, 4), 0x77, "render.rect_clipped_4_4");
ASSERT_EQ(Render_GetPixel(5, 4), 0,    "render.rect_clipped_right_edge");
ASSERT_EQ(Render_GetPixel(4, 5), 0,    "render.rect_clipped_bot_edge");

// ---- DrawRect: clip on right/bottom edges ----
Render_Init();
Render_DrawRect(RENDER_W - 5, RENDER_H - 5, 100, 100, 0x55);
ASSERT_EQ(Render_GetPixel(RENDER_W - 1, RENDER_H - 1), 0x55,
          "render.rect_clipped_botright");
ASSERT_EQ(Render_GetPixel(RENDER_W - 5, RENDER_H - 5), 0x55,
          "render.rect_clipped_topleft_far");
ASSERT_EQ(Render_GetPixel(RENDER_W - 6, RENDER_H - 5), 0,
          "render.rect_clipped_one_left_unchanged");

// ---- DrawRect: zero/negative size is no-op ----
Render_Init();
Render_DrawRect(50, 50, 0, 10, 0x99);
ASSERT_EQ(Render_GetPixel(50, 50), 0, "render.rect_zero_w_noop");
Render_DrawRect(50, 50, 10, 0, 0x99);
ASSERT_EQ(Render_GetPixel(50, 50), 0, "render.rect_zero_h_noop");

// ---- DrawRect: entirely off-screen is no-op ----
Render_Init();
Render_DrawRect(-100, -100, 50, 50, 0x88);
ASSERT_EQ(Render_GetPixel(0, 0), 0, "render.rect_entirely_off_topleft");
Render_DrawRect(RENDER_W + 10, RENDER_H + 10, 50, 50, 0x88);
ASSERT_EQ(Render_GetPixel(RENDER_W - 1, RENDER_H - 1), 0,
          "render.rect_entirely_off_botright");

// ---- HLine: standard, clipping, oob ----
Render_Init();
Render_HLine(50, 100, 30, 0xAA);
ASSERT_EQ(Render_GetPixel(50, 100), 0xAA, "render.hline_left");
ASSERT_EQ(Render_GetPixel(79, 100), 0xAA, "render.hline_right");
ASSERT_EQ(Render_GetPixel(80, 100), 0,    "render.hline_one_past");
ASSERT_EQ(Render_GetPixel(50, 99),  0,    "render.hline_row_above");
ASSERT_EQ(Render_GetPixel(50, 101), 0,    "render.hline_row_below");
// Clip both ends
Render_HLine(-10, 50, 30, 0xBB);
ASSERT_EQ(Render_GetPixel(0,  50), 0xBB, "render.hline_clipped_left");
ASSERT_EQ(Render_GetPixel(19, 50), 0xBB, "render.hline_clipped_right");
ASSERT_EQ(Render_GetPixel(20, 50), 0,    "render.hline_one_past_clipped");
// Off-screen y → no-op
Render_HLine(0, -1,        50, 0xCC);
Render_HLine(0, RENDER_H,  50, 0xCC);
ASSERT_EQ(Render_GetPixel(0, 0), 0,           "render.hline_oob_top_noop");
ASSERT_EQ(Render_GetPixel(0, RENDER_H - 1), 0, "render.hline_oob_bot_noop");

// ---- Bresenham line drawer ----

// Horizontal line: same as HLine
Render_Init();
Render_Line(10, 50, 20, 50, 0x42);
ASSERT_EQ(Render_GetPixel(10, 50), 0x42, "render.line_horiz_left");
ASSERT_EQ(Render_GetPixel(15, 50), 0x42, "render.line_horiz_mid");
ASSERT_EQ(Render_GetPixel(20, 50), 0x42, "render.line_horiz_right");
ASSERT_EQ(Render_GetPixel(21, 50), 0,    "render.line_horiz_one_past");
ASSERT_EQ(Render_GetPixel(10, 51), 0,    "render.line_horiz_row_below");

// Vertical line
Render_Init();
Render_Line(100, 20, 100, 30, 0x55);
ASSERT_EQ(Render_GetPixel(100, 20), 0x55, "render.line_vert_top");
ASSERT_EQ(Render_GetPixel(100, 25), 0x55, "render.line_vert_mid");
ASSERT_EQ(Render_GetPixel(100, 30), 0x55, "render.line_vert_bot");
ASSERT_EQ(Render_GetPixel(101, 25), 0,    "render.line_vert_col_right");

// Diagonal (45°): every step advances both x and y
Render_Init();
Render_Line(0, 0, 10, 10, 0x77);
ASSERT_EQ(Render_GetPixel(0,  0),  0x77, "render.line_diag_start");
ASSERT_EQ(Render_GetPixel(5,  5),  0x77, "render.line_diag_mid");
ASSERT_EQ(Render_GetPixel(10, 10), 0x77, "render.line_diag_end");
ASSERT_EQ(Render_GetPixel(11, 11), 0,    "render.line_diag_one_past");
// Off-diagonal pixels untouched
ASSERT_EQ(Render_GetPixel(1, 0),  0, "render.line_diag_off");
ASSERT_EQ(Render_GetPixel(0, 1),  0, "render.line_diag_off2");

// Reverse direction (right-to-left + bottom-to-top)
Render_Init();
Render_Line(20, 20, 10, 10, 0x88);
ASSERT_EQ(Render_GetPixel(20, 20), 0x88, "render.line_reverse_start");
ASSERT_EQ(Render_GetPixel(15, 15), 0x88, "render.line_reverse_mid");
ASSERT_EQ(Render_GetPixel(10, 10), 0x88, "render.line_reverse_end");

// Shallow slope (more horizontal than vertical)
Render_Init();
Render_Line(0, 0, 20, 5, 0x99);
ASSERT_EQ(Render_GetPixel(0,  0), 0x99, "render.line_shallow_start");
ASSERT_EQ(Render_GetPixel(20, 5), 0x99, "render.line_shallow_end");
// Bresenham takes 21 steps; verify a midpoint
ASSERT_EQ(Render_GetPixel(10, 2), 0x99, "render.line_shallow_mid");

// Steep slope (more vertical than horizontal)
Render_Init();
Render_Line(0, 0, 5, 20, 0xAA);
ASSERT_EQ(Render_GetPixel(0, 0),  0xAA, "render.line_steep_start");
ASSERT_EQ(Render_GetPixel(5, 20), 0xAA, "render.line_steep_end");
ASSERT_EQ(Render_GetPixel(2, 10), 0xAA, "render.line_steep_mid");

// Single-pixel "line" (degenerate)
Render_Init();
Render_Line(50, 50, 50, 50, 0xBB);
ASSERT_EQ(Render_GetPixel(50, 50), 0xBB, "render.line_degenerate");
ASSERT_EQ(Render_GetPixel(51, 50), 0,    "render.line_degenerate_no_extra");

// Off-screen endpoint clipped via Render_PutPixel; in-bounds portion drawn
Render_Init();
Render_Line(-10, 50, 10, 50, 0xCC);
ASSERT_EQ(Render_GetPixel(0,  50), 0xCC, "render.line_clipped_left_visible");
ASSERT_EQ(Render_GetPixel(10, 50), 0xCC, "render.line_clipped_right_visible");

// Both endpoints off-screen with no in-bounds intermediate pixels
Render_Init();
Render_Line(-50, -50, -10, -10, 0xDD);
ASSERT_EQ(Render_GetPixel(0, 0), 0, "render.line_both_off_noop");

// ---- Render_Quantize via the generated 256→16 table ----
//
// Spot-check key palette positions. The exact mappings come from
// gen-palette.py's synthetic Quake palette + nearest-RGB
// against TempleOS's CGA-derived 16-color DC palette.

// Index 0 (black) → BLACK (0)
ASSERT_EQ(Render_Quantize(0),    0, "quant.black");
// Index 15 (full white in the grayscale ramp) → WHITE (15)
ASSERT_EQ(Render_Quantize(15),  15, "quant.white");
// Index 7 (~127 RGB mid-gray) — closer to DKGRAY (85,85,85) than
// LTGRAY (170,170,170) by 1 unit. Table maps 7 → 8.
ASSERT_EQ(Render_Quantize(7),    8, "quant.midgray_dkgray");
// Index 240 (red brightlight) → RED (4)
ASSERT_EQ(Render_Quantize(240),  4, "quant.bright_red");
// Index 241 (green brightlight) → GREEN (2)
ASSERT_EQ(Render_Quantize(241),  2, "quant.bright_green");
// Index 252 (white brightlight) → WHITE (15)
ASSERT_EQ(Render_Quantize(252), 15, "quant.bright_white");
// Every entry must be in 0..15 (table is bounds-correct)
I64 _q_idx;
Bool _q_in_range = TRUE;
for (_q_idx = 0; _q_idx < 256; _q_idx++) {
  U8 _q_v = Render_Quantize(_q_idx);
  if (_q_v > 15) {
    _q_in_range = FALSE;
    break;
  }
}
ASSERT_EQ(_q_in_range == TRUE, 1, "quant.all_entries_in_range");
