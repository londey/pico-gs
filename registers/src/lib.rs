//! GPU register addresses and bit-field constants.
//!
//! Single source of truth for the ICEpi SPI GPU register map v10.0 (INT-010).
//!
//! This crate is `no_std` compatible.  Eventually the contents will be
//! generated from `registers/rdl/gpu_regs.rdl` via PeakRDL; for now the
//! definitions are maintained by hand and must match the specification in
//! `registers/doc/int_010_gpu_register_map.md`.

#![no_std]

// --- Vertex State (0x00-0x0F) ---

/// Vertex color register: Diffuse\[63:32\] + Specular\[31:0\] (RGBA8888 per color).
///
/// Latched for the next VERTEX write.
pub const COLOR: u8 = 0x00;

/// Packed UV coordinates for texture units 0 and 1.
///
/// \[63:48\] UV1_VQ, \[47:32\] UV1_UQ, \[31:16\] UV0_VQ, \[15:0\] UV0_UQ
/// (Q1.15 signed fixed-point, perspective-correct).
pub const UV0_UV1: u8 = 0x01;

/// Light direction vector for DOT3 bump mapping (X8Y8Z8).
pub const LIGHT_DIR: u8 = 0x03;

/// Vertex position + 1/W, no triangle draw.
///
/// Buffers the vertex without triggering rasterization.
/// Used for triangle strips, fans, or explicit submission.
pub const VERTEX_NOKICK: u8 = 0x06;

/// Vertex position + 1/W, draw triangle (v\[0\], v\[1\], v\[2\]).
///
/// Standard winding order (CCW in screen space).
pub const VERTEX_KICK_012: u8 = 0x07;

/// Vertex position + 1/W, draw triangle (v\[0\], v\[2\], v\[1\]).
///
/// Reversed winding order; used for triangle strip alternation.
pub const VERTEX_KICK_021: u8 = 0x08;

/// Vertex position + 1/W, two-corner rectangle emit.
pub const VERTEX_KICK_RECT: u8 = 0x09;

// --- Texture Configuration (0x10-0x17) ---
//
// Each texture unit has 4 registers.  Any write to a texture configuration
// register invalidates the texture cache for the corresponding unit.

/// Texture unit 0 base address (4K aligned).
pub const TEX0_BASE: u8 = 0x10;

/// Texture unit 0 format, dimensions, swizzle, filter, mipmap levels.
pub const TEX0_FMT: u8 = 0x11;

/// Texture unit 0 mipmap LOD bias (signed Q6.2 in bits \[7:0\]).
pub const TEX0_MIP_BIAS: u8 = 0x12;

/// Texture unit 0 UV wrapping mode (V_WRAP\[3:2\], U_WRAP\[1:0\]).
pub const TEX0_WRAP: u8 = 0x13;

/// Texture unit 1 base address (4K aligned).
pub const TEX1_BASE: u8 = 0x14;

/// Texture unit 1 format, dimensions, swizzle, filter, mipmap levels.
pub const TEX1_FMT: u8 = 0x15;

/// Texture unit 1 mipmap LOD bias (signed Q6.2 in bits \[7:0\]).
pub const TEX1_MIP_BIAS: u8 = 0x16;

/// Texture unit 1 UV wrapping mode (V_WRAP\[3:2\], U_WRAP\[1:0\]).
pub const TEX1_WRAP: u8 = 0x17;

// --- Backward-compatible aliases for unified TEXn_CFG ---
// These aliases map to the first register in each texture unit's block
// (TEXn_BASE) for code that used the old unified TEX0_CFG / TEX1_CFG names.

/// Backward-compatible alias for `TEX0_BASE`.
#[deprecated(note = "use TEX0_BASE (0x10) instead")]
pub const TEX0_CFG: u8 = TEX0_BASE;

/// Backward-compatible alias for `TEX1_BASE`.
#[deprecated(note = "use TEX1_BASE (0x14) instead")]
pub const TEX1_CFG: u8 = TEX1_BASE;

// --- TEXn_FMT bit fields (INT-010 TEXn_FMT at 0x11, 0x15) ---

/// Texture enable (bit 0).
pub const TEX_FMT_ENABLE: u64 = 1 << 0;

/// Texture format (bits \[3:2\]).
pub const TEX_FMT_FORMAT_SHIFT: u32 = 2;

/// Texture filter mode (bits \[7:6\]).
pub const TEX_FMT_FILTER_SHIFT: u32 = 6;

