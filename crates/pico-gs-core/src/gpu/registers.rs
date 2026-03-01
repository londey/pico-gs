// Spec-ref: unit_022_gpu_driver_layer.md `2e395d1315d4c2b1` 2026-02-25
//! GPU register addresses and bit-field constants for SPI access.
//!
//! Flat constants derived from the PeakRDL-generated `gpu_registers` crate.
//! The SystemRDL source (`registers/rdl/gpu_regs.rdl`) is the single source
//! of truth; these constants translate the byte-addressed MMIO layout into
//! 7-bit SPI register indices (byte_offset / 8).

// Re-export generated enum types used by the driver public API.
pub use gpu_registers::components::alpha_blend_e::AlphaBlendE as AlphaBlend;
pub use gpu_registers::components::alpha_test_e::AlphaTestE as AlphaTestFunc;
pub use gpu_registers::components::cull_mode_e::CullModeE as CullMode;
pub use gpu_registers::components::z_compare_e::ZCompareE as ZCompare;

// Re-export generated register types for structured field access.
pub use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
pub use gpu_registers::components::gpu_regs::named_types::fb_display_reg::FbDisplayReg;
pub use gpu_registers::components::gpu_regs::named_types::mem_fill_reg::MemFillReg;
pub use gpu_registers::components::gpu_regs::named_types::render_mode_reg::RenderModeReg;
pub use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;

// ---------------------------------------------------------------------------
// SPI register address constants (7-bit index = MMIO byte offset / 8)
// ---------------------------------------------------------------------------

// --- Vertex State (0x00–0x0F) ---

/// Vertex color register (MMIO 0x000).
pub const COLOR: u8 = 0x00;

/// Packed UV coordinates for texture units 0 and 1 (MMIO 0x008).
pub const UV0_UV1: u8 = 0x01;

/// Barycentric interpolation area normalization (MMIO 0x028).
pub const AREA_SETUP: u8 = 0x05;

/// Vertex position, no triangle draw (MMIO 0x030).
pub const VERTEX_NOKICK: u8 = 0x06;

/// Vertex position, draw triangle (v0,v1,v2) (MMIO 0x038).
pub const VERTEX_KICK_012: u8 = 0x07;

/// Vertex position, draw triangle (v0,v2,v1) (MMIO 0x040).
pub const VERTEX_KICK_021: u8 = 0x08;

/// Vertex position, rectangle emit (MMIO 0x048).
pub const VERTEX_KICK_RECT: u8 = 0x09;

// --- Texture Configuration (0x10–0x11) ---

/// Texture unit 0 configuration (unified 64-bit register) (MMIO 0x080).
pub const TEX0_CFG: u8 = 0x10;

/// Texture unit 1 configuration (unified 64-bit register) (MMIO 0x088).
pub const TEX1_CFG: u8 = 0x11;

// --- Color Combiner (0x18–0x19) ---

/// Color combiner mode (MMIO 0x0C0).
pub const CC_MODE: u8 = 0x18;

/// Constant colors 0 + 1 packed (MMIO 0x0C8).
pub const CONST_COLOR: u8 = 0x19;

// --- Rendering Configuration (0x30–0x32) ---

/// Unified rendering state register (MMIO 0x180).
pub const RENDER_MODE: u8 = 0x30;

/// Depth range clipping min/max (MMIO 0x188).
pub const Z_RANGE: u8 = 0x31;

/// 8x8 stipple pattern (MMIO 0x190).
pub const STIPPLE_PATTERN: u8 = 0x32;

// --- Framebuffer & Z-Buffer (0x40–0x44) ---

/// Render target configuration (MMIO 0x200).
pub const FB_CONFIG: u8 = 0x40;

/// Display scanout framebuffer (MMIO 0x208).
pub const FB_DISPLAY: u8 = 0x41;

/// Scissor rectangle (MMIO 0x218).
pub const FB_CONTROL: u8 = 0x43;

/// Hardware memory fill (MMIO 0x220).
pub const MEM_FILL: u8 = 0x44;

// --- Performance (0x50) ---

/// Performance timestamp marker (MMIO 0x280).
pub const PERF_TIMESTAMP: u8 = 0x50;

// --- Status & Control (0x70–0x7F) ---

/// Memory access dword address pointer (MMIO 0x380).
pub const MEM_ADDR: u8 = 0x70;

/// Memory data register, auto-increments address (MMIO 0x388).
pub const MEM_DATA: u8 = 0x71;

