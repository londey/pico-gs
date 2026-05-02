//! RGB565 → Q4.12 per-channel promotion (fb_promote).
//!
//! Used by the alpha-blend / color-combiner pass-2 path to convert a
//! destination framebuffer pixel read out of the color tile cache into
//! the Q4.12 per-channel representation consumed by the color combiner.
//!
//! See UNIT-006 (pixel pipeline) and the corresponding RTL module
//! `fb_promote.sv`.

// Spec-ref: unit_006_pixel_pipeline.md

use gs_twin_core::fragment::ColorQ412;
use gs_twin_core::math::Rgb565;
use qfixed::Q;

/// Promote an RGB565 framebuffer pixel to Q4.12 per-channel.
///
/// Maps UNORM `[0, 1.0]` exactly to Q4.12 `[0x0000, 0x1000]`.  The base
/// MSB-replication produces `0x0FFF` at full scale; the extra
/// `(v >> 4)` / `(v >> 5)` term supplies the final LSB so that 5/6-bit
/// all-ones round up to `0x1000` = 1.0, while all smaller values remain
/// within 1 LSB of the ideal `v * 0x1000 / max` ratio.
///
/// Matches RTL `fb_promote.sv`.
///
/// # Arguments
///
/// * `pixel` - 16-bit RGB565 pixel value.
///
/// # Returns
///
/// `ColorQ412` with the alpha channel set to opaque (`0x1000`); the
/// destination framebuffer has no alpha component, so callers that need
/// alpha must source it elsewhere.
#[must_use]
pub fn promote_rgb565(pixel: Rgb565) -> ColorQ412 {
    let r5 = (pixel.0 >> 11) & 0x1F;
    let g6 = (pixel.0 >> 5) & 0x3F;
    let b5 = pixel.0 & 0x1F;

    let r_q412 = ((r5 << 7) | (r5 << 2) | (r5 >> 3)) + (r5 >> 4);
    let g_q412 = ((g6 << 6) | g6) + (g6 >> 5);
    let b_q412 = ((b5 << 7) | (b5 << 2) | (b5 >> 3)) + (b5 >> 4);

    ColorQ412 {
        r: Q::from_bits(r_q412 as i64),
        g: Q::from_bits(g_q412 as i64),
        b: Q::from_bits(b_q412 as i64),
        a: Q::from_bits(0x1000), // opaque (promoted dst has no alpha channel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn promote_white() {
        let c = promote_rgb565(Rgb565(0xFFFF));
        assert_eq!(c.r.to_bits(), 0x1000);
        assert_eq!(c.g.to_bits(), 0x1000);
        assert_eq!(c.b.to_bits(), 0x1000);
        assert_eq!(c.a.to_bits(), 0x1000);
    }

    #[test]
    fn promote_black() {
        let c = promote_rgb565(Rgb565(0x0000));
        assert_eq!(c.r.to_bits(), 0);
        assert_eq!(c.g.to_bits(), 0);
        assert_eq!(c.b.to_bits(), 0);
        assert_eq!(c.a.to_bits(), 0x1000);
    }
}