/// Width log2 (bits \[11:8\]).
pub const TEX_FMT_WIDTH_LOG2_SHIFT: u32 = 8;

/// Height log2 (bits \[15:12\]).
pub const TEX_FMT_HEIGHT_LOG2_SHIFT: u32 = 12;

/// Swizzle pattern (bits \[19:16\]).
pub const TEX_FMT_SWIZZLE_SHIFT: u32 = 16;

/// Mipmap level count (bits \[23:20\]).
pub const TEX_FMT_MIP_LEVELS_SHIFT: u32 = 20;

// --- Backward-compatible aliases for old TEX_CFG field names ---

/// Backward-compatible alias for `TEX_FMT_ENABLE`.
#[deprecated(note = "use TEX_FMT_ENABLE instead")]
pub const TEX_CFG_ENABLE: u64 = TEX_FMT_ENABLE;

/// Backward-compatible alias for `TEX_FMT_FILTER_SHIFT`.
#[deprecated(note = "use TEX_FMT_FILTER_SHIFT instead")]
pub const TEX_CFG_FILTER_SHIFT: u32 = TEX_FMT_FILTER_SHIFT;

/// Backward-compatible alias for `TEX_FMT_FORMAT_SHIFT`.
#[deprecated(note = "use TEX_FMT_FORMAT_SHIFT instead")]
pub const TEX_CFG_FORMAT_SHIFT: u32 = TEX_FMT_FORMAT_SHIFT;

/// Backward-compatible alias for `TEX_FMT_WIDTH_LOG2_SHIFT`.
#[deprecated(note = "use TEX_FMT_WIDTH_LOG2_SHIFT instead")]
pub const TEX_CFG_WIDTH_LOG2_SHIFT: u32 = TEX_FMT_WIDTH_LOG2_SHIFT;

/// Backward-compatible alias for `TEX_FMT_HEIGHT_LOG2_SHIFT`.
#[deprecated(note = "use TEX_FMT_HEIGHT_LOG2_SHIFT instead")]
pub const TEX_CFG_HEIGHT_LOG2_SHIFT: u32 = TEX_FMT_HEIGHT_LOG2_SHIFT;

/// Backward-compatible alias (removed: wrap is now in TEXn_WRAP).
#[deprecated(note = "wrap mode is now in TEXn_WRAP register")]
pub const TEX_CFG_U_WRAP_SHIFT: u32 = 16;

/// Backward-compatible alias (removed: wrap is now in TEXn_WRAP).
#[deprecated(note = "wrap mode is now in TEXn_WRAP register")]
pub const TEX_CFG_V_WRAP_SHIFT: u32 = 18;

/// Backward-compatible alias (removed: mip levels now in TEXn_FMT).
#[deprecated(note = "use TEX_FMT_MIP_LEVELS_SHIFT instead")]
pub const TEX_CFG_MIP_LEVELS_SHIFT: u32 = TEX_FMT_MIP_LEVELS_SHIFT;

/// Backward-compatible alias (removed: base addr is now in TEXn_BASE).
#[deprecated(note = "base address is now in TEXn_BASE register")]
pub const TEX_CFG_BASE_ADDR_SHIFT: u32 = 32;

/// Texture format (TEXn_FMT\[3:2\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TexFormat {
    /// 16 bpp RGBA4444 (see INT-014).
    Rgba4444 = 0,

    /// 4 bpp block compressed BC1 (see INT-014).
    Bc1 = 1,
}

/// Texture filter mode (TEXn_FMT\[7:6\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TexFilter {
    /// No interpolation (sharp, pixelated).
    Nearest = 0,

    /// 2x2 tap bilinear filter.
    Bilinear = 1,

    /// Mipmap blend (requires MIP_LEVELS > 1).
    Trilinear = 2,
}

/// UV coordinate wrap mode (TEXn_WRAP U_WRAP/V_WRAP).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum WrapMode {
    /// Wrap around.
    Repeat = 0,

    /// Clamp to edge.
    ClampToEdge = 1,

    /// Clamp to zero (out of bounds = transparent).
    ClampToZero = 2,

    /// Reflect at boundaries.
    Mirror = 3,
}

// --- Color Combiner (0x18-0x1F) ---

/// Color combiner mode and input selection.
///
/// Two-stage combiner: cycle 0 in \[31:0\], cycle 1 in \[63:32\].
/// Equation per cycle: `result = (A - B) * C + D`.
pub const CC_MODE: u8 = 0x18;