/// GPU identification register (MMIO 0x3F8).
pub const ID: u8 = 0x7F;

// ---------------------------------------------------------------------------
// FB_CONFIG bit-field shift constants (from generated FbConfigReg)
// ---------------------------------------------------------------------------

/// COLOR_BASE field shift in FB_CONFIG (bits [15:0]).
pub const FB_CONFIG_Z_BASE_SHIFT: u32 = FbConfigReg::Z_BASE_OFFSET as u32;

/// WIDTH_LOG2 field shift in FB_CONFIG (bits [35:32]).
pub const FB_CONFIG_WIDTH_LOG2_SHIFT: u32 = FbConfigReg::WIDTH_LOG2_OFFSET as u32;

/// HEIGHT_LOG2 field shift in FB_CONFIG (bits [39:36]).
pub const FB_CONFIG_HEIGHT_LOG2_SHIFT: u32 = FbConfigReg::HEIGHT_LOG2_OFFSET as u32;

// ---------------------------------------------------------------------------
// FB_DISPLAY bit-field shift constants (from generated FbDisplayReg)
// ---------------------------------------------------------------------------

/// FB_ADDR field shift in FB_DISPLAY.
pub const FB_DISPLAY_FB_ADDR_SHIFT: u32 = FbDisplayReg::FB_ADDR_OFFSET as u32;

/// WIDTH_LOG2 field shift in FB_DISPLAY.
pub const FB_DISPLAY_WIDTH_LOG2_SHIFT: u32 = FbDisplayReg::FB_WIDTH_LOG2_OFFSET as u32;

// ---------------------------------------------------------------------------
// MEM_FILL bit-field shift constants (from generated MemFillReg)
// ---------------------------------------------------------------------------

/// FILL_VALUE field shift in MEM_FILL.
pub const MEM_FILL_VALUE_SHIFT: u32 = MemFillReg::FILL_VALUE_OFFSET as u32;

/// FILL_COUNT field shift in MEM_FILL.
pub const MEM_FILL_COUNT_SHIFT: u32 = MemFillReg::FILL_COUNT_OFFSET as u32;

// ---------------------------------------------------------------------------
// RENDER_MODE bit-flag constants (from generated RenderModeReg)
// ---------------------------------------------------------------------------

/// Gouraud shading enable (bit 0).
pub const RENDER_MODE_GOURAUD: u64 = 1 << RenderModeReg::GOURAUD_OFFSET;

/// Depth testing enable (bit 2).
pub const RENDER_MODE_Z_TEST: u64 = 1 << RenderModeReg::Z_TEST_EN_OFFSET;

/// Depth write enable (bit 3).
pub const RENDER_MODE_Z_WRITE: u64 = 1 << RenderModeReg::Z_WRITE_EN_OFFSET;

/// Color buffer write enable (bit 4).
pub const RENDER_MODE_COLOR_WRITE: u64 = 1 << RenderModeReg::COLOR_WRITE_EN_OFFSET;

// ---------------------------------------------------------------------------
// Memory map constants (INT-011)
// ---------------------------------------------------------------------------

/// Framebuffer A base address.
pub const FB_A_ADDR: u32 = 0x000000;

/// Framebuffer B base address.
pub const FB_B_ADDR: u32 = 0x080000;

/// Z-buffer base address.
pub const ZBUFFER_ADDR: u32 = 0x100000;

/// Texture memory start address.
pub const TEXTURE_BASE_ADDR: u32 = 0x180000;

/// Framebuffer A base in 512-byte units.
pub const FB_A_BASE_512: u16 = (FB_A_ADDR >> 9) as u16;

/// Framebuffer B base in 512-byte units.
pub const FB_B_BASE_512: u16 = (FB_B_ADDR >> 9) as u16;

/// Z-buffer base in 512-byte units.
pub const ZBUFFER_BASE_512: u16 = (ZBUFFER_ADDR >> 9) as u16;

// ---------------------------------------------------------------------------
// Device identification
// ---------------------------------------------------------------------------

/// Expected device ID for GPU v2.0.
pub const EXPECTED_DEVICE_ID: u16 = 0x6702;

// ---------------------------------------------------------------------------
// Display dimensions
// ---------------------------------------------------------------------------

/// Display width in pixels.
pub const SCREEN_WIDTH: u16 = 640;

/// Display height in pixels.
pub const SCREEN_HEIGHT: u16 = 480;
