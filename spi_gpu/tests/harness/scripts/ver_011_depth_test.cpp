// VER-011: Depth-Tested Overlapping Triangles — command script
//
// Encodes the register-write sequence for the depth-tested overlapping
// triangles test defined in doc/verification/ver_011_depth_tested_triangles.md.
//
// The test renders two overlapping flat-colored triangles at different depths.
// Triangle A (far, red, Z=0x8000) is rendered first; Triangle B (near, blue,
// Z=0x4000) is rendered second.  In the overlap region, Triangle B must
// occlude Triangle A because its Z value is smaller (nearer).
//
// Before rendering, a Z-buffer clear pass initializes the entire Z-buffer to
// 0xFFFF using the ALWAYS compare mode.
//
// The script is split into three sub-arrays:
//   ver_011_zclear_script  — Z-buffer clear pass (full-screen triangle, Z=0xFFFF)
//   ver_011_tri_a_script   — Triangle A (far, red)
//   ver_011_tri_b_script   — Triangle B (near, blue)
//
// The harness runs them sequentially with idle cycles between each to ensure
// the pipeline drains before the next batch of register writes.
//
// Register write sequence per INT-021 RenderMeshPatch:
//   1. FB_CONFIG     — framebuffer surface dimensions, color base, Z base
//   2. FB_CONTROL    — scissor rectangle covering the full viewport
//   3. RENDER_MODE   — Z clear: Z_TEST=1, Z_WRITE=1, Z_COMPARE=ALWAYS, COLOR_WRITE=0
//   4. Z-clear triangle covering the full screen with Z=0xFFFF
//   5. (pipeline idle)
//   6. RENDER_MODE   — depth-tested: GOURAUD=1, Z_TEST=1, Z_WRITE=1, COLOR_WRITE=1,
//   Z_COMPARE=LEQUAL
//   7. Triangle A vertices (red, Z=0x8000)
//   8. (pipeline idle)
//   9. Triangle B vertices (blue, Z=0x4000)
//
// References:
//   VER-011 (Depth-Tested Overlapping Triangles Golden Image Test)
//   UNIT-003 (Register File) — register addresses and data packing
//   UNIT-006 (Pixel Pipeline) — early Z-test path
//   INT-010 (GPU Register Map) — register definitions
//   INT-021 (Render Command Format) — command sequence

// This file is #include'd from harness.cpp after the RegWrite struct
// definition and the ver_010_gouraud.cpp script (which provides the
// helper functions and register address constants).
// <cstdint> is already included by harness.cpp.

// ---------------------------------------------------------------------------
// RENDER_MODE encoding helpers for VER-011
//
// From register_file.sv ADDR_RENDER_MODE decode and early_z.sv:
//   [0]      = GOURAUD_EN
//   [2]      = Z_TEST_EN
//   [3]      = Z_WRITE_EN
//   [4]      = COLOR_WRITE_EN
//   [15:13]  = Z_COMPARE (3-bit function code)
//
// Z compare function codes (from early_z.sv localparams):
//   3'b000 = LESS
//   3'b001 = LEQUAL
//   3'b010 = EQUAL
//   3'b011 = GEQUAL
//   3'b100 = GREATER
//   3'b101 = NOTEQUAL
//   3'b110 = ALWAYS
//   3'b111 = NEVER
// ---------------------------------------------------------------------------

/// Z-buffer clear pass RENDER_MODE:
///   Z_TEST_EN=1 (bit 2), Z_WRITE_EN=1 (bit 3), COLOR_WRITE_EN=0 (bit 4),
///   Z_COMPARE=ALWAYS (3'b110 = 6, shifted to bits [15:13]).
/// Encoding: (1<<2) | (1<<3) | (6<<13) = 0x04 | 0x08 | 0xC000 = 0xC00C.
static constexpr uint64_t RENDER_MODE_ZCLEAR = (1ULL << 2) | // Z_TEST_EN
                                               (1ULL << 3) | // Z_WRITE_EN
                                               (6ULL << 13); // Z_COMPARE = ALWAYS (3'b110)

/// Depth-tested rendering RENDER_MODE:
///   GOURAUD_EN=1 (bit 0), Z_TEST_EN=1 (bit 2), Z_WRITE_EN=1 (bit 3),
///   COLOR_WRITE_EN=1 (bit 4), Z_COMPARE=LEQUAL (3'b001 = 1, bits [15:13]).
/// Encoding: (1<<0) | (1<<2) | (1<<3) | (1<<4) | (1<<13) = 0x001D | 0x2000 = 0x201D.
static constexpr uint64_t RENDER_MODE_DEPTH_TEST = (1ULL << 0) | // GOURAUD_EN
                                                   (1ULL << 2) | // Z_TEST_EN
                                                   (1ULL << 3) | // Z_WRITE_EN
                                                   (1ULL << 4) | // COLOR_WRITE_EN
                                                   (1ULL << 13); // Z_COMPARE = LEQUAL (3'b001)

// ---------------------------------------------------------------------------
// Z-buffer base address (INT-011 memory map)
//
// ZBUFFER_ADDR = 0x100000 (byte address)
// In 512-byte units for FB_CONFIG Z_BASE field: 0x100000 >> 9 = 0x800
// ---------------------------------------------------------------------------

static constexpr uint16_t ZBUFFER_BASE_512 = 0x0800;

