// VER-010: Gouraud Triangle Golden Image Test — command script
//
// Encodes the register-write sequence for a single Gouraud-shaded triangle
// with red (top), green (bottom-left), and blue (bottom-right) vertices.
//
// The register addresses and data packing are verified against the RTL
// implementation in register_file.sv (UNIT-003) and rasterizer.sv (UNIT-005).
//
// Register write sequence per INT-021 RenderMeshPatch:
//   1. FB_CONFIG   — framebuffer surface dimensions and base addresses
//   2. FB_CONTROL  — scissor rectangle covering the full viewport
//   3. RENDER_MODE — Gouraud shading + color write, no Z
//   4. COLOR + VERTEX_NOKICK  — V0 (red, top center)
//   5. COLOR + VERTEX_NOKICK  — V1 (green, bottom left)
//   6. COLOR + VERTEX_KICK_012 — V2 (blue, bottom right) — triggers rasterization
//
// References:
//   VER-010 (Gouraud Triangle Golden Image Test)
//   UNIT-003 (Register File) — register addresses and data packing
//   INT-010 (GPU Register Map) — register definitions
//   INT-021 (Render Command Format) — command sequence

#include <cstdint>

// This file is #include'd from harness.cpp after the RegWrite struct
// definition.  It provides the VER-010 command script array.

// ---------------------------------------------------------------------------
// INT-010 Register Addresses (verified against register_file.sv localparams)
// ---------------------------------------------------------------------------

static constexpr uint8_t REG_COLOR            = 0x00;  // ADDR_COLOR
static constexpr uint8_t REG_VERTEX_NOKICK    = 0x06;  // ADDR_VERTEX_NOKICK
static constexpr uint8_t REG_VERTEX_KICK_012  = 0x07;  // ADDR_VERTEX_KICK_012
static constexpr uint8_t REG_RENDER_MODE      = 0x30;  // ADDR_RENDER_MODE
static constexpr uint8_t REG_FB_CONFIG        = 0x40;  // ADDR_FB_CONFIG
static constexpr uint8_t REG_FB_CONTROL       = 0x43;  // ADDR_FB_CONTROL

// ---------------------------------------------------------------------------
// VERTEX data packing (from register_file.sv ADDR_VERTEX_NOKICK decode):
//
//   cmd_wdata[15:0]  = X  (Q12.4 signed fixed-point)
//   cmd_wdata[31:16] = Y  (Q12.4 signed fixed-point)
//   cmd_wdata[47:32] = Z  (16-bit unsigned)
//   cmd_wdata[63:48] = Q  (1/W, Q1.15 signed fixed-point)
//
// Q12.4 encoding: integer_value * 16 (shift left 4 bits).
// ---------------------------------------------------------------------------

/// Pack screen-space coordinates into VERTEX register format.
///
/// @param x  Screen X coordinate (integer pixels).
/// @param y  Screen Y coordinate (integer pixels).
/// @param z  Depth value (16-bit unsigned, 0 = near).
/// @return   64-bit packed vertex data for VERTEX_NOKICK or VERTEX_KICK_012.
static constexpr uint64_t pack_vertex(int x, int y, uint16_t z) {
    uint16_t x_q12_4 = static_cast<uint16_t>(x * 16);  // Q12.4 fixed-point
    uint16_t y_q12_4 = static_cast<uint16_t>(y * 16);  // Q12.4 fixed-point
    uint16_t q       = 0;                               // 1/W = 0 (not used)
    return (static_cast<uint64_t>(q)       << 48) |
           (static_cast<uint64_t>(z)       << 32) |
           (static_cast<uint64_t>(y_q12_4) << 16) |
           (static_cast<uint64_t>(x_q12_4));
}

// ---------------------------------------------------------------------------
// COLOR register packing (from register_file.sv ADDR_COLOR decode):
//
//   current_color0[63:32] → vertex_color0 (diffuse, connected to rasterizer)
//   current_color0[31:0]  → vertex_color1 (specular, secondary)
//
// The rasterizer reads v0_color[23:0] from tri_color0 = vertex_color0:
//   [23:16] = R,  [15:8] = G,  [7:0] = B
//
// So the upper 32-bit word uses ARGB byte order:
//   {A[31:24], R[23:16], G[15:8], B[7:0]}
// ---------------------------------------------------------------------------

/// Pack an ARGB8888 color value.
///
/// @param r  Red channel (0-255).
/// @param g  Green channel (0-255).
/// @param b  Blue channel (0-255).
/// @param a  Alpha channel (0-255).
/// @return   32-bit ARGB value.
static constexpr uint32_t argb(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 0xFF) {
    return (static_cast<uint32_t>(a) << 24) |
           (static_cast<uint32_t>(r) << 16) |
           (static_cast<uint32_t>(g) << 8)  |
           (static_cast<uint32_t>(b));
}

/// Pack diffuse (primary) and specular (secondary) colors into the 64-bit
/// COLOR register format.
///
/// @param diffuse   32-bit ARGB primary color (goes into [63:32]).
/// @param specular  32-bit ARGB secondary color (goes into [31:0]).
/// @return          64-bit packed COLOR register value.
static constexpr uint64_t pack_color(uint32_t diffuse, uint32_t specular = 0xFF000000) {
    return (static_cast<uint64_t>(diffuse) << 32) |
           (static_cast<uint64_t>(specular));
}

