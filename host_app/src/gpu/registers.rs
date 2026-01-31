//! GPU v2.0 register addresses and bit-field constants.
//!
//! Matches the ICEpi SPI GPU register map specification v2.0.

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

/// Triangle rendering mode: Gouraud, Z-test, Z-write.
pub const TRI_MODE: u8 = 0x30;
/// Alpha blending mode.
pub const ALPHA_BLEND: u8 = 0x31;

// --- Framebuffer & Z-Buffer (0x40-0x4F) ---

/// Draw target framebuffer address (4K aligned).
pub const FB_DRAW: u8 = 0x40;
/// Display scanout framebuffer address (4K aligned, takes effect at VSYNC).
pub const FB_DISPLAY: u8 = 0x41;
/// Z-buffer address + compare function.
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

// --- TRI_MODE bit fields ---

/// Gouraud shading enable (bit 0).
pub const TRI_MODE_GOURAUD: u64 = 1 << 0;
/// Depth testing enable (bit 2).
pub const TRI_MODE_Z_TEST: u64 = 1 << 2;
/// Depth write enable (bit 3).
pub const TRI_MODE_Z_WRITE: u64 = 1 << 3;

// --- Z-Buffer compare functions (bits [34:32] of FB_ZBUFFER) ---

pub const Z_COMPARE_LESS: u64 = 0b000 << 32;
pub const Z_COMPARE_LEQUAL: u64 = 0b001 << 32;
pub const Z_COMPARE_EQUAL: u64 = 0b010 << 32;
pub const Z_COMPARE_GEQUAL: u64 = 0b011 << 32;
pub const Z_COMPARE_GREATER: u64 = 0b100 << 32;
pub const Z_COMPARE_NOTEQUAL: u64 = 0b101 << 32;
pub const Z_COMPARE_ALWAYS: u64 = 0b110 << 32;
pub const Z_COMPARE_NEVER: u64 = 0b111 << 32;

// --- Alpha blend modes ---

pub const ALPHA_DISABLED: u64 = 0b00;
pub const ALPHA_ADD: u64 = 0b01;
pub const ALPHA_SUBTRACT: u64 = 0b10;
pub const ALPHA_BLEND_MODE: u64 = 0b11;

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

/// Z far plane value (25-bit unsigned max).
pub const Z_FAR: u32 = 0x1FF_FFFF;
