//! Clipping, culling, and viewport projection (fixed-point).
//!
//! Takes clip-space vertices (Q16.16) and produces screen-space triangles:
//!   1. Trivial-reject triangles fully outside the frustum
//!   2. Perspective divide: clip → NDC (using fixed-point reciprocal)
//!   3. Viewport transform: NDC → screen pixels (Q12.4)
//!   4. Backface / frontface culling (screen-space winding via edge function)
//!
//! # RTL Implementation Notes
//! The RTL likely uses guard-band clipping or scissor-based rejection
//! rather than full Sutherland-Hodgman clipping against all 6 planes.
//! This twin starts with trivial reject (all 3 verts behind near plane)
//! and can be tightened to match the RTL's exact strategy.
//!
//! The perspective divide (1/w) is computed by the RP2350 host or by a
//! LUT + Newton-Raphson block in the RTL. The twin models the result
//! as a Q0.16 unsigned value ([`WRecip`]).

use crate::cmd::CullMode;
use crate::math::{
    truncating_narrow, Coord, Depth, EdgeAccum, ScreenCoord, WRecip,
};
use crate::pipeline::{ClipVertex, ScreenTriangle, ScreenVertex, Viewport};

/// Clip, cull, and project three clip-space vertices to a screen-space triangle.
///
/// Returns `None` if the triangle is culled or fully clipped.
///
/// # Numeric Behavior
/// - Clip-space inputs: Q16.16
/// - Near-plane test: `z < -w` (signed comparison on Q16.16)
/// - Perspective divide: multiply by precomputed 1/w (Q0.16)
/// - Viewport transform: scale + offset to Q12.4 screen coords
/// - Cull test: signed area via edge function on Q12.4 coords
pub fn clip_and_project(
    v0: &ClipVertex,
    v1: &ClipVertex,
    v2: &ClipVertex,
    viewport: &Viewport,
    cull_mode: CullMode,
) -> Option<ScreenTriangle> {
    // ── Trivial reject: all three vertices behind near plane ─────────
    // In clip space, behind near plane when z < -w.
    let behind_0 = v0.clip_pos.z < v0.clip_pos.w.wrapping_neg();
    let behind_1 = v1.clip_pos.z < v1.clip_pos.w.wrapping_neg();
    let behind_2 = v2.clip_pos.z < v2.clip_pos.w.wrapping_neg();
    if behind_0 && behind_1 && behind_2 {
        return None;
    }

    // ── Reject degenerate W ─────────────────────────────────────────
    // If any vertex has w ≤ 0 after clipping, skip the triangle.
    // (Full clipping would split it; we reject for now.)
    if v0.clip_pos.w <= Coord::ZERO
        || v1.clip_pos.w <= Coord::ZERO
        || v2.clip_pos.w <= Coord::ZERO
    {
        return None;
    }

    // ── Perspective divide + viewport transform ─────────────────────
    let sv0 = project_vertex(v0, viewport);
    let sv1 = project_vertex(v1, viewport);
    let sv2 = project_vertex(v2, viewport);

    // ── Backface culling (screen-space signed area) ─────────────────
    // 2× signed area = (v1-v0) × (v2-v0), computed on Q12.4 coords.
    // Positive = CCW (front-facing), negative = CW (back-facing).
    let signed_area = edge_function(sv0.x, sv0.y, sv1.x, sv1.y, sv2.x, sv2.y);
    match cull_mode {
        CullMode::Backface if signed_area <= EdgeAccum::ZERO => return None,
        CullMode::Frontface if signed_area >= EdgeAccum::ZERO => return None,
        _ => {}
    }

    // Reject degenerate (zero-area) triangles
    if signed_area == EdgeAccum::ZERO {
        return None;
    }

    Some(ScreenTriangle {
        v: [sv0, sv1, sv2],
    })
}

