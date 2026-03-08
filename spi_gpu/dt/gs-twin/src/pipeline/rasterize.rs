//! Triangle rasterizer (fixed-point).
//!
//! Implements bounding-box rasterization with edge functions, operating
//! entirely on the fixed-point types defined in [`crate::math`].
//!
//! # Algorithm
//! 1. Compute axis-aligned bounding box of the screen-space triangle
//! 2. For each pixel center in the box, evaluate three edge functions
//! 3. If all three have the correct sign (inside), emit a fragment
//! 4. Compute barycentric coordinates for attribute interpolation
//! 5. Perspective-correct interpolation of UVs using 1/w
//!
//! # RTL Implementation Notes
//! The RTL rasterizer walks the bounding box row by row. Edge function
//! evaluation uses MULT18X18D for the cross-product terms. The pixel
//! center is at (x + 0.5, y + 0.5), which in Q12.4 is (x_int << 4 | 0x8).
//!
//! The RTL may use incremental edge function update (adding dx/dy per
//! step) rather than recomputing from scratch per pixel. Both produce
//! identical results; the twin uses per-pixel evaluation for clarity.

use crate::math::{
    truncating_narrow, Bary3, ColorChannel, Depth, EdgeAccum, Rgb565, ScreenCoord, TexVec2, WRecip,
};
use crate::pipeline::clip::edge_function;
use crate::pipeline::{Fragment, ScreenTriangle};
use crate::reg::Rgba8888;

/// Rasterize a screen-space triangle into fragments.
///
/// Returns all fragments that pass the inside test. Depth testing and
/// framebuffer writes happen in the fragment stage, not here.
///
/// # Numeric Behavior
/// - Pixel centers at (x+0.5, y+0.5) in Q12.4 = `(x << 4) | 0x8`
/// - Edge functions: Q16.16 (see [`edge_function`])
/// - Barycentric coords: normalized by dividing by triangle area (Q16.16)
/// - UV interpolation: perspective-correct using per-vertex 1/w
/// - Depth interpolation: linear in screen space (correct for Z/W)
pub fn rasterize_triangle(tri: &ScreenTriangle) -> Vec<Fragment> {
    let [ref v0, ref v1, ref v2] = tri.v;
    let mut fragments = Vec::new();

    // ── Bounding box in integer pixel coordinates ───────────────────
    let min_x = min3_screen(v0.x, v1.x, v2.x).max(ScreenCoord::ZERO);
    let min_y = min3_screen(v0.y, v1.y, v2.y).max(ScreenCoord::ZERO);
    let max_x = max3_screen(v0.x, v1.x, v2.x);
    let max_y = max3_screen(v0.y, v1.y, v2.y);

    // Convert to integer pixel range (floor of min, ceil of max)
    let px_min_x = screen_to_pixel_floor(min_x);
    let px_min_y = screen_to_pixel_floor(min_y);
    let px_max_x = screen_to_pixel_ceil(max_x).min(2047); // guard against runaway
    let px_max_y = screen_to_pixel_ceil(max_y).min(2047);

    // ── Triangle area (2× signed area) ──────────────────────────────
    let area = edge_function(v0.x, v0.y, v1.x, v1.y, v2.x, v2.y);
    if area == EdgeAccum::ZERO {
        return fragments; // degenerate
    }

    // Determine winding for inside test
    let ccw = area > EdgeAccum::ZERO;

    // ── Scanline traversal ──────────────────────────────────────────
    for py in px_min_y..=px_max_y {
        for px in px_min_x..=px_max_x {
            // Pixel center in Q12.4: integer part shifted, + 0.5 (= 8 in Q12.4)
            let cx = ScreenCoord::from_num(px) + ScreenCoord::from_bits(8);
            let cy = ScreenCoord::from_num(py) + ScreenCoord::from_bits(8);

            // Edge functions (= barycentric weights × 2·area)
            let w0 = edge_function(v1.x, v1.y, v2.x, v2.y, cx, cy);
            let w1 = edge_function(v2.x, v2.y, v0.x, v0.y, cx, cy);
            let w2 = edge_function(v0.x, v0.y, v1.x, v1.y, cx, cy);

            // Inside test: all edge functions must have same sign as area
            let inside = if ccw {
                w0 >= EdgeAccum::ZERO && w1 >= EdgeAccum::ZERO && w2 >= EdgeAccum::ZERO
            } else {
                w0 <= EdgeAccum::ZERO && w1 <= EdgeAccum::ZERO && w2 <= EdgeAccum::ZERO
            };

            if !inside {
                continue;
            }

            // ── Attribute interpolation ─────────────────────────
            // Barycentric normalization: b_i = w_i / area
            // We do this in Q16.16. Division in fixed-point uses
            // the `fixed` crate's implementation (truncating).
            let b0 = w0.wrapping_div(area);
            let b1 = w1.wrapping_div(area);
            let b2 = w2.wrapping_div(area);

            // ── Depth: linear interpolation in screen space ─────
            // Z was already divided by W during viewport transform,
            // so linear interpolation of Z is correct.
            let z0 = EdgeAccum::from(v0.z);
            let z1 = EdgeAccum::from(v1.z);
            let z2 = EdgeAccum::from(v2.z);
            let z_interp = b0.wrapping_mul(z0)
                .wrapping_add(b1.wrapping_mul(z1))
                .wrapping_add(b2.wrapping_mul(z2));
            let depth: Depth = truncating_narrow(z_interp);

            // ── Perspective-correct UV interpolation ────────────
            // UV/w is linear in screen space. Interpolate UV/w and
            // 1/w separately, then divide:
            //   uv = (b0·uv0/w0 + b1·uv1/w1 + b2·uv2/w2)
            //      / (b0/w0    + b1/w1    + b2/w2)
            let uv = interpolate_uv_perspective(
                b0, b1, b2, v0.w_recip, v1.w_recip, v2.w_recip, &v0.uv, &v1.uv, &v2.uv,
            );

            // ── Vertex color interpolation ──────────────────────
            let color = interpolate_color(b0, b1, b2, v0.color, v1.color, v2.color);

            fragments.push(Fragment {
                x: px as u16,
                y: py as u16,
                depth,
                uv,
                color,
                bary: Bary3 {
                    w0: b0,
                    w1: b1,
                    w2: b2,
                },
            });
        }
    }

    fragments
}

