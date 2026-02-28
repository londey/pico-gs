// VER-014: Textured Cube Golden Image Test — command script
//
// Encodes the register-write sequence for the textured cube test defined in
// doc/verification/ver_014_textured_cube.md.
//
// The test renders a perspective-projected unit cube (twelve triangles, six
// faces) with a programmatically generated 16x16 RGB565 checker texture.
// Back-face triangles are submitted first (painter's order); front-face
// triangles are submitted last.  Z-testing occludes the back faces.
//
// The script is split into four sub-arrays:
//   ver_014_zclear_script     — Z-buffer clear pass (full 512x512 surface)
//   ver_014_setup_script      — Texture and render-mode configuration
//   ver_014_triangles_script  — All twelve cube triangle submissions
//
// Register write sequence per INT-021 RenderMeshPatch:
//   1. FB_CONFIG      — framebuffer surface dimensions, color base, Z base
//   2. FB_CONTROL     — scissor rectangle covering the full viewport
//   3. RENDER_MODE    — Z clear: Z_TEST=1, Z_WRITE=1, Z_COMPARE=ALWAYS
//   4. Z-clear triangles covering the full 512x512 surface with Z=0xFFFF
//   5. (pipeline idle)
//   6. TEX0_CFG       — texture enable, format, dimensions, base address
//   7. RENDER_MODE    — depth-tested textured: GOURAUD=1, Z_TEST=1,
//                       Z_WRITE=1, COLOR_WRITE=1, Z_COMPARE=LEQUAL
//   8. Twelve cube triangles with COLOR, UV0_UV1, VERTEX writes
//
// References:
//   VER-014 (Textured Cube Golden Image Test)
//   UNIT-003 (Register File) — register addresses and data packing
//   UNIT-005 (Rasterizer) — perspective-correct UV interpolation
//   UNIT-006 (Pixel Pipeline) — early Z-test, texture cache, MODULATE
//   INT-010 (GPU Register Map) — register definitions
//   INT-014 (Texture Memory Layout) — 4x4 block-tiled layout
//   INT-032 (Texture Cache Architecture) — cache miss handling

// This file is #include'd from harness.cpp after the RegWrite struct
// definition and the ver_010_gouraud.cpp / ver_011_depth_test.cpp scripts
// (which provide the helper functions and register address constants).
// <cstdint>, <vector>, and <cmath> are already included by harness.cpp.

// ---------------------------------------------------------------------------
// Additional register address constants for VER-014
//
// These supplement the constants defined in ver_010_gouraud.cpp.
// ---------------------------------------------------------------------------

static constexpr uint8_t REG_TEX0_CFG = 0x10;          // ADDR_TEX0_CFG
static constexpr uint8_t REG_UV0_UV1 = 0x01;           // ADDR_UV0_UV1
static constexpr uint8_t REG_VERTEX_KICK_021 = 0x08;   // ADDR_VERTEX_KICK_021

// ---------------------------------------------------------------------------
// UV coordinate packing helper
//
// From register_file.sv ADDR_UV0_UV1 decode and gpu_regs.rdl UV0_UV1 reg:
//   [15:0]   = UV0_UQ  (U coordinate for TEX0, Q1.15 signed fixed-point)
//   [31:16]  = UV0_VQ  (V coordinate for TEX0, Q1.15 signed fixed-point)
//   [47:32]  = UV1_UQ  (U coordinate for TEX1, Q1.15 signed fixed-point)
//   [63:48]  = UV1_VQ  (V coordinate for TEX1, Q1.15 signed fixed-point)
//
// Q1.15 encoding: value * 32768.0f
// Range: -1.0 to +0.999969 (approx +1.0)
// For UV=1.0, the packed value is 0x7FFF (closest representable).
// ---------------------------------------------------------------------------

