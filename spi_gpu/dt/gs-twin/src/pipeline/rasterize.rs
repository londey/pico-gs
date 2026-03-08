//! Integer-pixel triangle rasterizer matching the RTL's rasterizer.sv.
//!
//! The RTL truncates Q12.4 vertex coordinates to 10-bit integer pixels
//! (bits [13:4]) and computes edge functions on these integer values.
//! This module implements the same algorithm for bit-exact matching.
//!
//! # Algorithm
//! 1. Compute edge function coefficients (A, B, C) from integer vertices
//! 2. Walk the bounding box pixel by pixel
//! 3. Test each pixel against all three edge functions
//! 4. For inside pixels, interpolate color and depth using barycentrics
//!
//! # RTL Implementation Notes
//! Edge function: `e_i(x,y) = A_i * x + B_i * y + C_i`
//! where A = (y_j - y_k), B = (x_k - x_j), C = x_j*y_k - x_k*y_j.
//! The RTL uses 11-bit signed A/B and 21-bit signed C.

use crate::math::Rgb565;
use crate::reg::Rgba8888;

/// Integer-pixel vertex for the register-write path.
///
/// Matches the RTL's latched vertex registers after Q12.4 → pixel truncation.
#[derive(Debug, Clone, Copy, Default)]
pub struct IntVertex {
    /// Integer pixel X (0..1023), from Q12.4 bits [13:4].
    pub px: u16,
    /// Integer pixel Y (0..1023).
    pub py: u16,
    /// Depth, unsigned 16-bit.
    pub z: u16,
    /// Diffuse color (RGBA8888).
    pub color0: Rgba8888,
}

/// Triangle input for integer-pixel rasterization.
#[derive(Debug, Clone, Copy)]
pub struct IntTriangle {
    pub verts: [IntVertex; 3],
    /// Bounding box limits (clamped to scissor/surface).
    pub bbox_min_x: u16,
    pub bbox_max_x: u16,
    pub bbox_min_y: u16,
    pub bbox_max_y: u16,
    /// Whether Gouraud interpolation is enabled.
    pub gouraud_en: bool,
}

/// Fragment output from integer-pixel rasterization.
#[derive(Debug, Clone, Copy)]
pub struct IntFragment {
    pub x: u16,
    pub y: u16,
    /// Interpolated depth (unsigned 16-bit), for Z-test.
    pub z: u16,
    pub color: Rgb565,
}