// ── Perspective-correct UV interpolation ────────────────────────────────────

/// Interpolate texture coordinates with perspective correction.
///
/// # Numeric Behavior
/// - Barycentric weights: Q16.16
/// - 1/w: Q0.16 (unsigned), widened to Q16.16 for multiply
/// - UV: Q2.14, widened to Q16.16 for multiply
/// - Intermediate products: Q16.16 (truncated)
/// - Final UV: Q2.14 (truncated from Q16.16)
///
/// # RTL Implementation Notes
/// This requires 6 multiplies (3 for numerator U, 3 for numerator V)
/// plus 3 multiplies for the denominator (b_i × 1/w_i), plus a
/// reciprocal and 2 final multiplies. The RTL may time-share the
/// MULT18X18D slices across these operations.
fn interpolate_uv_perspective(
    b0: EdgeAccum,
    b1: EdgeAccum,
    b2: EdgeAccum,
    w0: WRecip,
    w1: WRecip,
    w2: WRecip,
    uv0: &TexVec2,
    uv1: &TexVec2,
    uv2: &TexVec2,
) -> TexVec2 {
    // Widen all operands to EdgeAccum (Q16.16) for intermediate math
    let wr0 = EdgeAccum::from_num(w0);
    let wr1 = EdgeAccum::from_num(w1);
    let wr2 = EdgeAccum::from_num(w2);

    // Denominator: sum of b_i / w_i = sum of b_i × (1/w_i)
    let denom = b0.wrapping_mul(wr0)
        .wrapping_add(b1.wrapping_mul(wr1))
        .wrapping_add(b2.wrapping_mul(wr2));

    if denom == EdgeAccum::ZERO {
        return *uv0; // degenerate, return v0's UVs
    }

    let u0 = EdgeAccum::from_num(uv0.u);
    let u1 = EdgeAccum::from_num(uv1.u);
    let u2 = EdgeAccum::from_num(uv2.u);
    let v0 = EdgeAccum::from_num(uv0.v);
    let v1 = EdgeAccum::from_num(uv1.v);
    let v2 = EdgeAccum::from_num(uv2.v);

    // Numerator U: sum of b_i × u_i × (1/w_i)
    let num_u = b0.wrapping_mul(u0).wrapping_mul(wr0)
        .wrapping_add(b1.wrapping_mul(u1).wrapping_mul(wr1))
        .wrapping_add(b2.wrapping_mul(u2).wrapping_mul(wr2));

    // Numerator V: sum of b_i × v_i × (1/w_i)
    let num_v = b0.wrapping_mul(v0).wrapping_mul(wr0)
        .wrapping_add(b1.wrapping_mul(v1).wrapping_mul(wr1))
        .wrapping_add(b2.wrapping_mul(v2).wrapping_mul(wr2));

    // Final: uv = numerator / denominator
    let u_result = num_u.wrapping_div(denom);
    let v_result = num_v.wrapping_div(denom);

    TexVec2 {
        u: truncating_narrow(u_result),
        v: truncating_narrow(v_result),
    }
}