/// Pack UV0 coordinates into the 64-bit UV0_UV1 register format.
/// UV1 is set to zero (only TEX0 is used in VER-014).
///
/// @param u0  U coordinate for TEX0 (0.0 to 1.0).
/// @param v0  V coordinate for TEX0 (0.0 to 1.0).
/// @return    64-bit packed UV0_UV1 register value.
static constexpr uint64_t pack_uv(float u0, float v0) {
    auto to_q1_15 = [](float val) -> uint16_t {
        auto fixed = static_cast<int16_t>(val * 32768.0f);
        return static_cast<uint16_t>(fixed);
    };
    uint16_t u_packed = to_q1_15(u0);
    uint16_t v_packed = to_q1_15(v0);
    // UV1 = 0 (TEX1 not used)
    return (static_cast<uint64_t>(v_packed) << 16) |
           (static_cast<uint64_t>(u_packed));
}

// ---------------------------------------------------------------------------
// TEX0_CFG packing helper
//
// From gpu_regs.rdl (authoritative) and register_file.sv ADDR_TEX0_CFG:
//   [0]      = ENABLE
//   [1]      = RSVD_1
//   [3:2]    = FILTER (tex_filter_e: 0=NEAREST, 1=BILINEAR)
//   [6:4]    = FORMAT (tex_format_e: 0=BC1, 4=RGB565, 5=RGBA8888, 6=R8)
//   [7]      = RSVD_7
//   [11:8]   = WIDTH_LOG2
//   [15:12]  = HEIGHT_LOG2
//   [17:16]  = U_WRAP
//   [19:18]  = V_WRAP
//   [23:20]  = MIP_LEVELS
//   [31:24]  = RSVD_MID
//   [47:32]  = BASE_ADDR (16-bit, x512 for byte address)
//   [63:48]  = RSVD_HI
// ---------------------------------------------------------------------------

/// Pack TEX0_CFG register value.
///
/// @param enable      Texture enable (1 = enabled).
/// @param filter      Filter mode (0 = NEAREST, 1 = BILINEAR).
/// @param format      Texture format (tex_format_e: 4 = RGB565).
/// @param width_log2  Log2 of texture width (e.g. 4 for 16px).
/// @param height_log2 Log2 of texture height (e.g. 4 for 16px).
/// @param u_wrap      U wrap mode (0 = repeat).
/// @param v_wrap      V wrap mode (0 = repeat).
/// @param mip_levels  Number of mip levels (0 = 1 level).
/// @param base_addr_512 Base address in 512-byte units.
/// @return            64-bit TEX0_CFG register value.
static constexpr uint64_t pack_tex0_cfg(
    uint8_t enable,
    uint8_t filter,
    uint8_t format,
    uint8_t width_log2,
    uint8_t height_log2,
    uint8_t u_wrap,
    uint8_t v_wrap,
    uint8_t mip_levels,
    uint16_t base_addr_512
) {
    return (static_cast<uint64_t>(enable & 0x1))              |  // [0]
           (static_cast<uint64_t>(filter & 0x3)    << 2)      |  // [3:2]
           (static_cast<uint64_t>(format & 0x7)    << 4)      |  // [6:4]
           (static_cast<uint64_t>(width_log2 & 0xF)  << 8)    |  // [11:8]
           (static_cast<uint64_t>(height_log2 & 0xF) << 12)   |  // [15:12]
           (static_cast<uint64_t>(u_wrap & 0x3)    << 16)     |  // [17:16]
           (static_cast<uint64_t>(v_wrap & 0x3)    << 18)     |  // [19:18]
           (static_cast<uint64_t>(mip_levels & 0xF) << 20)    |  // [23:20]
           (static_cast<uint64_t>(base_addr_512)   << 32);       // [47:32]
}

// ---------------------------------------------------------------------------
// Checker texture generator
//
// Generates a 16x16 pixel checker pattern in RGB565 format.
// 4x4 block checker: even blocks are white (0xFFFF), odd blocks are
// black (0x0000).  Block coordinates: block_x = px / 4, block_y = py / 4.
// Even block: (block_x + block_y) % 2 == 0.
//
// Returns raw pixel bytes (2 bytes per pixel, little-endian) suitable for
// passing to sdram.fill_texture(base, TexFormat::RGB565, data, width_log2).
// ---------------------------------------------------------------------------

