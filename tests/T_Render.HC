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
