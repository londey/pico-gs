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
    truncating_narrow, Bary3, ColorChannel, Coord, Depth, EdgeAccum, Rgb565, ScreenCoord,
    TexCoord, TexVec2, WRecip,
};
use crate::pipeline::clip::edge_function;
use crate::pipeline::{Fragment, ScreenTriangle};

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