/// Generate a 16x16 RGB565 checker pattern as a byte vector.
///
/// @return  512 bytes (16x16 pixels x 2 bytes/pixel) in linear row-major
///          order, suitable for fill_texture() with TexFormat::RGB565.
static std::vector<uint8_t> generate_checker_texture() {
    constexpr int TEX_SIZE = 16;
    constexpr int BLOCK_SIZE = 4;
    std::vector<uint8_t> data(TEX_SIZE * TEX_SIZE * 2);

    for (int y = 0; y < TEX_SIZE; y++) {
        for (int x = 0; x < TEX_SIZE; x++) {
            int block_x = x / BLOCK_SIZE;
            int block_y = y / BLOCK_SIZE;
            uint16_t color = ((block_x + block_y) % 2 == 0) ? 0xFFFF : 0x0000;

            int idx = (y * TEX_SIZE + x) * 2;
            // Little-endian byte order
            data[idx + 0] = static_cast<uint8_t>(color & 0xFF);
            data[idx + 1] = static_cast<uint8_t>((color >> 8) & 0xFF);
        }
    }

    return data;
}

// ---------------------------------------------------------------------------
// VER-014 Constants
// ---------------------------------------------------------------------------

/// Texture base address (byte address, 4K aligned).
/// The SDRAM model maps even byte addresses to mem_[] indices 1:1 via
/// connect_sdram (word_addr = byte_addr for even addresses).  The 512x512
/// RGB565 framebuffer spans byte addresses 0x00000 through 0x7FFFE
/// (block_off up to 16383*32 + 30 = 0x7FFFE).  fill_texture() uses
/// compact word addressing (TEX0_BASE_WORD + offset), so TEX0_BASE_WORD
/// must be >= 0x80000 to avoid overlapping the framebuffer mem_[] range.
///
/// TEX0_BASE_ADDR = 0x100000 → TEX0_BASE_WORD = 0x80000 (past FB end).
/// TEX0_BASE_ADDR_512 = 0x0800.  This does NOT conflict with
/// ZBUFFER_BASE_512=0x0800 because the Z-buffer uses <<9 scaling
/// (fb_z_base * 512 = 0x100000 byte addr) while the texture cache uses
/// <<8 scaling (base_addr_512 * 256 = 0x80000 word addr).
static constexpr uint64_t TEX0_BASE_ADDR = 0x00100000ULL;
static constexpr uint16_t TEX0_BASE_ADDR_512 = static_cast<uint16_t>(TEX0_BASE_ADDR / 512);
static constexpr uint32_t TEX0_BASE_WORD = static_cast<uint32_t>(TEX0_BASE_ADDR / 2);

/// Z-buffer base address (same as VER-011).
static constexpr uint16_t ZBUFFER_BASE_512_014 = 0x0800;

/// Z-buffer clear RENDER_MODE (identical to VER-011 RENDER_MODE_ZCLEAR):
///   Z_TEST_EN=1 (bit 2), Z_WRITE_EN=1 (bit 3), COLOR_WRITE_EN=0,
///   Z_COMPARE=ALWAYS (3'b110 at bits [15:13]).
static constexpr uint64_t RENDER_MODE_ZCLEAR_014 =
    (1ULL << 2) |   // Z_TEST_EN
    (1ULL << 3) |   // Z_WRITE_EN
    (6ULL << 13);   // Z_COMPARE = ALWAYS (3'b110)

/// Textured depth-tested RENDER_MODE:
///   GOURAUD_EN=1 (bit 0), Z_TEST_EN=1 (bit 2), Z_WRITE_EN=1 (bit 3),
///   COLOR_WRITE_EN=1 (bit 4), Z_COMPARE=LEQUAL (3'b001 at bits [15:13]).
static constexpr uint64_t RENDER_MODE_TEXTURED_DEPTH =
    (1ULL << 0)  |   // GOURAUD_EN
    (1ULL << 2)  |   // Z_TEST_EN
    (1ULL << 3)  |   // Z_WRITE_EN
    (1ULL << 4)  |   // COLOR_WRITE_EN
    (1ULL << 13);    // Z_COMPARE = LEQUAL (3'b001)

