//! Derivative precomputation matching `raster_deriv.sv` (UNIT-005.02).
//!
//! Computes per-attribute dx/dy derivatives and initial accumulator values
//! at the bounding box origin, given vertex data, edge coefficients,
//! reciprocal area, and winding.

// Spec-ref: unit_005.03_derivative_precomputation.md `0000000000000000` 1970-01-01

use crate::dsp_mul::{dsp_mul, shift_mul_32x11};
use crate::setup::EdgeCoeffs;
use gs_twin_core::triangle::RasterTriangle;

// ── Attribute indices ──────────────────────────────────────────────────────

/// Number of interpolated attributes (matching RTL's 14-attribute pipeline).
pub const NUM_ATTRS: usize = 14;

/// Color0 red channel index.
pub const ATTR_C0R: usize = 0;
/// Color0 green channel index.
pub const ATTR_C0G: usize = 1;
/// Color0 blue channel index.
pub const ATTR_C0B: usize = 2;
/// Color0 alpha channel index.
pub const ATTR_C0A: usize = 3;
/// Color1 red channel index.
pub const ATTR_C1R: usize = 4;
/// Color1 green channel index.
pub const ATTR_C1G: usize = 5;
/// Color1 blue channel index.
pub const ATTR_C1B: usize = 6;
/// Color1 alpha channel index.
pub const ATTR_C1A: usize = 7;
/// Depth (Z) attribute index.
pub const ATTR_Z: usize = 8;
/// Texture 0 S coordinate index.
pub const ATTR_S0: usize = 9;
/// Texture 0 T coordinate index.
pub const ATTR_T0: usize = 10;
/// Perspective Q/W denominator index.
pub const ATTR_Q: usize = 11;
/// Texture 1 S coordinate index.
pub const ATTR_S1: usize = 12;
/// Texture 1 T coordinate index.
pub const ATTR_T1: usize = 13;

/// Result of derivative precomputation for all 14 attributes.
///
/// Intermediate data structure exposed for per-module verification
/// against `raster_deriv.sv` testbench stimulus.
#[derive(Clone, Copy, Debug)]
pub struct DerivResult {
    /// Per-attribute dx derivatives (32-bit signed).
    pub dx: [i32; NUM_ATTRS],

    /// Per-attribute dy derivatives (32-bit signed).
    pub dy: [i32; NUM_ATTRS],

    /// Initial attribute values at bbox origin (32-bit signed).
    pub inits: [i32; NUM_ATTRS],
}