// ---------------------------------------------------------------------------
// FB_CONFIG register packing (from register_file.sv ADDR_FB_CONFIG decode):
//
//   [15:0]   = fb_color_base  (x512 byte address)
//   [31:16]  = fb_z_base      (x512 byte address)
//   [35:32]  = fb_width_log2  (log2 of surface width)
//   [39:36]  = fb_height_log2 (log2 of surface height)
// ---------------------------------------------------------------------------

/// Pack FB_CONFIG register value.
///
/// @param color_base   Color buffer base address (in 512-byte units).
/// @param z_base       Z buffer base address (in 512-byte units).
/// @param width_log2   Log2 of surface width (e.g. 9 for 512).
/// @param height_log2  Log2 of surface height (e.g. 9 for 512).
/// @return             64-bit FB_CONFIG register value.
static constexpr uint64_t pack_fb_config(uint16_t color_base, uint16_t z_base,
                                          uint8_t width_log2, uint8_t height_log2) {
    return (static_cast<uint64_t>(height_log2 & 0xF) << 36) |
           (static_cast<uint64_t>(width_log2  & 0xF) << 32) |
           (static_cast<uint64_t>(z_base) << 16) |
           (static_cast<uint64_t>(color_base));
}

// ---------------------------------------------------------------------------
// FB_CONTROL register packing (from register_file.sv ADDR_FB_CONTROL decode):
//
//   [9:0]    = scissor_x      (scissor X origin)
//   [19:10]  = scissor_y      (scissor Y origin)
//   [29:20]  = scissor_width  (scissor width in pixels)
//   [39:30]  = scissor_height (scissor height in pixels)
// ---------------------------------------------------------------------------

/// Pack FB_CONTROL (scissor) register value.
///
/// @param x       Scissor X origin.
/// @param y       Scissor Y origin.
/// @param width   Scissor width in pixels.
/// @param height  Scissor height in pixels.
/// @return        64-bit FB_CONTROL register value.
static constexpr uint64_t pack_fb_control(uint16_t x, uint16_t y,
                                           uint16_t width, uint16_t height) {
    return (static_cast<uint64_t>(height & 0x3FF) << 30) |
           (static_cast<uint64_t>(width  & 0x3FF) << 20) |
           (static_cast<uint64_t>(y      & 0x3FF) << 10) |
           (static_cast<uint64_t>(x      & 0x3FF));
}

// ---------------------------------------------------------------------------
// RENDER_MODE encoding (from register_file.sv ADDR_RENDER_MODE decode):
//
//   [0]     = GOURAUD_EN
//   [2]     = Z_TEST_EN
//   [3]     = Z_WRITE_EN
//   [4]     = COLOR_WRITE_EN
// ---------------------------------------------------------------------------

static constexpr uint64_t RENDER_MODE_GOURAUD_COLOR =
    (1ULL << 0) |   // GOURAUD_EN = 1
    (1ULL << 4);    // COLOR_WRITE_EN = 1
    // Z_TEST_EN = 0, Z_WRITE_EN = 0, all other bits = 0

// ---------------------------------------------------------------------------
// VER-010 Command Script
// ---------------------------------------------------------------------------

// Vertex positions (screen-space integer coordinates):
//   V0: (320, 40)   — top center      — red
//   V1: (80, 400)   — bottom left     — green
//   V2: (560, 400)  — bottom right    — blue

static const RegWrite ver_010_script[] = {
    // 1. Configure framebuffer: color base = 0, z base = 0,
    //    width_log2 = 9 (512-wide surface), height_log2 = 9
    {REG_FB_CONFIG,  pack_fb_config(0x0000, 0x0000, 9, 9)},

    // 2. Configure scissor to cover full 640x480 viewport
    //    (default reset value has height=0 which would clip everything)
    {REG_FB_CONTROL, pack_fb_control(0, 0, 640, 480)},

    // 3. Set render mode: Gouraud shading + color write, no Z test/write
    {REG_RENDER_MODE, RENDER_MODE_GOURAUD_COLOR},

    // 4. Submit V0: red vertex at top center (320, 40)
    {REG_COLOR,          pack_color(argb(0xFF, 0x00, 0x00))},  // Red diffuse
    {REG_VERTEX_NOKICK,  pack_vertex(320, 40, 0x0000)},

    // 5. Submit V1: green vertex at bottom left (80, 400)
    {REG_COLOR,          pack_color(argb(0x00, 0xFF, 0x00))},  // Green diffuse
    {REG_VERTEX_NOKICK,  pack_vertex(80, 400, 0x0000)},

    // 6. Submit V2: blue vertex at bottom right (560, 400)
    //    VERTEX_KICK_012 triggers rasterization of the triangle (V0, V1, V2).
    {REG_COLOR,          pack_color(argb(0x00, 0x00, 0xFF))},  // Blue diffuse
    {REG_VERTEX_KICK_012, pack_vertex(560, 400, 0x0000)},
};

static constexpr size_t ver_010_script_len =
    sizeof(ver_010_script) / sizeof(ver_010_script[0]);