// ── Vertex color interpolation ──────────────────────────────────────────────

/// Barycentric interpolation of RGB565 vertex colors.
///
/// # Numeric Behavior
/// 1. Expand RGB565 → 3× Q1.7 channels ([`ColorChannel`])
/// 2. Interpolate each channel: `c = b0×c0 + b1×c1 + b2×c2`
///    where b_i are Q16.16 and c_i are Q1.7 (widened to Q16.16)
/// 3. Truncate result back to Q1.7
/// 4. Pack 3× Q1.7 → RGB565
///
/// # RTL Implementation Notes
/// Color interpolation may be done at reduced precision (e.g. only
/// using the top 8 bits of the barycentric weights) to save multiplier
/// cycles. If so, adjust the truncation here to match.
fn interpolate_color(
    b0: EdgeAccum,
    b1: EdgeAccum,
    b2: EdgeAccum,
    c0: Rgb565,
    c1: Rgb565,
    c2: Rgb565,
) -> Rgb565 {
    let (r0, g0, b0c) = c0.to_channels();
    let (r1, g1, b1c) = c1.to_channels();
    let (r2, g2, b2c) = c2.to_channels();

    let interp_channel =
        |ch0: ColorChannel, ch1: ColorChannel, ch2: ColorChannel| -> ColorChannel {
            let a = b0.wrapping_mul(EdgeAccum::from_num(ch0));
            let b = b1.wrapping_mul(EdgeAccum::from_num(ch1));
            let c = b2.wrapping_mul(EdgeAccum::from_num(ch2));
            let sum = a.wrapping_add(b).wrapping_add(c);
            truncating_narrow(sum)
        };

    let r = interp_channel(r0, r1, r2);
    let g = interp_channel(g0, g1, g2);
    let b = interp_channel(b0c, b1c, b2c);

    Rgb565::from_channels(r, g, b)
}

// ── Screen coordinate helpers ───────────────────────────────────────────────

fn min3_screen(a: ScreenCoord, b: ScreenCoord, c: ScreenCoord) -> ScreenCoord {
    a.min(b).min(c)
}

fn max3_screen(a: ScreenCoord, b: ScreenCoord, c: ScreenCoord) -> ScreenCoord {
    a.max(b).max(c)
}

/// Floor a Q12.4 screen coord to integer pixel (extract integer part).
fn screen_to_pixel_floor(s: ScreenCoord) -> i32 {
    // Q12.4: integer part is bits [15:4], fractional is [3:0]
    s.to_bits() as i32 >> 4
}

/// Ceil a Q12.4 screen coord to integer pixel.
fn screen_to_pixel_ceil(s: ScreenCoord) -> i32 {
    let bits = s.to_bits() as i32;
    let frac = bits & 0xF;
    let int = bits >> 4;
    if frac > 0 { int + 1 } else { int }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Integer-pixel rasterizer (matching RTL's rasterizer.sv)
// ═══════════════════════════════════════════════════════════════════════════
//
// The RTL truncates Q12.4 vertex coordinates to 10-bit integer pixels
// (bits [13:4]) and computes edge functions on these integer values.
// This section implements the same algorithm for bit-exact matching.

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

            // ── Color interpolation ──────────────────────────────
            let color = if tri.gouraud_en {
                interpolate_color_rgba8888(
                    w0, w1, w2, area2,
                    v0.color0, v1.color0, v2.color0,
                )
            } else {
                // Flat shading: use v0's color
                rgba8888_to_rgb565(v0.color0)
            };

            fragments.push(IntFragment {
                x: px as u16,
                y: py as u16,
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
        let num = w0 as i64 * ch0 as i64
            + w1 as i64 * ch1 as i64
            + w2 as i64 * ch2 as i64;
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
