//! Fragment processing stage (fixed-point).
//!
//! Each fragment produced by the rasterizer passes through:
//!   1. Depth test: compare fragment depth (Q4.12) against Z-buffer
//!   2. Texturing: if bound, sample texture and modulate with vertex color
//!   3. Framebuffer write: store RGB565 pixel
//!
//! # RTL Implementation Notes
//! The fragment stage accesses SRAM for both the Z-buffer read/write and
//! the framebuffer write. In the RTL these are sequential SRAM accesses
//! (read Z → compare → optionally write Z + write color), taking
//! multiple clock cycles per fragment. The twin models this as a single
//! atomic operation since it's not cycle-accurate.

use crate::math::Rgb565;
use crate::mem::GpuMemory;
use crate::pipeline::{Fragment, GpuState};

/// Process a single fragment: depth test → texture → framebuffer write.
///
/// # Numeric Behavior
/// - Depth comparison: signed 16-bit compare on raw Q4.12 bits
/// - Texture sample: nearest-neighbor, UV wrap via bitmask
/// - Color modulate: per-channel (R5×R5)/31, (G6×G6)/63, (B5×B5)/31
///   using integer multiply + truncating shift
pub fn process_fragment(frag: &Fragment, state: &GpuState, memory: &mut GpuMemory) {
    let x = frag.x as u32;
    let y = frag.y as u32;

    // Bounds check against framebuffer
    if x >= memory.framebuffer.width || y >= memory.framebuffer.height {
        return;
    }

    // ── Depth test ──────────────────────────────────────────────────
    // Compare raw Q4.12 bits as signed i16 (matching RTL comparator)
    if !memory
        .depth_buffer
        .test_and_set(x, y, frag.depth, state.depth_func)
    {
        return; // fragment occluded
    }

    // ── Determine pixel color ───────────────────────────────────────
    let color = match state.bound_texture {
        Some(slot) => {
            let tex_color = memory.textures.sample_nearest(slot, frag.uv.u, frag.uv.v);
            modulate_rgb565(frag.color, tex_color)
        }
        None => frag.color,
    };

    // ── Write to framebuffer ────────────────────────────────────────
    memory.framebuffer.put_pixel(x, y, color);
}

/// Modulate (multiply) two RGB565 colors.
///
/// Per-channel: `out = (a × b) / max`, where max is 31 for R/B (5-bit)
/// and 63 for G (6-bit).
///
/// # RTL Implementation Notes
/// This uses small multipliers (5×5=10 bit, 6×6=12 bit) which fit
/// easily in the ECP5 fabric LUTs. The division by 31/63 is
/// approximated by right-shifting: `(a * b + 15) >> 5` for 5-bit
/// channels (equivalent to rounding), or `(a * b) >> 5` for truncation.
///
/// The twin uses truncating division to match the RTL's default behavior.
/// If your RTL rounds instead, change to `(prod + (max >> 1)) / max`.
fn modulate_rgb565(a: Rgb565, b: Rgb565) -> Rgb565 {
    let ar = (a.0 >> 11) & 0x1F;
    let ag = (a.0 >> 5) & 0x3F;
    let ab = a.0 & 0x1F;

    let br = (b.0 >> 11) & 0x1F;
    let bg = (b.0 >> 5) & 0x3F;
    let bb = b.0 & 0x1F;

    // Truncating: (a * b) / max
    // For 5-bit: max=31, multiply is 10 bits, divide by 31
    // For 6-bit: max=63, multiply is 12 bits, divide by 63
    let r = (ar * br) / 31;
    let g = (ag * bg) / 63;
    let b = (ab * bb) / 31;

    Rgb565((r << 11) | (g << 5) | b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modulate_white_preserves_color() {
        let white = Rgb565(0xFFFF); // R=31, G=63, B=31
        let color = Rgb565::from_rgb8(128, 64, 32);
        let result = modulate_rgb565(color, white);
        // Modulating by white (max) should preserve the original
        // (exact for integer channels, since 31*x/31 = x)
        assert_eq!(result, color);
    }

    #[test]
    fn modulate_black_yields_black() {
        let black = Rgb565(0);
        let color = Rgb565::from_rgb8(200, 100, 50);
        let result = modulate_rgb565(color, black);
        assert_eq!(result, Rgb565(0));
    }

    #[test]
    fn modulate_half_intensity() {
        // R=16 (~half of 31), G=32 (~half of 63), B=16
        let half = Rgb565((16 << 11) | (32 << 5) | 16);
        // Full white
        let white = Rgb565(0xFFFF);
        let result = modulate_rgb565(white, half);
        // 31*16/31 = 16, 63*32/63 = 32, 31*16/31 = 16
        let r = (result.0 >> 11) & 0x1F;
        let g = (result.0 >> 5) & 0x3F;
        let b = result.0 & 0x1F;
        assert_eq!(r, 16);
        assert_eq!(g, 32);
        assert_eq!(b, 16);
    }
}
