//! Ordered dithering — reduce Q4.12 color to RGB565.
//!
//! Applies a 16×16 blue-noise ordered dither matrix before truncating
//! from Q4.12 to RGB565, reducing banding in dark tones and gradients.
//! The dither offset is determined by the fragment's (x, y) position
//! modulo the matrix dimensions.
//!
//! # RTL Implementation Notes
//!
//! The dither matrix is stored in a single EBR (DP16KD).
//! When dithering is disabled, the color is truncated directly.

use gs_twin_core::fragment::{ColoredFragment, PixelOut};
use gs_twin_core::math::Rgb565;

/// Apply dithering and truncate Q4.12 color to RGB565.
///
/// # Arguments
///
/// * `frag` - Colored fragment with Q4.12 color.
/// * `dither_en` - Whether ordered dithering is enabled.
///
/// # Returns
///
/// A `PixelOut` with RGB565 color ready for framebuffer write.
pub fn dither(frag: ColoredFragment, _dither_en: bool) -> PixelOut {
    // TODO: implement blue-noise dither matrix lookup and application
    // Stub: direct truncation (Q4.12 → clamp to [0,1] → scale to RGB565)
    let clamp_to_u8 = |ch: qfixed::Q<4, 12>| -> u8 {
        let bits = ch.to_bits();
        // Q4.12: 1.0 = 4096. Clamp to [0, 4095], scale to [0, 255].
        let clamped = bits.clamp(0, 4095) as u32;
        // (clamped * 255 + 2048) / 4096 — rounded division
        ((clamped * 255 + 2048) / 4096) as u8
    };

    let r = clamp_to_u8(frag.color.r);
    let g = clamp_to_u8(frag.color.g);
    let b = clamp_to_u8(frag.color.b);

    PixelOut {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        color: Rgb565::from_rgb8(r, g, b),
    }
}
