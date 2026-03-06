// VER-015: Triangle Size Grid Golden Image Test — command script
//
// Renders 8 Gouraud-shaded triangles arranged in a 4×2 grid with
// progressively doubling sizes: 1, 2, 4, 8, 16, 32, 64, 128 pixels per side.
// Each triangle has the same red/green/blue vertex coloring as VER-010.
//
// Grid layout (512×480 viewport, cell size 128×240):
//
//   Row 0: | 1px  | 2px  | 4px  | 8px  |
//   Row 1: | 16px | 32px | 64px | 128px|
//
// This test exercises the rasterizer across a wide range of triangle areas,
// verifying that derivative computation (1/area), attribute accumulation,
// and tile boundary stepping all work correctly for both tiny and large
// triangles.
//
// References:
//   VER-010 (Gouraud Triangle) — same vertex color scheme
//   UNIT-005 (Rasterizer) — derivative and interpolation pipeline

// This file is #include'd from harness.cpp after ver_010_gouraud.cpp,
// so pack_vertex, rgba, pack_color, pack_fb_config, pack_fb_control,
// and register address constants are already defined.

// ---------------------------------------------------------------------------
// Sub-pixel vertex packing: takes Q12.4 fixed-point coordinates directly.
// ---------------------------------------------------------------------------

/// Pack Q12.4 screen-space coordinates into VERTEX register format.
///
/// @param x_q4  Screen X in Q12.4 fixed-point (1 pixel = 16).
/// @param y_q4  Screen Y in Q12.4 fixed-point (1 pixel = 16).
/// @param z     Depth value (16-bit unsigned).
/// @return      64-bit packed vertex data.
static constexpr uint64_t pack_vertex_q4(int16_t x_q4, int16_t y_q4, uint16_t z) {
    uint16_t q = 0;
    return (static_cast<uint64_t>(q) << 48) |
           (static_cast<uint64_t>(z) << 32) |
           (static_cast<uint64_t>(static_cast<uint16_t>(y_q4)) << 16) |
           (static_cast<uint64_t>(static_cast<uint16_t>(x_q4)));
}

// ---------------------------------------------------------------------------
// Triangle specifications: center position and half-size in Q12.4 units.
// ---------------------------------------------------------------------------

struct SizeGridTri {
    int16_t cx;     // Center X in Q12.4
    int16_t cy;     // Center Y in Q12.4
    int16_t hs;     // Half-size in Q12.4 (triangle spans 2*hs in each axis)
};

// Cell centers: col={64,192,320,448} × row={120,360} pixels
// Sizes in pixels: 1, 2, 4, 8, 16, 32, 64, 128
// Half-sizes in Q12.4: 8, 16, 32, 64, 128, 256, 512, 1024

static constexpr SizeGridTri size_grid_tris[] = {
    { 64 * 16, 120 * 16,    8},   //   1px, row 0 col 0
    {192 * 16, 120 * 16,   16},   //   2px, row 0 col 1
    {320 * 16, 120 * 16,   32},   //   4px, row 0 col 2
    {448 * 16, 120 * 16,   64},   //   8px, row 0 col 3
    { 64 * 16, 360 * 16,  128},   //  16px, row 1 col 0
    {192 * 16, 360 * 16,  256},   //  32px, row 1 col 1
    {320 * 16, 360 * 16,  512},   //  64px, row 1 col 2
    {448 * 16, 360 * 16, 1024},   // 128px, row 1 col 3
};

static constexpr size_t SIZE_GRID_TRI_COUNT = sizeof(size_grid_tris) / sizeof(size_grid_tris[0]);

// ---------------------------------------------------------------------------
// VER-015 Command Script
// ---------------------------------------------------------------------------
// For each triangle:
//   V0: (cx, cy - hs)     — top, red       (CCW winding)
//   V1: (cx + hs, cy + hs) — bottom right, blue
//   V2: (cx - hs, cy + hs) — bottom left, green

// Build the script array at compile time.  Each triangle needs 6 commands
// (3× COLOR + VERTEX), plus 4 setup commands + 1 trailing dummy = 53 total.

static const RegWrite ver_015_script[] = {
    // 1. Configure framebuffer: 512×512, color base = 0, no Z buffer
    {REG_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9)},

    // 2. Scissor covering full 512×480 viewport
    {REG_FB_CONTROL, pack_fb_control(0, 0, 512, 480)},

    // 3. Render mode: Gouraud + color write, no Z
    {REG_RENDER_MODE, RENDER_MODE_GOURAUD_COLOR},

    // --- Triangle 0: 1px (half-size = 0.5px = 8 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(64*16, 120*16 - 8, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(64*16 + 8, 120*16 + 8, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(64*16 - 8, 120*16 + 8, 0)},

    // --- Triangle 1: 2px (half-size = 1px = 16 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(192*16, 120*16 - 16, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(192*16 + 16, 120*16 + 16, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(192*16 - 16, 120*16 + 16, 0)},

    // --- Triangle 2: 4px (half-size = 2px = 32 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(320*16, 120*16 - 32, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(320*16 + 32, 120*16 + 32, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(320*16 - 32, 120*16 + 32, 0)},

    // --- Triangle 3: 8px (half-size = 4px = 64 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(448*16, 120*16 - 64, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(448*16 + 64, 120*16 + 64, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(448*16 - 64, 120*16 + 64, 0)},

    // --- Triangle 4: 16px (half-size = 8px = 128 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(64*16, 360*16 - 128, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(64*16 + 128, 360*16 + 128, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(64*16 - 128, 360*16 + 128, 0)},

    // --- Triangle 5: 32px (half-size = 16px = 256 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(192*16, 360*16 - 256, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(192*16 + 256, 360*16 + 256, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(192*16 - 256, 360*16 + 256, 0)},

    // --- Triangle 6: 64px (half-size = 32px = 512 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(320*16, 360*16 - 512, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(320*16 + 512, 360*16 + 512, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(320*16 - 512, 360*16 + 512, 0)},

    // --- Triangle 7: 128px (half-size = 64px = 1024 Q12.4) ---
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(448*16, 360*16 - 1024, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF))},
    {REG_VERTEX_NOKICK, pack_vertex_q4(448*16 + 1024, 360*16 + 1024, 0)},
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex_q4(448*16 - 1024, 360*16 + 1024, 0)},

    // Trailing dummy command (see VER-010 for rationale)
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_015_script_len = sizeof(ver_015_script) / sizeof(ver_015_script[0]);
