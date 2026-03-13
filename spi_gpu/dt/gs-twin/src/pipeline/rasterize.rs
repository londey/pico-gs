//! Derivative-based triangle rasterizer matching the RTL pipeline.
//!
//! The RTL rasterizer (rasterizer.sv and submodules) uses a two-phase approach:
//! 1. **Triangle setup**: compute edge function coefficients, reciprocal area,
//!    per-attribute dx/dy derivatives, and initial values at the bounding box
//!    origin.
//! 2. **Per-fragment iteration**: walk 4×4 tiles over the bounding box with
//!    hierarchical rejection, incrementally accumulate attributes, apply
//!    perspective correction, and emit fragments.
//!
//! All intermediate values use explicit bit widths matching the RTL.
//! The digital twin is transaction-level (not cycle-accurate) but bit-accurate
//! for the math.

use super::debug_pixel::RasterAccumulatorDebug;
use super::fragment::{ColorQ412, RasterFragment};
use super::recip;
use crate::reg::Rgba8888;

// ── Attribute indices ──────────────────────────────────────────────────────

const ATTR_C0R: usize = 0;
const ATTR_C0G: usize = 1;
const ATTR_C0B: usize = 2;
const ATTR_C0A: usize = 3;
const ATTR_C1R: usize = 4;
const ATTR_C1G: usize = 5;
const ATTR_C1B: usize = 6;
const ATTR_C1A: usize = 7;
const ATTR_Z: usize = 8;
const ATTR_S0: usize = 9;
const ATTR_T0: usize = 10;
const ATTR_Q: usize = 11;
const ATTR_S1: usize = 12;
const ATTR_T1: usize = 13;
const NUM_ATTRS: usize = 14;

/// Tile size for hierarchical edge walk (matching RTL's 4×4 tiles).
const TILE_SIZE: u16 = 4;

// ── Input types ────────────────────────────────────────────────────────────

/// Full vertex data matching the RTL's per-vertex register bundle.
///
/// Contains all attributes needed for rasterization: position, depth,
/// perspective factor, two color sets, and texture coordinates.
#[derive(Debug, Clone, Copy, Default)]
pub struct RasterVertex {
    /// Integer pixel X (0..1023), from Q12.4 bits \[13:4\].
    pub px: u16,

    /// Integer pixel Y (0..1023).
    pub py: u16,

    /// Depth, unsigned 16-bit.
    pub z: u16,

    /// Q/W perspective denominator, unsigned 16-bit (from VERTEX register).
    pub q: u16,

    /// Diffuse color (RGBA8888).
    pub color0: Rgba8888,

    /// Specular color (RGBA8888).
    pub color1: Rgba8888,

    /// TEX0 S coordinate (Q4.12 raw bits, signed).
    pub s0: u16,

    /// TEX0 T coordinate (Q4.12 raw bits, signed).
    pub t0: u16,

    /// TEX1 S coordinate (Q4.12 raw bits, signed).
    pub s1: u16,

    /// TEX1 T coordinate (Q4.12 raw bits, signed).
    pub t1: u16,
}

/// Triangle input for rasterization.
#[derive(Debug, Clone, Copy)]
pub struct RasterTriangle {
    /// Three vertices in winding order.
    pub verts: [RasterVertex; 3],

    /// Bounding box minimum X (clamped to scissor/surface).
    pub bbox_min_x: u16,

    /// Bounding box maximum X (clamped to scissor/surface).
    pub bbox_max_x: u16,

    /// Bounding box minimum Y (clamped to scissor/surface).
    pub bbox_min_y: u16,

    /// Bounding box maximum Y (clamped to scissor/surface).
    pub bbox_max_y: u16,

    /// Whether Gouraud interpolation is enabled for vertex colors.
    pub gouraud_en: bool,
}

// ── Triangle setup ─────────────────────────────────────────────────────────

