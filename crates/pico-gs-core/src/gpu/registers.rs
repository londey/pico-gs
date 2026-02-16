// Spec-ref: unit_022_gpu_driver_layer.md `4aaa3e4c37e70deb` 2026-02-16
//! GPU register addresses and bit-field constants.
//!
//! Matches the ICEpi SPI GPU register map specification v10.0 (INT-010).

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

// --- Texture Unit 0 (0x10-0x17) ---

/// Texture 0 base address in GPU SRAM (4K aligned).
pub const TEX0_BASE: u8 = 0x10;
/// Texture 0 format: dimensions, swizzle, compressed flag, enable.
pub const TEX0_FMT: u8 = 0x11;
/// Texture 0 blend function.
pub const TEX0_BLEND: u8 = 0x12;
/// Texture 0 LUT base address (for compressed textures).
pub const TEX0_LUT_BASE: u8 = 0x13;
/// Texture 0 UV wrapping mode.
pub const TEX0_WRAP: u8 = 0x14;

// --- Texture Unit 1 (0x18-0x1F) ---

pub const TEX1_BASE: u8 = 0x18;
pub const TEX1_FMT: u8 = 0x19;
pub const TEX1_BLEND: u8 = 0x1A;
pub const TEX1_LUT_BASE: u8 = 0x1B;
pub const TEX1_WRAP: u8 = 0x1C;

// --- Texture Unit 2 (0x20-0x27) ---

pub const TEX2_BASE: u8 = 0x20;
pub const TEX2_FMT: u8 = 0x21;
pub const TEX2_BLEND: u8 = 0x22;
pub const TEX2_LUT_BASE: u8 = 0x23;
pub const TEX2_WRAP: u8 = 0x24;

// --- Texture Unit 3 (0x28-0x2F) ---

pub const TEX3_BASE: u8 = 0x28;
pub const TEX3_FMT: u8 = 0x29;
pub const TEX3_BLEND: u8 = 0x2A;
pub const TEX3_LUT_BASE: u8 = 0x2B;
pub const TEX3_WRAP: u8 = 0x2C;

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

// Backward-compatible aliases.
pub const TRI_MODE_GOURAUD: u64 = RENDER_MODE_GOURAUD;
pub const TRI_MODE_Z_TEST: u64 = RENDER_MODE_Z_TEST;
pub const TRI_MODE_Z_WRITE: u64 = RENDER_MODE_Z_WRITE;

// --- Z-Buffer compare functions (RENDER_MODE bits [15:13], v8.0: moved from FB_ZBUFFER) ---

pub const Z_COMPARE_LESS: u64 = 0b000 << 13;
pub const Z_COMPARE_LEQUAL: u64 = 0b001 << 13;
pub const Z_COMPARE_EQUAL: u64 = 0b010 << 13;
pub const Z_COMPARE_GEQUAL: u64 = 0b011 << 13;
pub const Z_COMPARE_GREATER: u64 = 0b100 << 13;
pub const Z_COMPARE_NOTEQUAL: u64 = 0b101 << 13;
pub const Z_COMPARE_ALWAYS: u64 = 0b110 << 13;
pub const Z_COMPARE_NEVER: u64 = 0b111 << 13;

// --- Alpha blend modes (RENDER_MODE bits [9:7], v8.0: moved from ALPHA_BLEND register) ---

pub const ALPHA_DISABLED: u64 = 0b000 << 7;
pub const ALPHA_ADD: u64 = 0b001 << 7;
pub const ALPHA_SUBTRACT: u64 = 0b010 << 7;
pub const ALPHA_BLEND_MODE: u64 = 0b011 << 7;

// --- RENDER_MODE enum types (see INT-010 §0x30, INT-020) ---

/// Depth test comparison function (RENDER_MODE[15:13]).
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

/// Alpha blending mode (RENDER_MODE[9:7]).
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

/// Backface culling mode (RENDER_MODE[6:5]).
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

pub const SCREEN_WIDTH: u16 = 640;
pub const SCREEN_HEIGHT: u16 = 480;

/// Z far plane value (16-bit unsigned max).
pub const Z_FAR: u32 = 0xFFFF;