// ---------------------------------------------------------------------------
// Vertex color constant: white diffuse, black specular
//
// All cube vertices use white color so the MODULATE combiner produces
// texture_color * 1.0 = texture_color, isolating texture sampling
// correctness from color arithmetic.
// ---------------------------------------------------------------------------

static constexpr uint64_t COLOR_WHITE = pack_color(rgba(0xFF, 0xFF, 0xFF), rgba(0x00, 0x00, 0x00));
static constexpr uint64_t COLOR_BLACK = pack_color(rgba(0x00, 0x00, 0x00), rgba(0x00, 0x00, 0x00));

// ---------------------------------------------------------------------------
// Cube vertex positions and Z values (screen space, after perspective
// projection onto 512x512 viewport)
//
// Unit cube centered at origin, camera at (0,0,3), 60-degree VFOV.
// After perspective division and viewport mapping:
//
// Front face (+Z, z_ndc nearest to camera):
//   TL = (128, 128), TR = (384, 128), BL = (128, 384), BR = (384, 384)
//   Z = 0x3800 (front-face vertices, nearest)
//
// Right face (+X, receding into depth on right side):
//   Near edge shares (384, 128) and (384, 384) with +Z face
//   Far edge: (448, 192) top, (448, 320) bottom
//   Near Z = 0x3800, Far Z = 0x4800
//
// Top face (+Y, receding upward into depth):
//   Near edge shares (128, 128) and (384, 128) with +Z face
//   Far edge: (192, 64) left, (320, 64) right
//   Near Z = 0x3800, Far Z = 0x4800
//
// Back faces (-Z, -X, -Y) are behind front faces and occluded by Z-test.
// Their Z values are larger (farther from camera).
//
// Back face (-Z, farthest):
//   TL = (192, 192), TR = (320, 192), BL = (192, 320), BR = (320, 320)
//   Z = 0x5800
//
// Left face (-X, receding into depth on left side):
//   Near edge: (128, 128), (128, 384)  Z = 0x3800
//   Far edge: (64, 192), (64, 320)     Z = 0x4800
//
// Bottom face (-Y, receding downward into depth):
//   Near edge: (128, 384), (384, 384)  Z = 0x3800
//   Far edge: (192, 448), (320, 448)   Z = 0x4800
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// VER-014 Z-Buffer Clear Script
//
// Configures the framebuffer and renders two screen-covering triangles
// (512x512) with Z=0xFFFF to initialize the Z-buffer.
// COLOR_WRITE is disabled so only the Z-buffer is modified.
// ---------------------------------------------------------------------------