/// Edge function coefficients for one edge.
///
/// Edge evaluation: `e(x,y) = a*x + b*y + c`
#[derive(Debug, Clone, Copy, Default)]
struct EdgeCoeffs {
    /// X coefficient, 11-bit signed (matching RTL `signed [10:0]`).
    a: i32,
    /// Y coefficient, 11-bit signed.
    b: i32,
    /// Constant term, 21-bit signed.
    c: i32,
}

/// Result of triangle setup — all precomputed data for fragment iteration.
#[derive(Clone, Copy)]
pub struct TriangleSetup {
    /// Edge function coefficients for 3 edges.
    edges: [EdgeCoeffs; 3],

    /// True if triangle has CCW winding (positive area).
    ccw: bool,

    /// Bounding box (tile-aligned for RTL matching).
    bbox_min_x: u16,
    bbox_min_y: u16,
    bbox_max_x: u16,
    bbox_max_y: u16,

    /// Per-attribute dx derivatives (32-bit signed, matching RTL `signed [31:0]`).
    dx: [i32; NUM_ATTRS],

    /// Per-attribute dy derivatives (32-bit signed).
    dy: [i32; NUM_ATTRS],

    /// Initial attribute values at bbox origin (32-bit signed).
    inits: [i32; NUM_ATTRS],

    /// Whether Gouraud interpolation is enabled.
    gouraud_en: bool,
}

/// Perform triangle setup: compute edge coefficients, derivatives, and
/// initial values.
///
/// Returns `None` for degenerate triangles (zero area).
///
/// Matches the RTL's rasterizer.sv S_SETUP + raster_recip_area +
/// raster_deriv pipeline.
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
    let inv_area = recip.mantissa;
    let area_shift = recip.area_shift;

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

    let bbox_sx = tri_min_x as i32 - x0;
    let bbox_sy = tri_min_y as i32 - y0;

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

    Some(TriangleSetup {
        edges,
        ccw,
        bbox_min_x: tri_min_x,
        bbox_min_y: tri_min_y,
        bbox_max_x: tri_max_x,
        bbox_max_y: tri_max_y,
        dx: dx_derivs,
        dy: dy_derivs,
        inits,
        gouraud_en: tri.gouraud_en,
    })
}

// ── Per-fragment iteration ─────────────────────────────────────────────────

/// Rasterize a triangle from precomputed setup data, returning fragments
/// as a collected `Vec`.
///
/// Convenience wrapper around [`rasterize_iter`]; prefer the iterator
/// form when fragments are consumed one-at-a-time.
pub fn rasterize_triangle(setup: &TriangleSetup) -> Vec<RasterFragment> {
    rasterize_iter(*setup).collect()
}

/// Return an iterator that yields [`RasterFragment`]s for a triangle.
///
/// Walks the bounding box in 4×4 tiles with hierarchical rejection,
/// per-pixel edge testing, incremental attribute accumulation, and
/// perspective correction — matching `raster_edge_walk.sv` +
/// `raster_attr_accum.sv`.
pub fn rasterize_iter(setup: TriangleSetup) -> TriangleIter {
    TriangleIter::new(setup)
}

/// Return a debug-aware iterator that captures accumulator state for a
/// specific pixel coordinate.
///
/// When `debug_pixel` is `Some((x, y))`, the iterator captures raw
/// accumulator state and perspective correction intermediates for
/// fragments at that coordinate.  The caller retrieves this via
/// [`TriangleIter::take_debug`] after each [`Iterator::next`] call.
pub fn rasterize_iter_debug(setup: TriangleSetup, debug_pixel: Option<(u16, u16)>) -> TriangleIter {
    let mut iter = TriangleIter::new(setup);
    iter.debug_pixel = debug_pixel;
    iter
}

/// Streaming iterator over rasterized fragments of a single triangle.
///
/// Created by [`rasterize_iter`].  Each call to [`Iterator::next`]
/// advances the hierarchical 4×4 tile walker to the next inside-triangle
/// pixel and returns its fully-formed [`RasterFragment`].
pub struct TriangleIter {
    // ── Copied setup fields ──────────────────────────────────────
    edges: [EdgeCoeffs; 3],
    ccw: bool,
    max_x: u16,
    max_y: u16,
    dx: [i32; NUM_ATTRS],
    dy: [i32; NUM_ATTRS],
    min_x: u16,