/// Project a single clip-space vertex to screen space.
///
/// # Numeric Behavior
/// 1. Compute 1/w as Q0.16 (unsigned). In the RTL this is precomputed
///    or uses a LUT. Here we convert via f32 as a placeholder — replace
///    with your RTL's actual reciprocal method for bit-exact matching.
/// 2. NDC = clip_xyz × (1/w), yielding Q16.16 NDC coords in [-1, 1].
/// 3. Viewport: screen_x = vp.x + (ndc_x + 1) × vp.width/2,
///    truncated to Q12.4.
fn project_vertex(v: &ClipVertex, vp: &Viewport) -> ScreenVertex {
    // ── 1/w computation ─────────────────────────────────────────────
    // TODO: Replace with your RTL's reciprocal implementation
    // (LUT + Newton-Raphson) for bit-exact matching. This f32
    // intermediate is a placeholder that gets the algorithm right
    // but may differ by ±1 LSB from the hardware.
    let w_f32: f32 = f32::from(v.clip_pos.w.to_num::<f32>());
    let w_recip_f32 = 1.0 / w_f32;
    let w_recip = WRecip::from_num(w_recip_f32.clamp(0.0, 0.999985));

    // ── NDC: clip × (1/w) ───────────────────────────────────────────
    // Widen 1/w to Coord for multiplication.
    let w_recip_wide = Coord::from_num(w_recip);
    let ndc_x = v.clip_pos.x.wrapping_mul(w_recip_wide);
    let ndc_y = v.clip_pos.y.wrapping_mul(w_recip_wide);
    let ndc_z = v.clip_pos.z.wrapping_mul(w_recip_wide);

    // ── Viewport transform → Q12.4 screen coords ───────────────────
    let half_w = Coord::from_num(vp.width >> 1);
    let half_h = Coord::from_num(vp.height >> 1);
    let vp_x = Coord::from_num(vp.x);
    let vp_y = Coord::from_num(vp.y);

    // screen_x = vp.x + half_w + ndc_x * half_w
    let sx = vp_x
        .wrapping_add(half_w)
        .wrapping_add(ndc_x.wrapping_mul(half_w));

    // screen_y = vp.y + half_h - ndc_y * half_h  (Y flipped)
    let sy = vp_y
        .wrapping_add(half_h)
        .wrapping_sub(ndc_y.wrapping_mul(half_h));

    // depth: map ndc_z from [-1, 1] → [0, 1] in Q4.12
    // depth = (ndc_z + 1) / 2
    let ndc_z_plus_one = ndc_z.wrapping_add(Coord::ONE);
    let depth_coord = ndc_z_plus_one >> 1u32; // divide by 2
    let depth: Depth = truncating_narrow(depth_coord);

    ScreenVertex {
        x: truncating_narrow(sx),
        y: truncating_narrow(sy),
        z: depth,
        w_recip,
        uv: v.uv,
        color: v.color,
    }
}

/// 2× signed area of a screen-space triangle (edge function).
///
/// `edge_fn(v0, v1, p) = (v1.x - v0.x) × (p.y - v0.y) - (v1.y - v0.y) × (p.x - v0.x)`
///
/// Inputs are Q12.4, products are Q24.8, result accumulated in Q16.16
/// (wrapping to match RTL).
///
/// # RTL Implementation Notes
/// Each cross-product term uses one MULT18X18D. The subtraction and
/// final difference use the ALU fabric.
pub(crate) fn edge_function(
    v0x: ScreenCoord,
    v0y: ScreenCoord,
    v1x: ScreenCoord,
    v1y: ScreenCoord,
    px: ScreenCoord,
    py: ScreenCoord,
) -> EdgeAccum {
    // Widen to EdgeAccum (Q16.16) before multiply to match RTL precision
    let dx1 = EdgeAccum::from(v1x) - EdgeAccum::from(v0x);
    let dy_p = EdgeAccum::from(py) - EdgeAccum::from(v0y);
    let dy1 = EdgeAccum::from(v1y) - EdgeAccum::from(v0y);
    let dx_p = EdgeAccum::from(px) - EdgeAccum::from(v0x);

    dx1.wrapping_mul(dy_p).wrapping_sub(dy1.wrapping_mul(dx_p))
}