/// Constant colors 0 + 1 packed.
///
/// \[31:0\] = CONST0 (RGBA8888), \[63:32\] = CONST1/fog color (RGBA8888).
pub const CONST_COLOR: u8 = 0x19;

// --- Rendering Configuration (0x30-0x3F) ---

/// Unified rendering state register (v10.0).
///
/// Combines gouraud, Z-test/write, color write, cull mode, alpha blend,
/// dithering, Z compare, stipple, and alpha test fields.
pub const RENDER_MODE: u8 = 0x30;

/// Backward-compatible alias for `RENDER_MODE`.
#[deprecated(note = "use RENDER_MODE instead")]
pub const TRI_MODE: u8 = RENDER_MODE;

/// Depth range clipping (Z scissor) min/max register.
///
/// \[31:16\] Z_RANGE_MAX, \[15:0\] Z_RANGE_MIN (16-bit unsigned, inclusive).
pub const Z_RANGE: u8 = 0x31;

/// Stipple pattern (8x8 bitmask in bits \[63:0\]).
pub const STIPPLE_PATTERN: u8 = 0x32;

// --- Framebuffer & Z-Buffer (0x40-0x4F) ---

/// Render target configuration: color base, Z base, surface dimensions.
///
/// \[15:0\] COLOR_BASE (address >> 9, 512-byte granularity),
/// \[31:16\] Z_BASE (address >> 9),
/// \[35:32\] WIDTH_LOG2,
/// \[39:36\] HEIGHT_LOG2.
pub const FB_CONFIG: u8 = 0x40;

/// Display scanout framebuffer + LUT control (blocking, waits for vsync).
///
/// \[0\] COLOR_GRADE_ENABLE,
/// \[1\] LINE_DOUBLE,
/// \[15:2\] reserved,
/// \[31:16\] LUT_ADDR (address >> 9),
/// \[47:32\] FB_ADDR (address >> 9),
/// \[51:48\] WIDTH_LOG2.
pub const FB_DISPLAY: u8 = 0x41;

/// Scissor rectangle for fragment clipping.
///
/// \[9:0\] SCISSOR_X, \[19:10\] SCISSOR_Y,
/// \[29:20\] SCISSOR_WIDTH, \[39:30\] SCISSOR_HEIGHT.
pub const FB_CONTROL: u8 = 0x43;

/// Hardware memory fill.
///
/// \[15:0\] FILL_BASE (address >> 9, 512-byte granularity),
/// \[31:16\] FILL_VALUE (16-bit constant),
/// \[51:32\] FILL_COUNT (number of 16-bit words).
/// GPU executes the fill synchronously within the command FIFO.
pub const MEM_FILL: u8 = 0x44;

// --- FB_CONFIG bit-field shift constants ---

/// COLOR_BASE field shift in FB_CONFIG (bits \[15:0\]).
pub const FB_CONFIG_COLOR_BASE_SHIFT: u32 = 0;

/// Z_BASE field shift in FB_CONFIG (bits \[31:16\]).
pub const FB_CONFIG_Z_BASE_SHIFT: u32 = 16;

/// WIDTH_LOG2 field shift in FB_CONFIG (bits \[35:32\]).
pub const FB_CONFIG_WIDTH_LOG2_SHIFT: u32 = 32;

/// HEIGHT_LOG2 field shift in FB_CONFIG (bits \[39:36\]).
pub const FB_CONFIG_HEIGHT_LOG2_SHIFT: u32 = 36;

// --- MEM_FILL bit-field shift constants ---

/// FILL_BASE field shift in MEM_FILL (bits \[15:0\]).
pub const MEM_FILL_BASE_SHIFT: u32 = 0;

/// FILL_VALUE field shift in MEM_FILL (bits \[31:16\]).
pub const MEM_FILL_VALUE_SHIFT: u32 = 16;

/// FILL_COUNT field shift in MEM_FILL (bits \[51:32\]).
pub const MEM_FILL_COUNT_SHIFT: u32 = 32;

// --- FB_DISPLAY bit fields ---

/// Color grading enable (bit 0).
pub const FB_DISPLAY_COLOR_GRADE_ENABLE: u64 = 1 << 0;

/// Line-double mode enable (bit 1).
pub const FB_DISPLAY_LINE_DOUBLE: u64 = 1 << 1;