/// Rasterize a triangle using integer pixel coordinates.
///
/// This matches the RTL's rasterizer.sv algorithm:
/// 1. Compute edge function coefficients (A, B, C) from integer vertices
/// 2. Walk the bounding box pixel by pixel
/// 3. Test each pixel against all three edge functions
/// 4. For inside pixels, interpolate color using barycentrics
///
/// # RTL Implementation Notes
/// Edge function: `e_i(x,y) = A_i * x + B_i * y + C_i`
/// where A = (y_j - y_k), B = (x_k - x_j), C = x_j*y_k - x_k*y_j.
/// The RTL uses 11-bit signed A/B and 21-bit signed C.
/// We use i32 for headroom (matching the RTL's multiplier widths).
pub fn rasterize_int_triangle(tri: &IntTriangle) -> Vec<IntFragment> {
    let [ref v0, ref v1, ref v2] = tri.verts;
    let mut fragments = Vec::new();

    let x0 = v0.px as i32;
    let y0 = v0.py as i32;
    let x1 = v1.px as i32;
    let y1 = v1.py as i32;
    let x2 = v2.px as i32;
    let y2 = v2.py as i32;

    // ── Edge function coefficients ───────────────────────────────────
    // Matching rasterizer.sv S_SETUP:
    //   edge0: (v1, v2) — tests against v0's half-plane
    //   edge1: (v2, v0) — tests against v1's half-plane
    //   edge2: (v0, v1) — tests against v2's half-plane
    let e0_a = y1 - y2;
    let e0_b = x2 - x1;
    let e0_c = x1 * y2 - x2 * y1;

    let e1_a = y2 - y0;
    let e1_b = x0 - x2;
    let e1_c = x2 * y0 - x0 * y2;

    let e2_a = y0 - y1;
    let e2_b = x1 - x0;
    let e2_c = x0 * y1 - x1 * y0;

    // 2× signed area = e0_a * x0 + e0_b * y0 + e0_c (evaluate edge0 at v0)
    let area2 = e0_a * x0 + e0_b * y0 + e0_c;
    if area2 == 0 {
        return fragments; // degenerate triangle
    }

    // Bounding box: clamp triangle bbox to provided limits
    let tri_min_x = x0.min(x1).min(x2).max(tri.bbox_min_x as i32);
    let tri_max_x = x0.max(x1).max(x2).min(tri.bbox_max_x as i32);
    let tri_min_y = y0.min(y1).min(y2).max(tri.bbox_min_y as i32);
    let tri_max_y = y0.max(y1).max(y2).min(tri.bbox_max_y as i32);

    // CCW = positive area
    let ccw = area2 > 0;

    // ── Scanline walk ────────────────────────────────────────────────
    for py in tri_min_y..=tri_max_y {
        for px in tri_min_x..=tri_max_x {
            // Evaluate edge functions at (px, py)
            let w0 = e0_a * px + e0_b * py + e0_c;
            let w1 = e1_a * px + e1_b * py + e1_c;
            let w2 = e2_a * px + e2_b * py + e2_c;

            // Inside test: all edge functions same sign as area
            let inside = if ccw {
                w0 >= 0 && w1 >= 0 && w2 >= 0
            } else {
                w0 <= 0 && w1 <= 0 && w2 <= 0
            };

            if !inside {
                continue;
            }

            // ── Z interpolation ───────────────────────────────────
            let z_interp = {
                let num =
                    w0 as i64 * v0.z as i64 + w1 as i64 * v1.z as i64 + w2 as i64 * v2.z as i64;
                (num / area2 as i64).clamp(0, 0xFFFF) as u16
            };

            // ── Color interpolation ──────────────────────────────
            let color = if tri.gouraud_en {
                interpolate_color_rgba8888(w0, w1, w2, area2, v0.color0, v1.color0, v2.color0)
            } else {
                // Flat shading: use v0's color
                rgba8888_to_rgb565(v0.color0)
            };

            fragments.push(IntFragment {
                x: px as u16,
                y: py as u16,
                z: z_interp,
                color,
            });
        }
    }

    fragments
}

/// Interpolate RGBA8888 vertex colors using barycentric weights.
///
/// Performs per-channel 8-bit interpolation:
///   `ch = (w0 * ch0 + w1 * ch1 + w2 * ch2) / area2`
/// then packs the result as RGB565.
///
/// Uses i64 intermediates to avoid overflow:
/// - w_i: up to ~512*512 = 262144 (fits i32)
/// - ch_i: 0..255 (u8)
/// - w_i * ch_i: up to ~67M (fits i32)
/// - sum of 3: up to ~200M (fits i32)
/// - But for safety with larger triangles, use i64.
fn interpolate_color_rgba8888(
    w0: i32,
    w1: i32,
    w2: i32,
    area2: i32,
    c0: Rgba8888,
    c1: Rgba8888,
    c2: Rgba8888,
) -> Rgb565 {
    let interp_channel = |ch0: u8, ch1: u8, ch2: u8| -> u8 {
        let num = w0 as i64 * ch0 as i64 + w1 as i64 * ch1 as i64 + w2 as i64 * ch2 as i64;
        // Truncating division (toward zero), matching RTL behavior
        (num / area2 as i64).clamp(0, 255) as u8
    };

    let r = interp_channel(c0.r(), c1.r(), c2.r());
    let g = interp_channel(c0.g(), c1.g(), c2.g());
    let b = interp_channel(c0.b(), c1.b(), c2.b());

    Rgb565::from_rgb8(r, g, b)
}

/// Convert RGBA8888 to RGB565 (truncating, no rounding).
fn rgba8888_to_rgb565(c: Rgba8888) -> Rgb565 {
    Rgb565::from_rgb8(c.r(), c.g(), c.b())
}
