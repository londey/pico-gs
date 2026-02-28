// VER-013: Color-Combined Output Golden Image Test — command script
//
// Encodes the register-write sequence for a textured, vertex-shaded
// triangle with the color combiner configured in MODULATE mode, as
// defined in doc/verification/ver_013_color_combined_output.md.
//
// The test renders a textured triangle with a programmatically generated
// 16x16 RGB565 checker pattern (white/mid-gray 4x4 blocks).  Vertex
// colors are red/green/blue (same as VER-010) so MODULATE produces
// texture_color * vertex_color, a color-tinted checker pattern.
//
// The script is a single array (no Z-buffer clear needed since Z is disabled).
//
// Register write sequence per INT-021 RenderMeshPatch:
//   1. FB_CONFIG     — framebuffer surface dimensions and base addresses
//   2. FB_CONTROL    — scissor rectangle
//   3. TEX0_CFG      — texture enable, format, dimensions, base address
//   4. CC_MODE       — MODULATE preset (TEX0 * SHADE0 in cycle 0, pass-through in cycle 1)
//   5. RENDER_MODE   — GOURAUD_EN=1, COLOR_WRITE_EN=1, no Z
//   6. AREA_SETUP    — triangle area normalization
//   7. V0: COLOR + UV0_UV1 + VERTEX_NOKICK
//   8. V1: COLOR + UV0_UV1 + VERTEX_NOKICK
//   9. V2: COLOR + UV0_UV1 + VERTEX_KICK_012
//
// References:
//   VER-013 (Color-Combined Output Golden Image Test)
//   UNIT-003 (Register File) — register addresses and data packing
//   UNIT-006 (Pixel Pipeline) — texture cache, format-select mux, combiner
//   UNIT-010 (Color Combiner) — two-stage pipeline, MODULATE mode
//   INT-010 (GPU Register Map) — register definitions
//   INT-014 (Texture Memory Layout) — 4x4 block-tiled layout

// This file is #include'd from harness.cpp after ver_014_textured_cube.cpp
// and ver_012_textured.cpp (which provide helper functions, register
// address constants, pack_uv, pack_tex0_cfg, and generate_checker_texture).

// ---------------------------------------------------------------------------
// VER-013 Constants
// ---------------------------------------------------------------------------

/// CC_MODE register address (from register_file.sv).
static constexpr uint8_t REG_CC_MODE = 0x18;

/// MODULATE CC_MODE encoding (cc_source_e indices):
///   Cycle 0: A=TEX0(1), B=ZERO(7), C=SHADE0(3), D=ZERO(7)
///   Cycle 1: A=COMBINED(0), B=ZERO(7), C=ONE(6), D=ZERO(7) (pass-through)
///
/// Packed: cycle0 = 0x73717371, cycle1 = 0x76707670
/// This matches the register_file.sv reset default for cc_mode_reg.
static constexpr uint64_t CC_MODE_MODULATE = 0x7670767073717371ULL;

/// Texture base address (same as VER-012 and VER-014).
static constexpr uint64_t TEX0_BASE_ADDR_013 = TEX0_BASE_ADDR;
static constexpr uint16_t TEX0_BASE_ADDR_512_013 = TEX0_BASE_ADDR_512;
static constexpr uint32_t TEX0_BASE_WORD_013 = TEX0_BASE_WORD;

/// RENDER_MODE: GOURAUD_EN=1, COLOR_WRITE_EN=1, no Z.
static constexpr uint64_t RENDER_MODE_COMBINED_013 =
    (1ULL << 0) |   // GOURAUD_EN
    (1ULL << 4);     // COLOR_WRITE_EN

// ---------------------------------------------------------------------------
// VER-013 Checker Texture Generator
//
// Same as VER-012/VER-014 checker but with white/mid-gray instead of
// white/black.  Mid-gray in RGB565 is 0x8410 (approx 50% intensity).
// ---------------------------------------------------------------------------

/// Generate a 16x16 RGB565 checker pattern with white/mid-gray blocks.
///
/// @return  512 bytes (16x16 pixels x 2 bytes/pixel) in linear row-major
///          order, suitable for fill_texture() with TexFormat::RGB565.
static std::vector<uint8_t> generate_checker_texture_midgray() {
    constexpr int TEX_SIZE = 16;
    constexpr int BLOCK_SIZE = 4;
    std::vector<uint8_t> data(TEX_SIZE * TEX_SIZE * 2);

    for (int y = 0; y < TEX_SIZE; y++) {
        for (int x = 0; x < TEX_SIZE; x++) {
            int block_x = x / BLOCK_SIZE;
            int block_y = y / BLOCK_SIZE;
            // Even blocks: white (0xFFFF), odd blocks: mid-gray (0x8410)
            uint16_t color = ((block_x + block_y) % 2 == 0) ? 0xFFFF : 0x8410;

            int idx = (y * TEX_SIZE + x) * 2;
            // Little-endian byte order
            data[idx + 0] = static_cast<uint8_t>(color & 0xFF);
            data[idx + 1] = static_cast<uint8_t>((color >> 8) & 0xFF);
        }
    }

    return data;
}

// ---------------------------------------------------------------------------
// VER-013 Command Script
//
// Vertex positions (screen-space, CCW winding):
//   V0: (320, 60)   — top center      UV = (0.5, 0.0)  — red
//   V1: (511, 380)  — bottom right    UV = (1.0, 1.0)  — blue
//   V2: (100, 380)  — bottom left     UV = (0.0, 1.0)  — green
// ---------------------------------------------------------------------------

static const RegWrite ver_013_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = 0,
    //    width_log2 = 9, height_log2 = 9
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
        TEX0_BASE_ADDR_512_013
    )},

    // 4. Configure CC_MODE for MODULATE (TEX0 * SHADE0)
    {REG_CC_MODE, CC_MODE_MODULATE},

    // 5. Set render mode: Gouraud + color write, no Z
    {REG_RENDER_MODE, RENDER_MODE_COMBINED_013},

    // 6. AREA_SETUP for the triangle (320,60)-(511,380)-(100,380)
    {REG_AREA_SETUP, compute_area_setup(320, 60, 511, 380, 100, 380)},

    // 7. Submit V0: red at (320, 60), UV=(0.5, 0.0)
    {REG_COLOR, pack_color(rgba(0xFF, 0x00, 0x00), rgba(0x00, 0x00, 0x00))},
    {REG_UV0_UV1, pack_uv(0.5f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(320, 60, 0x0000)},

    // 8. Submit V1: blue at (511, 380), UV=(1.0, 1.0)
    {REG_COLOR, pack_color(rgba(0x00, 0x00, 0xFF), rgba(0x00, 0x00, 0x00))},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(511, 380, 0x0000)},

    // 9. Submit V2: green at (100, 380), UV=(0.0, 1.0)
    //    VERTEX_KICK_012 triggers rasterization.
    {REG_COLOR, pack_color(rgba(0x00, 0xFF, 0x00), rgba(0x00, 0x00, 0x00))},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(100, 380, 0x0000)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_013_script_len =
    sizeof(ver_013_script) / sizeof(ver_013_script[0]);