// ---------------------------------------------------------------------------
// VER-011 Z-Buffer Clear Script
//
// Configures the framebuffer, sets Z_COMPARE=ALWAYS with Z_WRITE enabled,
// and renders a screen-covering triangle with Z=0xFFFF at all vertices.
// COLOR_WRITE is disabled so only the Z-buffer is modified.
//
// The clear triangle covers the full 512x480 visible area:
//   V0 = (0, 0)      — top-left corner
//   V1 = (511, 0)    — top-right corner
//   V2 = (0, 479)    — bottom-left corner
//
// This is not a full-screen quad; it covers the lower-left half of the
// viewport.  Two triangles are used to form a rectangle covering the
// full viewport.
//
// NOTE: To guarantee full Z-buffer coverage, we use two triangles that
// together form a rectangle covering the full viewport.
// ---------------------------------------------------------------------------

static const RegWrite ver_011_zclear_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = 0x800 (ZBUFFER_ADDR),
    //    width_log2 = 9 (512-wide surface), height_log2 = 9
    {REG_FB_CONFIG, pack_fb_config(0x0000, ZBUFFER_BASE_512, 9, 9)},

    // 2. Configure scissor to cover full 512x480 viewport
    {REG_FB_CONTROL, pack_fb_control(0, 0, 512, 480)},

    // 3. Set render mode: Z clear pass (ALWAYS compare, Z write only)
    {REG_RENDER_MODE, RENDER_MODE_ZCLEAR},

    // 4. Z-clear triangle covering the screen: all vertices use black color
    //    (irrelevant since COLOR_WRITE=0) and Z=0xFFFF.
    //
    //    Triangle 1: (0,0) - (511,0) - (0,479) covers lower-left half
    {REG_AREA_SETUP, compute_area_setup(0, 0, 511, 0, 0, 479)},
    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(0, 0, 0xFFFF)},

    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(511, 0, 0xFFFF)},

    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex(0, 479, 0xFFFF)},

    //    Triangle 2: (511,0) - (511,479) - (0,479) covers upper-right half
    {REG_AREA_SETUP, compute_area_setup(511, 0, 511, 479, 0, 479)},
    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(511, 0, 0xFFFF)},

    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(511, 479, 0xFFFF)},

    {REG_COLOR, pack_color(argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex(0, 479, 0xFFFF)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_011_zclear_script_len =
    sizeof(ver_011_zclear_script) / sizeof(ver_011_zclear_script[0]);

// ---------------------------------------------------------------------------
// VER-011 Triangle A Script (far, red, Z=0x8000)
//
// Configures RENDER_MODE for depth-tested Gouraud rendering (LEQUAL), then
// submits Triangle A with flat red color at all vertices.
//
// Vertex positions (screen-space integer coordinates, scaled for 512-wide FB):
//   A0: (80, 100)    — top left
//   A1: (320, 100)   — top right
//   A2: (200, 380)   — bottom center
// ---------------------------------------------------------------------------

static const RegWrite ver_011_tri_a_script[] = {
    // 1. Set render mode: depth-tested Gouraud rendering
    {REG_RENDER_MODE, RENDER_MODE_DEPTH_TEST},

    // 1b. Set AREA_SETUP for Triangle A: (80,100)-(320,100)-(200,380)
    {REG_AREA_SETUP, compute_area_setup(80, 100, 320, 100, 200, 380)},

    // 2. Submit V0: red at (80, 100), Z=0x8000
    {REG_COLOR, pack_color(argb(0xFF, 0x00, 0x00), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(80, 100, 0x8000)},

    // 3. Submit V1: red at (320, 100), Z=0x8000
    {REG_COLOR, pack_color(argb(0xFF, 0x00, 0x00), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(320, 100, 0x8000)},

    // 4. Submit V2: red at (200, 380), Z=0x8000
    //    VERTEX_KICK_012 triggers rasterization of Triangle A (V0, V1, V2).
    {REG_COLOR, pack_color(argb(0xFF, 0x00, 0x00), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex(200, 380, 0x8000)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_011_tri_a_script_len =
    sizeof(ver_011_tri_a_script) / sizeof(ver_011_tri_a_script[0]);

// ---------------------------------------------------------------------------
// VER-011 Triangle B Script (near, blue, Z=0x4000)
//
// Submits Triangle B with flat blue color at all vertices.
// RENDER_MODE is already configured from Triangle A (LEQUAL, depth-tested).
//
// Vertex positions (screen-space integer coordinates, scaled for 512-wide FB):
//   B0: (160, 80)    — top left
//   B1: (400, 80)    — top right
//   B2: (280, 360)   — bottom center
// ---------------------------------------------------------------------------

static const RegWrite ver_011_tri_b_script[] = {
    // 0b. Set AREA_SETUP for Triangle B: (160,80)-(400,80)-(280,360)
    {REG_AREA_SETUP, compute_area_setup(160, 80, 400, 80, 280, 360)},

    // 1. Submit V0: blue at (160, 80), Z=0x4000
    {REG_COLOR, pack_color(argb(0x00, 0x00, 0xFF), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(160, 80, 0x4000)},

    // 2. Submit V1: blue at (400, 80), Z=0x4000
    {REG_COLOR, pack_color(argb(0x00, 0x00, 0xFF), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_NOKICK, pack_vertex(400, 80, 0x4000)},

    // 3. Submit V2: blue at (280, 360), Z=0x4000
    //    VERTEX_KICK_012 triggers rasterization of Triangle B (V0, V1, V2).
    {REG_COLOR, pack_color(argb(0x00, 0x00, 0xFF), argb(0x00, 0x00, 0x00))},
    {REG_VERTEX_KICK_012, pack_vertex(280, 360, 0x4000)},

    // Dummy trailing command — see ver_010_gouraud.cpp for rationale.
    {REG_COLOR, 0x0000000000000000ULL},
};

static constexpr size_t ver_011_tri_b_script_len =
    sizeof(ver_011_tri_b_script) / sizeof(ver_011_tri_b_script[0]);