static const RegWrite ver_014_zclear_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = ZBUFFER_BASE,
    //    width_log2 = 9, height_log2 = 9 (512x512 surface)
    {REG_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512_014, 9, 9)},

    // 2. Configure scissor to cover full 512x512 viewport
    {REG_FB_CONTROL, pack_fb_control(0, 0, 512, 512)},

    // 3. Set render mode: Z clear pass (ALWAYS compare, Z write only)
    {REG_RENDER_MODE, RENDER_MODE_ZCLEAR_014},

    // 4. Z-clear triangle 1: (0,0) - (511,0) - (0,511)
    {REG_AREA_SETUP, compute_area_setup(0, 0, 511, 0, 0, 511)},
    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_NOKICK, pack_vertex(0, 0, 0xFFFF)},

    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_NOKICK, pack_vertex(511, 0, 0xFFFF)},

    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_KICK_012, pack_vertex(0, 511, 0xFFFF)},

    // 5. Z-clear triangle 2: (511,0) - (511,511) - (0,511)
    {REG_AREA_SETUP, compute_area_setup(511, 0, 511, 511, 0, 511)},
    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_NOKICK, pack_vertex(511, 0, 0xFFFF)},

    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_NOKICK, pack_vertex(511, 511, 0xFFFF)},

    {REG_COLOR, COLOR_BLACK},
    {REG_VERTEX_KICK_012, pack_vertex(0, 511, 0xFFFF)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_014_zclear_script_len =
    sizeof(ver_014_zclear_script) / sizeof(ver_014_zclear_script[0]);

// ---------------------------------------------------------------------------
// VER-014 Setup Script
//
// Configures the texture unit and render mode for depth-tested textured
// rendering after the Z-buffer has been cleared.
// ---------------------------------------------------------------------------

static const RegWrite ver_014_setup_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = ZBUFFER_BASE,
    //    width_log2 = 9, height_log2 = 9
    {REG_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512_014, 9, 9)},

    // 2. Configure scissor to cover full 512x512 viewport
    {REG_FB_CONTROL, pack_fb_control(0, 0, 512, 512)},

    // 3. Configure TEX0: ENABLE=1, FILTER=NEAREST(0), FORMAT=RGB565(4),
    //    WIDTH_LOG2=4, HEIGHT_LOG2=4, WRAP=REPEAT(0), MIP_LEVELS=0 (=1 level),
    //    BASE_ADDR=TEX0_BASE_ADDR_512
    {REG_TEX0_CFG, pack_tex0_cfg(
        1,                    // ENABLE
        0,                    // FILTER = NEAREST
        4,                    // FORMAT = RGB565
        4,                    // WIDTH_LOG2 (16px)
        4,                    // HEIGHT_LOG2 (16px)
        0,                    // U_WRAP = REPEAT
        0,                    // V_WRAP = REPEAT
        0,                    // MIP_LEVELS = 0 (1 mip level)
        TEX0_BASE_ADDR_512   // BASE_ADDR in 512-byte units
    )},

    // 4. Set render mode: depth-tested textured rendering
    {REG_RENDER_MODE, RENDER_MODE_TEXTURED_DEPTH},

    // Dummy trailing command
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_014_setup_script_len =
    sizeof(ver_014_setup_script) / sizeof(ver_014_setup_script[0]);

// ---------------------------------------------------------------------------
// VER-014 Cube Triangle Script
//
// Twelve triangles (two per face, six faces).
// Submitted in painter's order: back faces first, front faces last.
//
// Face order (back to front):
//   -Z (back face, farthest)
//   -X (left face, back half receding)
//   -Y (bottom face, back half receding)
//   +X (right face, front half visible)
//   +Y (top face, front half visible)
//   +Z (front face, nearest)
//
// Each triangle:
//   AREA_SETUP (pre-computed bounding box and area normalization)
//   V0: COLOR (white), UV0_UV1, VERTEX_NOKICK
//   V1: COLOR (white), UV0_UV1, VERTEX_NOKICK
//   V2: COLOR (white), UV0_UV1, VERTEX_KICK_012 or VERTEX_KICK_021
//
// UV coordinates map the full [0,1] checker pattern onto each face.
//
// Winding:
//   Front-facing triangles use CCW winding → VERTEX_KICK_012
//   Back-facing triangles (viewed from behind) use CW winding
//   → VERTEX_KICK_021 to reverse into CCW for the rasterizer
// ---------------------------------------------------------------------------