    // ── Precomputed tile-step constants ──────────────────────────
    a4: [i32; 3],
    b4: [i32; 3],
    a3: [i32; 3],
    b3: [i32; 3],

    // ── 4-level accumulator hierarchy ────────────────────────────
    e_trow: [i32; 3],
    attr_trow: [i32; NUM_ATTRS],
    e_tcol: [i32; 3],
    attr_tcol: [i32; NUM_ATTRS],
    e_row: [i32; 3],
    attr_row: [i32; NUM_ATTRS],
    e_acc: [i32; 3],
    attr_acc: [i32; NUM_ATTRS],

    // ── Loop positions ───────────────────────────────────────────
    tile_y: u16,
    tile_x: u16,
    py_offset: u16,
    px_offset: u16,

    done: bool,

    // ── Debug pixel support ─────────────────────────────────────
    /// When set, capture accumulator debug state for fragments at this pixel.
    debug_pixel: Option<(u16, u16)>,

    /// Last captured debug state (taken by caller after each `next()`).
    last_debug: Option<RasterAccumulatorDebug>,
}

impl TriangleIter {
    fn new(setup: TriangleSetup) -> Self {
        let min_x = setup.bbox_min_x;
        let min_y = setup.bbox_min_y;
        let max_x = setup.bbox_max_x;
        let max_y = setup.bbox_max_y;

        if min_x > max_x || min_y > max_y {
            return Self::empty(&setup);
        }

        // Initialize edge values at (min_x, min_y)
        let init_edge =
            |e: &EdgeCoeffs| -> i32 { e.a * (min_x as i32) + e.b * (min_y as i32) + e.c };

        let e_trow = [
            init_edge(&setup.edges[0]),
            init_edge(&setup.edges[1]),
            init_edge(&setup.edges[2]),
        ];

        let a4 = [
            setup.edges[0].a * 4,
            setup.edges[1].a * 4,
            setup.edges[2].a * 4,
        ];
        let b4 = [
            setup.edges[0].b * 4,
            setup.edges[1].b * 4,
            setup.edges[2].b * 4,
        ];
        let a3 = [
            setup.edges[0].a * 3,
            setup.edges[1].a * 3,
            setup.edges[2].a * 3,
        ];
        let b3 = [
            setup.edges[0].b * 3,
            setup.edges[1].b * 3,
            setup.edges[2].b * 3,
        ];

        let mut iter = Self {
            edges: setup.edges,
            ccw: setup.ccw,
            max_x,
            max_y,
            dx: setup.dx,
            dy: setup.dy,
            min_x,
            a4,
            b4,
            a3,
            b3,
            e_trow,
            attr_trow: setup.inits,
            e_tcol: e_trow,
            attr_tcol: setup.inits,
            e_row: e_trow,
            attr_row: setup.inits,
            e_acc: e_trow,
            attr_acc: setup.inits,
            tile_y: min_y,
            tile_x: min_x,
            py_offset: 0,
            px_offset: 0,
            done: false,
            debug_pixel: None,
            last_debug: None,
        };

        // Advance past the first tile if it is rejected.
        if tile_reject(&iter.e_tcol, &a3, &b3, setup.ccw) {
            iter.advance_to_next_tile();
        }

        iter
    }

