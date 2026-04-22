//! Triangle setup matching `rasterizer.sv` S_SETUP phase.
//!
//! Computes edge function coefficients, signed area, bounding box,
//! and orchestrates reciprocal area + derivative computation.

// Spec-ref: unit_005_rasterizer.md `0000000000000000` 1970-01-01

use crate::deriv::{self, DerivResult, NUM_ATTRS};
use crate::recip;
use gs_twin_core::triangle::RasterTriangle;

/// Edge function coefficients for one edge.
///
/// Edge evaluation: `e(x,y) = a*x + b*y + c`.
/// Matches RTL `rasterizer.sv` edge register widths.
#[derive(Debug, Clone, Copy, Default)]
pub struct EdgeCoeffs {
    /// X coefficient, 11-bit signed (matching RTL `signed [10:0]`).
    pub a: i32,
    /// Y coefficient, 11-bit signed.
    pub b: i32,
    /// Constant term, 21-bit signed.
    pub c: i32,
}

/// Result of triangle setup — all precomputed data for fragment iteration.
///
/// This struct is the interface between setup and iteration phases,
/// matching the data passed through `raster_setup_fifo` in the RTL.
#[derive(Clone, Copy)]
pub struct TriangleSetup {
    /// Edge function coefficients for 3 edges.
    pub edges: [EdgeCoeffs; 3],

    /// True if triangle has CCW winding (positive area).
    pub ccw: bool,

    /// Bounding box minimum X (tile-aligned for RTL matching).
    pub bbox_min_x: u16,
    /// Bounding box minimum Y.
    pub bbox_min_y: u16,
    /// Bounding box maximum X.
    pub bbox_max_x: u16,
    /// Bounding box maximum Y.
    pub bbox_max_y: u16,

    /// Per-attribute dx derivatives (32-bit signed, matching RTL `signed [31:0]`).
    pub dx: [i32; NUM_ATTRS],

    /// Per-attribute dy derivatives (32-bit signed).
    pub dy: [i32; NUM_ATTRS],

    /// Initial attribute values at bbox origin (32-bit signed).
    pub inits: [i32; NUM_ATTRS],

    /// Whether Gouraud interpolation is enabled.
    pub gouraud_en: bool,
}

/// Perform triangle setup: compute edge coefficients, derivatives, and
/// initial values.
///
/// Returns `None` for degenerate triangles (zero area).
///
/// Matches the RTL's `rasterizer.sv` S_SETUP + `raster_recip_area` +
/// `raster_deriv` pipeline.
///
/// # Arguments
///
/// * `tri` - Input triangle with vertex positions and attributes.
///
/// # Returns
///
/// `Some(TriangleSetup)` on success, `None` for degenerate triangles.
pub fn triangle_setup(tri: &RasterTriangle) -> Option<TriangleSetup> {
    let [ref v0, ref v1, ref v2] = tri.verts;

    let x0 = v0.px as i32;
    let y0 = v0.py as i32;
    let x1 = v1.px as i32;
    let y1 = v1.py as i32;
    let x2 = v2.px as i32;
    let y2 = v2.py as i32;

    // ── Edge function coefficients ─────────────────────────────────
    // Matching rasterizer.sv S_SETUP:
    //   edge0: (v1, v2) — tests against v0's half-plane
    //   edge1: (v2, v0) — tests against v1's half-plane
    //   edge2: (v0, v1) — tests against v2's half-plane
    let edges = [
        EdgeCoeffs {
            a: y1 - y2,
            b: x2 - x1,
            c: x1 * y2 - x2 * y1,
        },
        EdgeCoeffs {
            a: y2 - y0,
            b: x0 - x2,
            c: x2 * y0 - x0 * y2,
        },
        EdgeCoeffs {
            a: y0 - y1,
            b: x1 - x0,
            c: x0 * y1 - x1 * y0,
        },
    ];

    // 2× signed area = evaluate edge0 at v0
    let area2 = edges[0].a * x0 + edges[0].b * y0 + edges[0].c;
    if area2 == 0 {
        return None; // degenerate triangle
    }

    let ccw = area2 > 0;

    // ── Bounding box ───────────────────────────────────────────────
    // Clamp triangle bbox to provided scissor limits
    let tri_min_x = (x0.min(x1).min(x2).max(tri.bbox_min_x as i32)) as u16;
    let tri_max_x = (x0.max(x1).max(x2).min(tri.bbox_max_x as i32)) as u16;
    let tri_min_y = (y0.min(y1).min(y2).max(tri.bbox_min_y as i32)) as u16;
    let tri_max_y = (y0.max(y1).max(y2).min(tri.bbox_max_y as i32)) as u16;

    // ── Reciprocal area ────────────────────────────────────────────
    // Matching raster_recip_area.sv: 22-bit signed input
    let recip = recip::recip_area(area2)?;

    // ── Derivatives and initial values ─────────────────────────────
    let DerivResult { dx, dy, inits } = deriv::compute_derivatives(
        tri,
        &edges,
        recip.mantissa,
        recip.area_shift,
        ccw,
        tri_min_x,
        tri_min_y,
    );

    Some(TriangleSetup {
        edges,
        ccw,
        bbox_min_x: tri_min_x,
        bbox_min_y: tri_min_y,
        bbox_max_x: tri_max_x,
        bbox_max_y: tri_max_y,
        dx,
        dy,
        inits,
        gouraud_en: tri.gouraud_en,
    })
}