/// Compute per-attribute derivatives and initial values.
///
/// Matches the RTL's `raster_deriv` module: delta extraction, DSP multiply
/// by `inv_area`, edge coefficient application (shift-add), area shift,
/// and initial value computation at the bbox origin.
///
/// # Arguments
///
/// * `tri` - Input triangle with vertex attributes.
/// * `edges` - Three edge function coefficient sets from setup.
/// * `inv_area` - UQ1.17 reciprocal area mantissa from `recip_area`.
/// * `area_shift` - Right-shift for denormalization.
/// * `ccw` - Triangle winding (true = CCW, positive area).
/// * `bbox_min_x` - Bounding box origin X.
/// * `bbox_min_y` - Bounding box origin Y.
///
/// # Returns
///
/// `DerivResult` containing all dx/dy arrays and initial values.
pub fn compute_derivatives(
    tri: &RasterTriangle,
    edges: &[EdgeCoeffs; 3],
    inv_area: u32,
    area_shift: u8,
    ccw: bool,
    bbox_min_x: u16,
    bbox_min_y: u16,
) -> DerivResult {
    let [ref v0, ref v1, ref v2] = tri.verts;

    let x0 = v0.px as i32;
    let y0 = v0.py as i32;

    // ── Vertex attribute deltas ────────────────────────────────────
    // Color deltas: 9-bit signed (from u8 difference)
    // Matching raster_deriv.sv: $signed({1'b0, ch1}) - $signed({1'b0, ch0})
    let color_delta = |ch0: u8, ch1: u8| -> i32 { ch1 as i32 - ch0 as i32 };

    // Wide deltas: 17-bit signed
    // Z: unsigned difference via sign-extension: $signed({1'b0, z1}) - $signed({1'b0, z0})
    let wide_unsigned_delta = |a: u16, b: u16| -> i32 { b as i32 - a as i32 };

    // ST: signed difference via sign-extension: {s1[15], s1} - {s0[15], s0}
    let wide_signed_delta = |a: u16, b: u16| -> i32 { (b as i16 as i32) - (a as i16 as i32) };

    // d10 = attr[v1] - attr[v0], d20 = attr[v2] - attr[v0]
    let d10: [i32; NUM_ATTRS] = [
        color_delta(v0.color0.r(), v1.color0.r()),
        color_delta(v0.color0.g(), v1.color0.g()),
        color_delta(v0.color0.b(), v1.color0.b()),
        color_delta(v0.color0.a(), v1.color0.a()),
        color_delta(v0.color1.r(), v1.color1.r()),
        color_delta(v0.color1.g(), v1.color1.g()),
        color_delta(v0.color1.b(), v1.color1.b()),
        color_delta(v0.color1.a(), v1.color1.a()),
        wide_unsigned_delta(v0.z, v1.z),
        wide_signed_delta(v0.s0, v1.s0),
        wide_signed_delta(v0.t0, v1.t0),
        wide_unsigned_delta(v0.q, v1.q),
        wide_signed_delta(v0.s1, v1.s1),
        wide_signed_delta(v0.t1, v1.t1),
    ];

    let d20: [i32; NUM_ATTRS] = [
        color_delta(v0.color0.r(), v2.color0.r()),
        color_delta(v0.color0.g(), v2.color0.g()),
        color_delta(v0.color0.b(), v2.color0.b()),
        color_delta(v0.color0.a(), v2.color0.a()),
        color_delta(v0.color1.r(), v2.color1.r()),
        color_delta(v0.color1.g(), v2.color1.g()),
        color_delta(v0.color1.b(), v2.color1.b()),
        color_delta(v0.color1.a(), v2.color1.a()),
        wide_unsigned_delta(v0.z, v2.z),
        wide_signed_delta(v0.s0, v2.s0),
        wide_signed_delta(v0.t0, v2.t0),
        wide_unsigned_delta(v0.q, v2.q),
        wide_signed_delta(v0.s1, v2.s1),
        wide_signed_delta(v0.t1, v2.t1),
    ];

    // ── Derivative computation ─────────────────────────────────────
    // Matching raster_deriv.sv:
    //   1. delta * inv_area (17-bit signed × 18-bit unsigned → 36-bit signed)
    //   2. scaled * edge_coeff (47-bit × 11-bit → 47-bit, shift-add)
    //   3. deriv = (d10_scaled * edge1_coeff + d20_scaled * edge2_coeff) >>> area_shift
    //
    // Uses edges[1] (edge1) and edges[2] (edge2) for derivatives.
    let edge1_a = edges[1].a as i64;
    let edge1_b = edges[1].b as i64;
    let edge2_a = edges[2].a as i64;
    let edge2_b = edges[2].b as i64;

    let mut dx_derivs = [0i32; NUM_ATTRS];
    let mut dy_derivs = [0i32; NUM_ATTRS];

    for i in 0..NUM_ATTRS {
        // Step 1: delta * inv_area (signed 17 × unsigned 18 → signed 36)
        // Matching raster_dsp_mul.sv: |a| * b, restore sign
        let d10_inv = dsp_mul(d10[i], inv_area);
        let d20_inv = dsp_mul(d20[i], inv_area);

        // Step 2: edge coefficient application (47-bit shift-add)
        // dx = d10_inv * edge1_A + d20_inv * edge2_A
        // dy = d10_inv * edge1_B + d20_inv * edge2_B
        let scaled_dx = d10_inv * edge1_a + d20_inv * edge2_a;
        let scaled_dy = d10_inv * edge1_b + d20_inv * edge2_b;

        // Step 3: arithmetic right shift by area_shift, truncate to 32-bit.
        // The reciprocal is computed from |area|, so for CW triangles
        // (area < 0) we must negate to get the correct signed 1/area.
        let sign = if ccw { 1i32 } else { -1 };
        dx_derivs[i] = ((scaled_dx >> area_shift) as i32).wrapping_mul(sign);
        dy_derivs[i] = ((scaled_dy >> area_shift) as i32).wrapping_mul(sign);
    }

    // Force color derivatives to zero when Gouraud is disabled
    if !tri.gouraud_en {
        for i in ATTR_C0R..=ATTR_C1A {
            dx_derivs[i] = 0;
            dy_derivs[i] = 0;
        }
    }

    // ── Initial values at bbox origin ──────────────────────────────
    // Matching raster_deriv.sv init computation:
    //   init = f0 + dx * (bbox_x - x0) + dy * (bbox_y - y0)
    //
    // f0 format:
    //   Colors: {8'b0, unorm8, 16'b0} = (u8 as i32) << 16
    //   Z:      {z16, 16'b0}          = (z as i32) << 16
    //   ST:     {st_q412, 16'b0}      = (i16 as i32) << 16
    //   Q:      {q16, 16'b0}          = (q as i32) << 16

    let bbox_sx = bbox_min_x as i32 - x0;
    let bbox_sy = bbox_min_y as i32 - y0;

    let f0: [i32; NUM_ATTRS] = [
        (v0.color0.r() as i32) << 16,
        (v0.color0.g() as i32) << 16,
        (v0.color0.b() as i32) << 16,
        (v0.color0.a() as i32) << 16,
        (v0.color1.r() as i32) << 16,
        (v0.color1.g() as i32) << 16,
        (v0.color1.b() as i32) << 16,
        (v0.color1.a() as i32) << 16,
        ((v0.z as u32) << 16) as i32,
        (v0.s0 as i16 as i32) << 16,
        (v0.t0 as i16 as i32) << 16,
        ((v0.q as u32) << 16) as i32,
        (v0.s1 as i16 as i32) << 16,
        (v0.t1 as i16 as i32) << 16,
    ];

    let mut inits = [0i32; NUM_ATTRS];
    for i in 0..NUM_ATTRS {
        // init = f0 + dx * bbox_sx + dy * bbox_sy
        // Matching raster_shift_mul_32x11: 32-bit × 11-bit → 32-bit truncated
        let dx_term = shift_mul_32x11(dx_derivs[i], bbox_sx);
        let dy_term = shift_mul_32x11(dy_derivs[i], bbox_sy);
        inits[i] = f0[i].wrapping_add(dx_term).wrapping_add(dy_term);
    }

    DerivResult {
        dx: dx_derivs,
        dy: dy_derivs,
        inits,
    }
}
