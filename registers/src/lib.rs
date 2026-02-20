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

/// Vertex color register (ABGR, latched for next VERTEX write).
pub const COLOR: u8 = 0x00;
/// Texture unit 0 UV coordinates (perspective-correct 1.15 fixed-point).
pub const UV0: u8 = 0x01;
/// Texture unit 1 UV coordinates.
pub const UV1: u8 = 0x02;
/// Texture unit 2 UV coordinates.
pub const UV2: u8 = 0x03;
/// Texture unit 3 UV coordinates.
pub const UV3: u8 = 0x04;
/// Vertex position + push trigger. Third write submits triangle.
pub const VERTEX: u8 = 0x05;

// --- Texture Samplers (0x10-0x11) ---

/// Texture 0 unified config (enable, format, filter, dims, wrap, mips, base).
pub const TEX0_CFG: u8 = 0x10;
/// Texture 1 unified config.
pub const TEX1_CFG: u8 = 0x11;

// --- TEXn_CFG bit fields ---

/// Texture enable (bit 0).
pub const TEX_CFG_ENABLE: u64 = 1 << 0;

/// Texture filter mode (bits [3:2]).
pub const TEX_CFG_FILTER_SHIFT: u32 = 2;
/// Texture format (bits [6:4]).
pub const TEX_CFG_FORMAT_SHIFT: u32 = 4;
/// Width log2 (bits [11:8]).
pub const TEX_CFG_WIDTH_LOG2_SHIFT: u32 = 8;
/// Height log2 (bits [15:12]).
pub const TEX_CFG_HEIGHT_LOG2_SHIFT: u32 = 12;
/// U wrap mode (bits [17:16]).
pub const TEX_CFG_U_WRAP_SHIFT: u32 = 16;
/// V wrap mode (bits [19:18]).
pub const TEX_CFG_V_WRAP_SHIFT: u32 = 18;
/// Mipmap level count (bits [23:20]).
pub const TEX_CFG_MIP_LEVELS_SHIFT: u32 = 20;
/// Base address (bits [47:32]), x512 byte granularity, 32 MiB addressable.
pub const TEX_CFG_BASE_ADDR_SHIFT: u32 = 32;

/// Texture format (TEXn_CFG\[6:4\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TexFormat {
    /// 4 bpp block compressed, opaque or 1-bit alpha.
    Bc1 = 0,
    /// 8 bpp block compressed, explicit alpha.
    Bc2 = 1,
    /// 8 bpp block compressed, interpolated alpha.
    Bc3 = 2,
    /// 4 bpp block compressed, single channel.
    Bc4 = 3,
    /// 16 bpp 5-6-5 uncompressed, 4x4 tiled.
    Rgb565 = 4,
    /// 32 bpp 8-8-8-8 uncompressed, 4x4 tiled.
    Rgba8888 = 5,
    /// 8 bpp single channel, 4x4 tiled.
    R8 = 6,
}

/// Texture filter mode (TEXn_CFG\[3:2\]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum TexFilter {
    /// No interpolation.
    Nearest = 0,
    /// 2x2 tap bilinear filter.
    Bilinear = 1,
    /// Mipmap blend (requires MIP_LEVELS > 1).
    Trilinear = 2,
}

/// UV coordinate wrap mode (TEXn_CFG U_WRAP/V_WRAP).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum WrapMode {
    /// Wrap around.
    Repeat = 0,
    /// Clamp to edge.
    ClampToEdge = 1,
    /// Reflect at boundaries.
    Mirror = 2,
    /// Coupled diagonal mirror for octahedral mapping.
    Octahedral = 3,
}

// --- Rendering Configuration (0x30-0x3F) ---

/// Unified rendering state register (v10.0).
pub const RENDER_MODE: u8 = 0x30;
/// Backward-compatible alias for `RENDER_MODE`.
pub const TRI_MODE: u8 = RENDER_MODE;
/// Depth range clipping (Z scissor) min/max register (v10.0).
pub const Z_RANGE: u8 = 0x31;

// --- Framebuffer & Z-Buffer (0x40-0x4F) ---

/// Draw target framebuffer address (4K aligned).
pub const FB_DRAW: u8 = 0x40;
/// Display scanout framebuffer address (4K aligned, takes effect at VSYNC).
pub const FB_DISPLAY: u8 = 0x41;
/// Z-buffer base address (v8.0: Z_COMPARE moved to RENDER_MODE).
pub const FB_ZBUFFER: u8 = 0x42;

// --- Status & Control (0x70-0x7F) ---

/// Memory upload address pointer.
pub const MEM_ADDR: u8 = 0x70;
/// Memory upload data (auto-increments MEM_ADDR by 4).
pub const MEM_DATA: u8 = 0x71;
/// GPU status register (read-only): VBLANK, BUSY, FIFO_DEPTH.
pub const STATUS: u8 = 0x7E;
/// GPU identification register (read-only): VERSION + DEVICE_ID.
pub const ID: u8 = 0x7F;

// --- RENDER_MODE bit fields (see INT-010 §0x30) ---

/// Gouraud shading enable (bit 0).
pub const RENDER_MODE_GOURAUD: u64 = 1 << 0;
/// Depth testing enable (bit 2).
pub const RENDER_MODE_Z_TEST: u64 = 1 << 2;
/// Depth write enable (bit 3).
pub const RENDER_MODE_Z_WRITE: u64 = 1 << 3;
/// Color buffer write enable (bit 4). 0 = Z-only pass.
pub const RENDER_MODE_COLOR_WRITE: u64 = 1 << 4;

/// Backward-compatible alias.
pub const TRI_MODE_GOURAUD: u64 = RENDER_MODE_GOURAUD;
/// Backward-compatible alias.
pub const TRI_MODE_Z_TEST: u64 = RENDER_MODE_Z_TEST;
/// Backward-compatible alias.
pub const TRI_MODE_Z_WRITE: u64 = RENDER_MODE_Z_WRITE;

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

// --- RENDER_MODE enum types (see INT-010 §0x30, INT-020) ---

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

// --- Memory map addresses ---

/// Framebuffer A base address.
pub const FB_A_ADDR: u32 = 0x000000;
/// Framebuffer B base address.
pub const FB_B_ADDR: u32 = 0x12C000;
/// Z-buffer base address.
pub const ZBUFFER_ADDR: u32 = 0x258000;
/// Texture memory start address.
pub const TEXTURE_BASE_ADDR: u32 = 0x384000;

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
