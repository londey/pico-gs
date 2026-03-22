//! Shared triangle and vertex types for rasterization.
//!
//! These types are defined here (rather than in the rasterizer crate) because
//! they are used by both the rasterizer and the register file (SPI) crate
//! for `GpuAction::KickTriangle`.

// ── RGBA8888 color helper ────────────────────────────────────────────────────

/// Unpack RGBA8888 as `[31:24]=R, [23:16]=G, [15:8]=B, [7:0]=A`.
///
/// Matches the RTL's decode in rasterizer.sv (v0_color0[31:24] = R, etc.).
#[derive(Debug, Clone, Copy, Default)]
pub struct Rgba8888(pub u32);

impl Rgba8888 {
    /// Extract the red channel (bits [31:24]).
    pub fn r(self) -> u8 {
        (self.0 >> 24) as u8
    }

    /// Extract the green channel (bits [23:16]).
    pub fn g(self) -> u8 {
        (self.0 >> 16) as u8
    }

    /// Extract the blue channel (bits [15:8]).
    pub fn b(self) -> u8 {
        (self.0 >> 8) as u8
    }

    /// Extract the alpha channel (bits [7:0]).
    pub fn a(self) -> u8 {
        self.0 as u8
    }
}

// ── Vertex and triangle types ────────────────────────────────────────────────

/// Full vertex data matching the RTL's per-vertex register bundle.
///
/// Contains all attributes needed for rasterization: position, depth,
/// perspective factor, two color sets, and texture coordinates.
#[derive(Debug, Clone, Copy, Default)]
pub struct RasterVertex {
    /// Integer pixel X (0..1023), from Q12.4 bits \[13:4\].
    pub px: u16,

    /// Integer pixel Y (0..1023).
    pub py: u16,

    /// Depth, unsigned 16-bit.
    pub z: u16,

    /// Q/W perspective denominator, unsigned 16-bit (from VERTEX register).
    pub q: u16,

    /// Diffuse color (RGBA8888).
    pub color0: Rgba8888,

    /// Specular color (RGBA8888).
    pub color1: Rgba8888,

    /// TEX0 S coordinate (Q4.12 raw bits, signed).
    pub s0: u16,

    /// TEX0 T coordinate (Q4.12 raw bits, signed).
    pub t0: u16,

    /// TEX1 S coordinate (Q4.12 raw bits, signed).
    pub s1: u16,

    /// TEX1 T coordinate (Q4.12 raw bits, signed).
    pub t1: u16,
}

/// Triangle input for rasterization.
#[derive(Debug, Clone, Copy, Default)]
pub struct RasterTriangle {
    /// Three vertices in winding order.
    pub verts: [RasterVertex; 3],

    /// Bounding box minimum X (clamped to scissor/surface).
    pub bbox_min_x: u16,

    /// Bounding box maximum X (clamped to scissor/surface).
    pub bbox_max_x: u16,

    /// Bounding box minimum Y (clamped to scissor/surface).
    pub bbox_min_y: u16,

    /// Bounding box maximum Y (clamped to scissor/surface).
    pub bbox_max_y: u16,

    /// Whether Gouraud interpolation is enabled for vertex colors.
    pub gouraud_en: bool,
}

/// A single register write command.
#[derive(Debug, Clone, Copy)]
pub struct RegWrite {
    /// 7-bit register index (0..127).
    pub addr: u8,

    /// 64-bit register data.
    pub data: u64,
}
