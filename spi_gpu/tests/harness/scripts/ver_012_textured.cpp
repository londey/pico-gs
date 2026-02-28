// VER-012: Textured Triangle Golden Image Test — command script
//
// Encodes the register-write sequence for a single textured triangle
// defined in doc/verification/ver_012_textured_triangle.md.
//
// The test renders a textured triangle with a programmatically generated
// 16x16 RGB565 checker pattern (white/black 4x4 blocks).  Vertex colors
// are white so MODULATE produces texture_color * 1.0 = texture_color.
//
// The script is a single array (no Z-buffer clear needed since Z is disabled).
//
// Register write sequence per INT-021 RenderMeshPatch:
//   1. FB_CONFIG     — framebuffer surface dimensions and base addresses
//   2. FB_CONTROL    — scissor rectangle
//   3. TEX0_CFG      — texture enable, format, dimensions, base address
//   4. RENDER_MODE   — COLOR_WRITE_EN=1, no Z, no Gouraud
//   5. AREA_SETUP    — triangle area normalization
//   6. V0: COLOR + UV0_UV1 + VERTEX_NOKICK
//   7. V1: COLOR + UV0_UV1 + VERTEX_NOKICK
//   8. V2: COLOR + UV0_UV1 + VERTEX_KICK_012
//
// References:
//   VER-012 (Textured Triangle Golden Image Test)
//   UNIT-003 (Register File) — register addresses and data packing
//   UNIT-006 (Pixel Pipeline) — texture cache, format-select mux
//   INT-010 (GPU Register Map) — register definitions
//   INT-014 (Texture Memory Layout) — 4x4 block-tiled layout
//   INT-032 (Texture Cache Architecture) — cache miss handling

// This file is #include'd from harness.cpp after ver_010_gouraud.cpp,
// ver_011_depth_test.cpp, and ver_014_textured_cube.cpp (which provide
// helper functions, register address constants, pack_uv, pack_tex0_cfg,
// and generate_checker_texture).

// ---------------------------------------------------------------------------
// VER-012 Constants
// ---------------------------------------------------------------------------

/// Texture base address (same as VER-014).
static constexpr uint64_t TEX0_BASE_ADDR_012 = TEX0_BASE_ADDR;
static constexpr uint16_t TEX0_BASE_ADDR_512_012 = TEX0_BASE_ADDR_512;
static constexpr uint32_t TEX0_BASE_WORD_012 = TEX0_BASE_WORD;

/// RENDER_MODE: COLOR_WRITE_EN=1, no Gouraud (flat white), no Z.
static constexpr uint64_t RENDER_MODE_TEXTURED_012 =
    (1ULL << 4);   // COLOR_WRITE_EN

/// Vertex color: white diffuse (so MODULATE produces texture * 1.0).
static constexpr uint64_t COLOR_WHITE_012 = pack_color(rgba(0xFF, 0xFF, 0xFF), rgba(0x00, 0x00, 0x00));

// ---------------------------------------------------------------------------
// VER-012 Command Script
//
// Vertex positions (screen-space, CCW winding):
//   V0: (320, 60)   — top center      UV = (0.5, 0.0)
//   V1: (511, 380)  — bottom right    UV = (1.0, 1.0)
//   V2: (100, 380)  — bottom left     UV = (0.0, 1.0)
//
// Vertices are ordered CCW (top → bottom-right → bottom-left) so the
// edge function test (e0 >= 0 && e1 >= 0 && e2 >= 0) passes.
// ---------------------------------------------------------------------------

static const RegWrite ver_012_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = 0,
    //    width_log2 = 9 (512-wide), height_log2 = 9
    {REG_FB_CONFIG, pack_fb_config(0x0000, 0x0000, 9, 9)},

    // 2. Configure scissor to cover full 512x512 viewport
    {REG_FB_CONTROL, pack_fb_control(0, 0, 512, 512)},

    // 3. Configure TEX0: ENABLE=1, FILTER=NEAREST, FORMAT=RGB565(4),
    //    WIDTH_LOG2=4, HEIGHT_LOG2=4, WRAP=REPEAT, MIP_LEVELS=0
    {REG_TEX0_CFG, pack_tex0_cfg(
        1,                    // ENABLE
        0,                    // FILTER = NEAREST
        4,                    // FORMAT = RGB565
        4,                    // WIDTH_LOG2 (16px)
        4,                    // HEIGHT_LOG2 (16px)
        0,                    // U_WRAP = REPEAT
        0,                    // V_WRAP = REPEAT
        0,                    // MIP_LEVELS = 0
        TEX0_BASE_ADDR_512_012
    )},

    // 4. Set render mode: textured, color write, no Z, no Gouraud
    {REG_RENDER_MODE, RENDER_MODE_TEXTURED_012},

    // 5. AREA_SETUP for the triangle (320,60)-(511,380)-(100,380)
    {REG_AREA_SETUP, compute_area_setup(320, 60, 511, 380, 100, 380)},

    // 6. Submit V0: white at (320, 60), UV=(0.5, 0.0)
    {REG_COLOR, COLOR_WHITE_012},
    {REG_UV0_UV1, pack_uv(0.5f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000)},

    // 7. Submit V1: white at (511, 380), UV=(1.0, 1.0)
    {REG_COLOR, COLOR_WHITE_012},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000)},

    // 8. Submit V2: white at (100, 380), UV=(0.0, 1.0)
    //    VERTEX_KICK_012 triggers rasterization.
    {REG_COLOR, COLOR_WHITE_012},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_012_script_len =
    sizeof(ver_012_script) / sizeof(ver_012_script[0]);