    /// Create an immediately-exhausted iterator (degenerate bbox).
    fn empty(setup: &TriangleSetup) -> Self {
        Self {
            edges: setup.edges,
            ccw: setup.ccw,
            max_x: 0,
            max_y: 0,
            dx: setup.dx,
            dy: setup.dy,
            min_x: 0,
            a4: [0; 3],
            b4: [0; 3],
            a3: [0; 3],
            b3: [0; 3],
            e_trow: [0; 3],
            attr_trow: [0; NUM_ATTRS],
            e_tcol: [0; 3],
            attr_tcol: [0; NUM_ATTRS],
            e_row: [0; 3],
            attr_row: [0; NUM_ATTRS],
            e_acc: [0; 3],
            attr_acc: [0; NUM_ATTRS],
            tile_y: 0,
            tile_x: 0,
            py_offset: 0,
            px_offset: 0,
            done: true,
            debug_pixel: None,
            last_debug: None,
        }
    }

    /// Advance past the current tile to the next non-rejected tile,
    /// stepping tile-col and tile-row accumulators as needed.
    /// Sets `self.done` if the entire bbox is exhausted.
    ///
    /// On success, `e_row`/`attr_row`/`e_acc`/`attr_acc` and
    /// `py_offset`/`px_offset` are initialized for the new tile.
    fn advance_to_next_tile(&mut self) {
        // Step past current tile-col
        self.step_tile_col();

        loop {
            if self.scan_tile_row() {
                return;
            }
            self.advance_tile_row();
            if self.done {
                return;
            }
        }
    }

    /// Scan remaining tile-cols in the current tile-row for a
    /// non-rejected tile.  Returns `true` if one was found.
    fn scan_tile_row(&mut self) -> bool {
        while self.tile_x <= self.max_x {
            if !tile_reject(&self.e_tcol, &self.a3, &self.b3, self.ccw) {
                self.init_tile_pixels();
                return true;
            }
            self.step_tile_col();
        }
        false
    }

    /// Step tile-col accumulators to the next 4×4 column.
    fn step_tile_col(&mut self) {
        step_edges(&mut self.e_tcol, &self.a4);
        step_attrs(&mut self.attr_tcol, &self.dx, 4);
        self.tile_x = self.tile_x.saturating_add(TILE_SIZE);
    }

    /// Advance to the next tile-row, resetting tile-col to `min_x`.
    /// Sets `self.done` if beyond `max_y`.
    fn advance_tile_row(&mut self) {
        step_edges(&mut self.e_trow, &self.b4);
        step_attrs(&mut self.attr_trow, &self.dy, 4);
        self.tile_y = self.tile_y.saturating_add(TILE_SIZE);

        if self.tile_y > self.max_y {
            self.done = true;
            return;
        }

        self.e_tcol = self.e_trow;
        self.attr_tcol = self.attr_trow;
        self.tile_x = self.min_x;
    }

    /// Initialize pixel-row and pixel-col accumulators from the current
    /// tile-col accumulators, resetting offsets to 0.
    fn init_tile_pixels(&mut self) {
        self.e_row = self.e_tcol;
        self.attr_row = self.attr_tcol;
        self.e_acc = self.e_tcol;
        self.attr_acc = self.attr_tcol;
        self.py_offset = 0;
        self.px_offset = 0;
    }

    /// Test the current pixel against the edge functions.
    fn pixel_inside(&self) -> bool {
        if self.ccw {
            self.e_acc[0] >= 0 && self.e_acc[1] >= 0 && self.e_acc[2] >= 0
        } else {
            self.e_acc[0] <= 0 && self.e_acc[1] <= 0 && self.e_acc[2] <= 0
        }
    }

    /// Step the pixel-col accumulators in X (unconditional per pixel).
    fn step_pixel_x(&mut self) {
        for (e, edge) in self.e_acc.iter_mut().zip(self.edges.iter()) {
            *e = e.wrapping_add(edge.a);
        }
        for (a, d) in self.attr_acc.iter_mut().zip(self.dx.iter()) {
            *a = a.wrapping_add(*d);
        }
    }

