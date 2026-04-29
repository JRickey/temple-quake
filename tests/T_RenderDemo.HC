// T_RenderDemo.HC — visible-pixels-on-screen smoke for Render_Flush.
//
// Fills render_buf with 16 vertical stripes (one per TempleOS DC
// color), calls Render_Flush at the top-left, sleeps briefly so a
// host-side screenshot can capture the pre-cleanup framebuffer,
// then verifies the in-memory buffer state. This is the first
// visible output the project has produced — the screenshot is
// the win; the assertions are insurance.
//
// The stripe pattern is chosen so pixel (x, y) = floor(x / 20),
// giving 16 stripes × 20 pixels = exactly 320 wide × 200 tall.
// After `qpal & 0xF` quantization, stripe N maps to TempleOS
// color N — all 16 visible at once.

I64 _rd_x;
I64 _rd_y;
for (_rd_y = 0; _rd_y < RENDER_H; _rd_y++) {
  for (_rd_x = 0; _rd_x < RENDER_W; _rd_x++) {
    Render_PutPixel(_rd_x, _rd_y, _rd_x / 20);
  }
}

// In-memory shape check before we flush — confirms the pattern
// landed where we think.
ASSERT_EQ(Render_GetPixel(0,   0),    0, "demo.stripe0_left");
ASSERT_EQ(Render_GetPixel(19,  100),  0, "demo.stripe0_right");
ASSERT_EQ(Render_GetPixel(20,  100),  1, "demo.stripe1_left");
ASSERT_EQ(Render_GetPixel(160, 100),  8, "demo.stripe8_middle");
ASSERT_EQ(Render_GetPixel(319, 199), 15, "demo.stripe15_botright");

// Blit to TempleOS's screen DC at top-left.
Render_Flush(0, 0);

// Hold the framebuffer stable for ~1.5s so a host screenshot can
// capture it before the test runner moves on.
Sleep(1500);

PASS("demo.flush_completed");