/// LUT base address shift (bits \[31:16\]), x512 byte granularity, 32 MiB addressable.
pub const FB_DISPLAY_LUT_ADDR_SHIFT: u32 = 16;

/// Framebuffer base address shift (bits \[47:32\]), x512 byte granularity, 32 MiB addressable.
pub const FB_DISPLAY_FB_ADDR_SHIFT: u32 = 32;

/// Display framebuffer WIDTH_LOG2 shift (bits \[51:48\]).
pub const FB_DISPLAY_WIDTH_LOG2_SHIFT: u32 = 48;

// --- Performance Timestamp (0x50) ---

/// Performance timestamp marker.
///
/// Write: DATA\[22:0\] = 23-bit SDRAM word address (32-bit word granularity,
/// 32 MiB addressable).  The GPU captures the frame-relative cycle counter
/// and writes it as a 32-bit word to the specified SDRAM address.
///
/// Read: returns the live (instantaneous) cycle counter in \[31:0\].
pub const PERF_TIMESTAMP: u8 = 0x50;

// --- Status & Control (0x70-0x7F) ---

/// Memory access dword address pointer (22-bit, write triggers read prefetch).
pub const MEM_ADDR: u8 = 0x70;

/// Memory data register (bidirectional 64-bit, auto-increments MEM_ADDR by 1).
pub const MEM_DATA: u8 = 0x71;

/// GPU identification register (read-only): VERSION + DEVICE_ID.
pub const ID: u8 = 0x7F;

// --- RENDER_MODE bit fields (see INT-010 section 0x30) ---

/// Gouraud shading enable (bit 0).
pub const RENDER_MODE_GOURAUD: u64 = 1 << 0;

/// Depth testing enable (bit 2).
pub const RENDER_MODE_Z_TEST: u64 = 1 << 2;

/// Depth write enable (bit 3).
pub const RENDER_MODE_Z_WRITE: u64 = 1 << 3;

/// Color buffer write enable (bit 4). 0 = Z-only pass.
pub const RENDER_MODE_COLOR_WRITE: u64 = 1 << 4;

/// Cull mode shift (bits \[6:5\]).
pub const RENDER_MODE_CULL_SHIFT: u32 = 5;

/// Alpha blend mode shift (bits \[9:7\]).
pub const RENDER_MODE_ALPHA_BLEND_SHIFT: u32 = 7;

/// Dithering enable (bit 10).
pub const RENDER_MODE_DITHER_EN: u64 = 1 << 10;

/// Dither pattern shift (bits \[12:11\]).
pub const RENDER_MODE_DITHER_PATTERN_SHIFT: u32 = 11;

/// Z compare function shift (bits \[15:13\]).
pub const RENDER_MODE_Z_COMPARE_SHIFT: u32 = 13;

/// Stipple test enable (bit 16).
pub const RENDER_MODE_STIPPLE_EN: u64 = 1 << 16;

/// Alpha test function shift (bits \[18:17\]).
pub const RENDER_MODE_ALPHA_TEST_SHIFT: u32 = 17;

/// Alpha test reference value shift (bits \[26:19\]).
pub const RENDER_MODE_ALPHA_REF_SHIFT: u32 = 19;

// --- Z-Buffer compare functions (RENDER_MODE bits [15:13]) ---

/// Z compare: less than.
pub const Z_COMPARE_LESS: u64 = 0b000 << 13;

/// Z compare: less than or equal.
pub const Z_COMPARE_LEQUAL: u64 = 0b001 << 13;

/// Z compare: equal.
pub const Z_COMPARE_EQUAL: u64 = 0b010 << 13;

/// Z compare: greater than or equal.
pub const Z_COMPARE_GEQUAL: u64 = 0b011 << 13;

/// Z compare: greater than.
pub const Z_COMPARE_GREATER: u64 = 0b100 << 13;

/// Z compare: not equal.
pub const Z_COMPARE_NOTEQUAL: u64 = 0b101 << 13;

/// Z compare: always pass.
pub const Z_COMPARE_ALWAYS: u64 = 0b110 << 13;

/// Z compare: never pass.
pub const Z_COMPARE_NEVER: u64 = 0b111 << 13;

// --- Alpha blend modes (RENDER_MODE bits [9:7]) ---

/// Alpha blending disabled.
pub const ALPHA_DISABLED: u64 = 0b000 << 7;