    /// Step to the next pixel-row within the current tile.
    ///
    /// Returns `true` if a valid row was entered, `false` if the tile
    /// is exhausted.
    fn advance_pixel_row(&mut self) -> bool {
        self.py_offset += 1;
        if self.py_offset >= TILE_SIZE || (self.tile_y + self.py_offset) > self.max_y {
            return false;
        }
        for (e, edge) in self.e_row.iter_mut().zip(self.edges.iter()) {
            *e = e.wrapping_add(edge.b);
        }
        for (a, d) in self.attr_row.iter_mut().zip(self.dy.iter()) {
            *a = a.wrapping_add(*d);
        }
        self.e_acc = self.e_row;
        self.attr_acc = self.attr_row;
        self.px_offset = 0;
        true
    }
}

impl Iterator for TriangleIter {
    type Item = RasterFragment;

    fn next(&mut self) -> Option<RasterFragment> {
        loop {
            if self.done {
                return None;
            }
            if let Some(frag) = self.scan_pixels() {
                return Some(frag);
            }
            if !self.advance_pixel_row() {
                self.advance_to_next_tile();
            }
        }
    }
}

impl TriangleIter {
    /// Scan remaining pixels in the current pixel-row, returning the
    /// first inside-triangle fragment (if any).  Advances `px_offset`
    /// and steps X accumulators for every pixel visited.
    fn scan_pixels(&mut self) -> Option<RasterFragment> {
        while self.px_offset < TILE_SIZE {
            let px = self.tile_x + self.px_offset;
            self.px_offset += 1;

            if px > self.max_x {
                break;
            }

            let inside = self.pixel_inside();
            let py = self.tile_y + self.py_offset;
            let result = inside.then(|| self.emit_or_debug(px, py));

            self.step_pixel_x();

            if let Some(frag) = result {
                return Some(frag);
            }
        }
        None
    }

    /// Emit a fragment, capturing debug state if this pixel is the debug target.
    fn emit_or_debug(&mut self, px: u16, py: u16) -> RasterFragment {
        let is_debug = self
            .debug_pixel
            .is_some_and(|(dx, dy)| px == dx && py == dy);
        if is_debug {
            let (f, dbg) = emit_fragment_debug(px, py, &self.attr_acc);
            self.last_debug = Some(dbg);
            f
        } else {
            emit_fragment(px, py, &self.attr_acc)
        }
    }

    /// Take the last captured debug accumulator state, if any.
    ///
    /// Returns `Some` only when the most recently yielded fragment was
    /// at the debug pixel coordinate.  The value is consumed (set to
    /// `None`) by this call.
    pub fn take_debug(&mut self) -> Option<RasterAccumulatorDebug> {
        self.last_debug.take()
    }
}

// ── Helper functions ───────────────────────────────────────────────────────

/// DSP multiply matching raster_dsp_mul.sv: signed 17-bit × unsigned 18-bit.
///
/// Computes `|a| * b`, restores sign. Result is 36-bit signed (as i64).
fn dsp_mul(a: i32, b: u32) -> i64 {
    // Sign-extend a to 18-bit signed, take absolute value
    let a_ext = ((a as i64) << 46) >> 46; // sign-extend to effective 18-bit
    let a_mag = a_ext.unsigned_abs();

    // 18 × 18 unsigned multiply
    let prod = a_mag * (b as u64);

    // Restore sign
    if a < 0 {
        -(prod as i64)
    } else {
        prod as i64
    }
}

/// Shift-add multiply matching raster_shift_mul_32x11.sv.
///
/// 32-bit signed × 11-bit signed → 32-bit signed (truncated).
fn shift_mul_32x11(a: i32, b: i32) -> i32 {
    // In the DT we can just multiply and truncate to 32-bit
    let result = (a as i64) * (b as i64);
    result as i32
}

/// Increment 3 edge accumulators by the given deltas.
fn step_edges(edges: &mut [i32; 3], deltas: &[i32; 3]) {
    for (e, d) in edges.iter_mut().zip(deltas.iter()) {
        *e = e.wrapping_add(*d);
    }
}