static const RegWrite ver_014_triangles_script[] = {

    // =======================================================================
    // Face 1: -Z (back face, Z=0x5800)
    //   TL=(192,192) TR=(320,192) BL=(192,320) BR=(320,320)
    //   Viewed from behind, vertices are CW → use KICK_021
    // =======================================================================

    // Triangle 1: TL-BL-TR → (192,192)-(192,320)-(320,192)
    {REG_AREA_SETUP, compute_area_setup(192, 192, 192, 320, 320, 192)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(192, 192, 0x5800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(192, 320, 0x5800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(320, 192, 0x5800)},

    // Triangle 2: TR-BL-BR → (320,192)-(192,320)-(320,320)
    {REG_AREA_SETUP, compute_area_setup(320, 192, 192, 320, 320, 320)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(320, 192, 0x5800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(192, 320, 0x5800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(320, 320, 0x5800)},

    // =======================================================================
    // Face 2: -X (left face)
    //   Near: (128,128) Z=0x3800, (128,384) Z=0x3800
    //   Far:  (64,192)  Z=0x4800, (64,320)  Z=0x4800
    //   Viewed from behind → KICK_021
    // =======================================================================

    // Triangle 3: (128,128)-(64,192)-(128,384)
    {REG_AREA_SETUP, compute_area_setup(128, 128, 64, 192, 128, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(128, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(64, 192, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(128, 384, 0x3800)},

    // Triangle 4: (64,192)-(64,320)-(128,384)
    {REG_AREA_SETUP, compute_area_setup(64, 192, 64, 320, 128, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(64, 192, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(64, 320, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(128, 384, 0x3800)},

    // =======================================================================
    // Face 3: -Y (bottom face)
    //   Near: (128,384) Z=0x3800, (384,384) Z=0x3800
    //   Far:  (192,448) Z=0x4800, (320,448) Z=0x4800
    //   Viewed from below → KICK_021
    // =======================================================================

    // Triangle 5: (128,384)-(384,384)-(192,448)
    {REG_AREA_SETUP, compute_area_setup(128, 384, 384, 384, 192, 448)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(128, 384, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 384, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(192, 448, 0x4800)},

    // Triangle 6: (384,384)-(320,448)-(192,448)
    {REG_AREA_SETUP, compute_area_setup(384, 384, 320, 448, 192, 448)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 384, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(320, 448, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_021, pack_vertex(192, 448, 0x4800)},

    // =======================================================================
    // Face 4: +X (right face, front-visible)
    //   Near: (384,128) Z=0x3800, (384,384) Z=0x3800
    //   Far:  (448,192) Z=0x4800, (448,320) Z=0x4800
    //   Front-facing → CCW winding → KICK_012
    // =======================================================================

    // Triangle 7: (384,128)-(448,192)-(384,384)
    {REG_AREA_SETUP, compute_area_setup(384, 128, 448, 192, 384, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(448, 192, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(384, 384, 0x3800)},

    // Triangle 8: (448,192)-(448,320)-(384,384)
    {REG_AREA_SETUP, compute_area_setup(448, 192, 448, 320, 384, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(448, 192, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(448, 320, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(384, 384, 0x3800)},

    // =======================================================================
    // Face 5: +Y (top face, front-visible)
    //   Near: (128,128) Z=0x3800, (384,128) Z=0x3800
    //   Far:  (192,64)  Z=0x4800, (320,64)  Z=0x4800
    //   Front-facing → CCW winding → KICK_012
    // =======================================================================

    // Triangle 9: (128,128)-(384,128)-(192,64)
    {REG_AREA_SETUP, compute_area_setup(128, 128, 384, 128, 192, 64)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(128, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.5f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(192, 64, 0x4800)},

    // Triangle 10: (384,128)-(320,64)-(192,64)
    {REG_AREA_SETUP, compute_area_setup(384, 128, 320, 64, 192, 64)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(320, 64, 0x4800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.5f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(192, 64, 0x4800)},

    // =======================================================================
    // Face 6: +Z (front face, nearest, Z=0x3800)
    //   TL=(128,128) TR=(384,128) BL=(128,384) BR=(384,384)
    //   Front-facing → CCW winding → KICK_012
    // =======================================================================

    // Triangle 11: (128,128)-(384,128)-(128,384)
    {REG_AREA_SETUP, compute_area_setup(128, 128, 384, 128, 128, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(128, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(128, 384, 0x3800)},

    // Triangle 12: (384,128)-(384,384)-(128,384)
    {REG_AREA_SETUP, compute_area_setup(384, 128, 384, 384, 128, 384)},
    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 0.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 128, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(1.0f, 1.0f)},
    {REG_VERTEX_NOKICK, pack_vertex(384, 384, 0x3800)},

    {REG_COLOR, COLOR_WHITE},
    {REG_UV0_UV1, pack_uv(0.0f, 1.0f)},
    {REG_VERTEX_KICK_012, pack_vertex(128, 384, 0x3800)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_014_triangles_script_len =
    sizeof(ver_014_triangles_script) / sizeof(ver_014_triangles_script[0]);