/// Additive blending.
pub const ALPHA_ADD: u64 = 0b001 << 7;

/// Subtractive blending.
pub const ALPHA_SUBTRACT: u64 = 0b010 << 7;

/// Alpha blend (src * a + dst * (1-a)).
pub const ALPHA_BLEND_MODE: u64 = 0b011 << 7;

// --- RENDER_MODE enum types (see INT-010 section 0x30) ---

/// Depth test comparison function (RENDER_MODE\[15:13\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ZCompare {
    /// Less than (<).
    Less = 0b000,

    /// Less than or equal (<=).
    Lequal = 0b001,

    /// Equal (=).
    Equal = 0b010,

    /// Greater than or equal (>=).
    Gequal = 0b011,

    /// Greater than (>).
    Greater = 0b100,

    /// Not equal (!=).
    NotEqual = 0b101,

    /// Always pass.
    Always = 0b110,

    /// Never pass.
    Never = 0b111,
}

/// Alpha blending mode (RENDER_MODE\[9:7\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum AlphaBlend {
    /// Disabled: overwrite destination.
    Disabled = 0b000,

    /// Additive: src + dst, saturate.
    Add = 0b001,

    /// Subtractive: src - dst, saturate.
    Subtract = 0b010,

    /// Alpha blend: src * a + dst * (1-a).
    Blend = 0b011,
}

/// Backface culling mode (RENDER_MODE\[6:5\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum CullMode {
    /// No culling.
    None = 0b00,

    /// Cull clockwise-wound triangles.
    Cw = 0b01,

    /// Cull counter-clockwise triangles.
    Ccw = 0b10,
}

/// Alpha test comparison function (RENDER_MODE\[18:17\]).
///
/// Per INT-010: 2-bit field encoding. The full 8-function set is
/// compressed to 4 entries since only 2 bits are available.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum AlphaTestFunc {
    /// Never pass (alpha test always fails).
    Never = 0,

    /// Pass if fragment alpha < ALPHA_REF.
    Less = 1,

    /// Pass if fragment alpha >= ALPHA_REF.
    Gequal = 2,

    /// Always pass (alpha test disabled).
    Always = 3,
}

// --- Memory map addresses (INT-011 4x4 tiled layout) ---

/// Framebuffer A base address (512x512, 4x4 block-tiled).
pub const FB_A_ADDR: u32 = 0x000000;

/// Framebuffer B base address.
pub const FB_B_ADDR: u32 = 0x080000;

/// Z-buffer base address.
pub const ZBUFFER_ADDR: u32 = 0x100000;

/// Texture memory start address.
pub const TEXTURE_BASE_ADDR: u32 = 0x180000;

/// Framebuffer A base in 512-byte units (for FB_CONFIG COLOR_BASE field).
pub const FB_A_BASE_512: u16 = (FB_A_ADDR >> 9) as u16;

/// Framebuffer B base in 512-byte units.
pub const FB_B_BASE_512: u16 = (FB_B_ADDR >> 9) as u16;

/// Z-buffer base in 512-byte units (for FB_CONFIG Z_BASE field).
pub const ZBUFFER_BASE_512: u16 = (ZBUFFER_ADDR >> 9) as u16;

/// Texture memory base in 512-byte units.
pub const TEXTURE_BASE_512: u16 = (TEXTURE_BASE_ADDR >> 9) as u16;

// --- GPU identification ---

/// Expected device ID for GPU v2.0.
pub const EXPECTED_DEVICE_ID: u16 = 0x6702;

// --- Display dimensions ---

/// Display width in pixels.
pub const SCREEN_WIDTH: u16 = 640;

/// Display height in pixels.
pub const SCREEN_HEIGHT: u16 = 480;

/// Z far plane value (16-bit unsigned max).
pub const Z_FAR: u32 = 0xFFFF;

// --- Backward-compatible aliases for removed constants ---
// Deprecated aliases kept for transition; consumers should update.

/// Backward-compatible alias: UV0 renamed to UV0_UV1.
#[deprecated(note = "use UV0_UV1 instead (packed UV for both texture units)")]
pub const UV0: u8 = UV0_UV1;

/// Alternate name for `COLOR` that makes the dual-color packing explicit.
///
/// COLOR0 (diffuse) is in \[63:32\], COLOR1 (specular) is in \[31:0\].
/// Both names refer to register address 0x00.
pub const COLOR0_COLOR1: u8 = COLOR;