/// Increment attribute accumulators by `derivs * scale` (wrapping).
fn step_attrs(attrs: &mut [i32; NUM_ATTRS], derivs: &[i32; NUM_ATTRS], scale: i32) {
    for (a, d) in attrs.iter_mut().zip(derivs.iter()) {
        *a = a.wrapping_add(d.wrapping_mul(scale));
    }
}

/// Test whether a 4×4 tile can be rejected by hierarchical edge testing.
///
/// Tests all 4 corners of the tile. If all corners fail any single edge,
/// the entire tile is outside.
fn tile_reject(e_tl: &[i32; 3], a3: &[i32; 3], b3: &[i32; 3], ccw: bool) -> bool {
    for k in 0..3 {
        let tl = e_tl[k];
        let tr = tl.wrapping_add(a3[k]);
        let bl = tl.wrapping_add(b3[k]);
        let br = tl.wrapping_add(a3[k]).wrapping_add(b3[k]);

        if ccw {
            // All 4 corners negative → entire tile outside for this edge
            if tl < 0 && tr < 0 && bl < 0 && br < 0 {
                return true;
            }
        } else {
            // All 4 corners positive → entire tile outside for CW winding
            if tl > 0 && tr > 0 && bl > 0 && br > 0 {
                return true;
            }
        }
    }
    false
}

/// Promote an 8.16 color accumulator to Q4.12.
///
/// Matches raster_attr_accum.sv color promotion:
///   - Negative → 0x0000
///   - Overflow (`acc[31:24] != 0`) → 0x0FFF
///   - Normal: `{4'b0, acc[23:16], acc[23:20]}`
fn promote_color_q412(acc: i32) -> qfixed::Q<4, 12> {
    if acc < 0 {
        return qfixed::Q::from_bits(0);
    }
    // Check overflow: any bits set above byte position [23:16]
    if (acc >> 24) != 0 {
        return qfixed::Q::from_bits(0x0FFF);
    }
    let byte = ((acc >> 16) & 0xFF) as i64;
    // {4'b0, byte, byte[7:4]}
    let q412 = (byte << 4) | (byte >> 4);
    qfixed::Q::from_bits(q412)
}

/// Extract 16-bit unsigned Z from 16.16 accumulator.
///
/// Z is an unsigned 16-bit value stored in a signed 32-bit accumulator
/// (signed to support derivative addition). Extraction treats the top
/// 16 bits as unsigned — no sign clamp.
///
/// Note: the RTL (`raster_attr_accum.sv`) currently clamps negative
/// accumulators to 0 (`acc[31] ? 0 : acc[31:16]`), which breaks Z
/// values >= 0x8000 because `$signed({z0, 16'b0})` wraps negative.
/// The DT uses unsigned extraction as the correct intended behavior.
fn extract_z(acc: i32) -> u16 {
    ((acc as u32) >> 16) as u16
}

/// Apply perspective correction to a texture coordinate accumulator.
///
/// Matches raster_edge_walk.sv:
///   `mul = $signed(s_acc[31:16]) * $signed({1'b0, persp_recip})`
///   `result = mul[29:14]` → Q4.12
///
/// `s_acc`: 32-bit signed attribute accumulator (top 16 bits = Q4.12)
/// `inv_q`: UQ4.14 (18-bit unsigned from recip_q)
fn persp_correct(s_acc: i32, inv_q: u32) -> qfixed::Q<4, 12> {
    // Extract top 16 bits as signed Q4.12
    let s_top = (s_acc >> 16) as i16 as i32;

    // Signed multiply: signed(16) × signed({1'b0, 18-bit}) = signed 35-bit
    let inv_q_signed = inv_q as i32; // {1'b0, UQ4.14} — always positive
    let product = (s_top as i64) * (inv_q_signed as i64); // Q9.26 (35-bit)

    // Extract bits [29:14] → Q4.12 (16-bit signed)
    let result = ((product >> 14) & 0xFFFF) as i16;
    qfixed::Q::from_bits(result as i64)
}

