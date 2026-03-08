//! Fixed-point types and color formats matching the RTL bit-for-bit.
//!
//! Every numeric type in this module corresponds to a specific wire format
//! in the pico-gs RTL.
//! The type aliases encode the Q format (TI convention:
//! Qm.n = m integer bits including sign + n fractional bits, total = m+n bits).
//!
//! If you change a Q format here, the corresponding RTL module must change
//! to match, and vice versa.

use qfixed::Q;

// ═══════════════════════════════════════════════════════════════════════════
//  Scalar Q-format aliases — one per pipeline wire format
// ═══════════════════════════════════════════════════════════════════════════

/// **Depth / Z-buffer: Q4.12 (16-bit signed)**
///
/// Post-viewport depth value stored in the Z-buffer SRAM.
/// Range [0, ~8) with 12 bits of fractional precision.
/// The depth buffer comparison operates on these raw 16-bit values.
///
/// # RTL Implementation Notes
/// Z-buffer is a 16-bit-wide SRAM region.
/// Depth comparison is a simple 16-bit signed comparison in the fragment stage.
pub type Depth = Q<4, 12>;

/// **Texture coordinate: Q2.14 (16-bit signed)**
///
/// UV coordinates in [0, 1) with 14 bits of fractional precision.
/// Two integer bits allow for slight overshoot during interpolation
/// before wrapping.
///
/// # RTL Implementation Notes
/// Texture coordinates are interpolated in the rasterizer using the
/// same MULT18X18D + accumulate path as barycentrics.
/// Wrapping to [0, 1) is a simple bitmask on the fractional part.
pub type TexCoord = Q<2, 14>;

// ═══════════════════════════════════════════════════════════════════════════
//  Color types
// ═══════════════════════════════════════════════════════════════════════════

/// RGB565 packed pixel, matching the framebuffer SRAM format.
///
/// Bit layout: `RRRRR_GGGGGG_BBBBB` (MSB first).
///
/// # RTL Implementation Notes
/// This is the native pixel format written to/read from the framebuffer
/// SRAM.
/// The SRAM data bus is 16 bits wide, so one pixel per access.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rgb565(pub u16);

impl Rgb565 {
    /// Pack from 8-bit channels.
    ///
    /// Truncates (right-shifts) to 5-6-5 bits.
    /// This matches the RTL's behavior: no rounding, just discard low bits.
    pub fn from_rgb8(r: u8, g: u8, b: u8) -> Self {
        let r5 = (r >> 3) as u16;
        let g6 = (g >> 2) as u16;
        let b5 = (b >> 3) as u16;
        Self((r5 << 11) | (g6 << 5) | b5)
    }

    /// Unpack to 8-bit channels with bit replication for full range.
    pub fn to_rgb8(self) -> (u8, u8, u8) {
        let r5 = (self.0 >> 11) & 0x1F;
        let g6 = (self.0 >> 5) & 0x3F;
        let b5 = self.0 & 0x1F;
        (
            ((r5 << 3) | (r5 >> 2)) as u8,
            ((g6 << 2) | (g6 >> 4)) as u8,
            ((b5 << 3) | (b5 >> 2)) as u8,
        )
    }
}
