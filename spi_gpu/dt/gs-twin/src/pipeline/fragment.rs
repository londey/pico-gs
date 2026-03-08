//! Per-stage fragment types for the pixel pipeline.
//!
//! Each type matches a specific data-lane boundary in the pipeline,
//! as defined in ARCHITECTURE.md's per-fragment data lanes table.
//! Fields and their Q formats correspond to RTL wire widths.
//!
//! # Pipeline type flow
//!
//! ```text
//! Rasterizer ──→ RasterFragment
//!   → stipple_test → depth_range_clip → early_z_test
//!   → tex_sample ──→ TexturedFragment
//!   → color_combine_0 → color_combine_1 ──→ ColoredFragment
//!   → alpha_test → alpha_blend
//!   → dither ──→ PixelOut
//!   → pixel_write
//! ```

use crate::math::Rgb565;
use qfixed::Q;

// ── Pipeline-wide color format ───────────────────────────────────────────────

/// Q4.12 RGBA color — the pipeline-wide fragment color format.
///
/// All UNORM inputs (vertex colors, material constants, texture samples)
/// are promoted to Q4.12 at pipeline entry.
/// The signed representation handles `(A-B)` in the color combiner, and
/// the 3-bit integer headroom above 1.0 (range up to ~8.0) accommodates
/// additive blending without premature saturation.
///
/// # RTL Implementation Notes
///
/// 16-bit operands fit within the ECP5's native 18×18 DSP multipliers.
/// See ARCHITECTURE.md lines 27–31.
#[derive(Debug, Clone, Copy, Default)]
pub struct ColorQ412 {
    /// Red channel, Q4.12 signed.
    pub r: Q<4, 12>,

    /// Green channel, Q4.12 signed.
    pub g: Q<4, 12>,

    /// Blue channel, Q4.12 signed.
    pub b: Q<4, 12>,

    /// Alpha channel, Q4.12 signed.
    pub a: Q<4, 12>,
}

// ── Rasterizer output ────────────────────────────────────────────────────────

/// Fragment emitted by the rasterizer, carrying all interpolated data lanes.
///
/// This is the input to the early pipeline stages: stipple test, depth
/// range clip, and early Z test.
/// All data lanes from the rasterizer are live at this point.
///
/// # Data lanes (ARCHITECTURE.md)
///
/// x, y, z, shade0, shade1, uv (TEX0 + TEX1), lod.
#[derive(Debug, Clone, Copy, Default)]
pub struct RasterFragment {
    /// Integer pixel X (0..1023), from Q12.4 bits [13:4].
    pub x: u16,

    /// Integer pixel Y (0..1023).
    pub y: u16,

    /// Depth, unsigned 16-bit.
    pub z: u16,

    /// Interpolated diffuse vertex color (SHADE0), Q4.12 RGBA.
    pub shade0: ColorQ412,

    /// Interpolated specular vertex color (SHADE1), Q4.12 RGBA.
    pub shade1: ColorQ412,

    /// TEX0 U coordinate, Q4.12 signed (perspective-corrected by rasterizer).
    pub u0: Q<4, 12>,

    /// TEX0 V coordinate, Q4.12 signed.
    pub v0: Q<4, 12>,

    /// TEX1 U coordinate, Q4.12 signed.
    pub u1: Q<4, 12>,

    /// TEX1 V coordinate, Q4.12 signed.
    pub v1: Q<4, 12>,

    /// Level-of-detail, UQ4.4 (4-bit integer mip level + 4-bit fraction).
    pub lod: u8,
}

// ── After texture sampling ───────────────────────────────────────────────────

/// Fragment after texture sampling, input to the color combiner stages.
///
/// UV and LOD lanes have been consumed by texture sampling.
/// tex0/tex1 are the sampled texel colors.
/// The `comb` field is populated by color combiner stage 0.
///
/// # Data lanes (ARCHITECTURE.md)
///
/// x, y, z, shade0, shade1, tex0, tex1, comb (after CC0).
#[derive(Debug, Clone, Copy, Default)]
pub struct TexturedFragment {
    /// Integer pixel X.
    pub x: u16,

    /// Integer pixel Y.
    pub y: u16,

    /// Depth, unsigned 16-bit.
    pub z: u16,

    /// Interpolated diffuse vertex color (SHADE0), Q4.12 RGBA.
    pub shade0: ColorQ412,

    /// Interpolated specular vertex color (SHADE1), Q4.12 RGBA.
    pub shade1: ColorQ412,

    /// Sampled TEX0 color, Q4.12 RGBA.
    pub tex0: ColorQ412,

    /// Sampled TEX1 color, Q4.12 RGBA.
    pub tex1: ColorQ412,

    /// Color combiner stage 0 output (COMBINED source for stage 1).
    /// `None` before CC0, `Some` after CC0.
    pub comb: Option<ColorQ412>,
}

// ── After color combiner ─────────────────────────────────────────────────────

/// Fragment after color combiner stage 1, carrying only final color.
///
/// All intermediate data lanes (shade, tex, comb) have been consumed.
/// This is the input to alpha test, alpha blend, and dither.
///
/// # Data lanes (ARCHITECTURE.md)
///
/// x, y, z, color.
#[derive(Debug, Clone, Copy, Default)]
pub struct ColoredFragment {
    /// Integer pixel X.
    pub x: u16,

    /// Integer pixel Y.
    pub y: u16,

    /// Depth, unsigned 16-bit.
    pub z: u16,

    /// Final fragment color, Q4.12 RGBA.
    pub color: ColorQ412,
}

// ── After dither ─────────────────────────────────────────────────────────────

/// Fragment after dithering, ready for framebuffer write.
///
/// Color has been truncated from Q4.12 to RGB565.
///
/// # Data lanes (ARCHITECTURE.md)
///
/// x, y, z, color (RGB565).
#[derive(Debug, Clone, Copy, Default)]
pub struct PixelOut {
    /// Integer pixel X.
    pub x: u16,

    /// Integer pixel Y.
    pub y: u16,

    /// Depth, unsigned 16-bit (for Z-buffer write).
    pub z: u16,

    /// Final color, RGB565 (after dither truncation).
    pub color: Rgb565,
}