/// Emit a fragment from the current accumulator state.
///
/// Performs color promotion, Z extraction, perspective correction,
/// and LOD computation.
fn emit_fragment(px: u16, py: u16, acc: &[i32; NUM_ATTRS]) -> RasterFragment {
    let z = extract_z(acc[ATTR_Z]);

    // Perspective correction: compute 1/Q from Q accumulator
    let q_top = (acc[ATTR_Q] >> 16) as u16;
    let rq = recip::recip_q(q_top as u32);

    RasterFragment {
        x: px,
        y: py,
        z,
        shade0: ColorQ412 {
            r: promote_color_q412(acc[ATTR_C0R]),
            g: promote_color_q412(acc[ATTR_C0G]),
            b: promote_color_q412(acc[ATTR_C0B]),
            a: promote_color_q412(acc[ATTR_C0A]),
        },
        shade1: ColorQ412 {
            r: promote_color_q412(acc[ATTR_C1R]),
            g: promote_color_q412(acc[ATTR_C1G]),
            b: promote_color_q412(acc[ATTR_C1B]),
            a: promote_color_q412(acc[ATTR_C1A]),
        },
        u0: persp_correct(acc[ATTR_S0], rq.recip),
        v0: persp_correct(acc[ATTR_T0], rq.recip),
        u1: persp_correct(acc[ATTR_S1], rq.recip),
        v1: persp_correct(acc[ATTR_T1], rq.recip),
        lod: rq.lod,
    }
}

/// Perspective correction returning both the result and the raw product.
fn persp_correct_debug(s_acc: i32, inv_q: u32) -> (qfixed::Q<4, 12>, i16, i64) {
    let s_top = (s_acc >> 16) as i16 as i32;
    let inv_q_signed = inv_q as i32;
    let product = (s_top as i64) * (inv_q_signed as i64);
    let result = ((product >> 14) & 0xFFFF) as i16;
    (qfixed::Q::from_bits(result as i64), s_top as i16, product)
}

/// Emit a fragment with debug accumulator capture.
///
/// Same computation as [`emit_fragment`] but also captures raw
/// accumulator state and perspective correction intermediates.
fn emit_fragment_debug(
    px: u16,
    py: u16,
    acc: &[i32; NUM_ATTRS],
) -> (RasterFragment, RasterAccumulatorDebug) {
    let z = extract_z(acc[ATTR_Z]);

    let q_top = (acc[ATTR_Q] >> 16) as u16;
    let rq = recip::recip_q(q_top as u32);

    let (u0, s0_top, s0_product) = persp_correct_debug(acc[ATTR_S0], rq.recip);
    let (v0, t0_top, t0_product) = persp_correct_debug(acc[ATTR_T0], rq.recip);
    let (u1, s1_top, s1_product) = persp_correct_debug(acc[ATTR_S1], rq.recip);
    let (v1, t1_top, t1_product) = persp_correct_debug(acc[ATTR_T1], rq.recip);

    let frag = RasterFragment {
        x: px,
        y: py,
        z,
        shade0: ColorQ412 {
            r: promote_color_q412(acc[ATTR_C0R]),
            g: promote_color_q412(acc[ATTR_C0G]),
            b: promote_color_q412(acc[ATTR_C0B]),
            a: promote_color_q412(acc[ATTR_C0A]),
        },
        shade1: ColorQ412 {
            r: promote_color_q412(acc[ATTR_C1R]),
            g: promote_color_q412(acc[ATTR_C1G]),
            b: promote_color_q412(acc[ATTR_C1B]),
            a: promote_color_q412(acc[ATTR_C1A]),
        },
        u0,
        v0,
        u1,
        v1,
        lod: rq.lod,
    };

    let mut acc_copy = [0i32; 14];
    acc_copy.copy_from_slice(acc);

    let dbg = RasterAccumulatorDebug {
        acc: acc_copy,
        q_top,
        inv_q: rq.recip,
        s0_top,
        t0_top,
        s1_top,
        t1_top,
        s0_product,
        t0_product,
        s1_product,
        t1_product,
    };

    (frag, dbg)
}
