//! Tile-ordered edge walk and fragment emission matching
//! `raster_edge_walk.sv` (UNIT-005.04).
//!
//! Provides the [`TriangleIter`] iterator that walks 4×4 tiles over the
//! bounding box with hierarchical edge rejection, Hi-Z tile rejection,
//! per-pixel edge testing, and perspective correction.

// Spec-ref: unit_005.05_iteration_fsm.md `0000000000000000` 1970-01-01
// Spec-ref: unit_005.06_hiz_block_metadata.md `0000000000000000` 1970-01-01

use crate::attr_accum::{self, AttrAccum};
use crate::deriv::{
    ATTR_C0A, ATTR_C0B, ATTR_C0G, ATTR_C0R, ATTR_C1A, ATTR_C1B, ATTR_C1G, ATTR_C1R, ATTR_Q,
    ATTR_S0, ATTR_S1, ATTR_T0, ATTR_T1, ATTR_Z, NUM_ATTRS,
};
use crate::recip;
use crate::setup::{EdgeCoeffs, TriangleSetup};
use gs_twin_core::debug_types::RasterAccumulatorDebug;
use gs_twin_core::fragment::{ColorQ412, RasterFragment};
pub use gs_twin_core::hiz::HizMetadata;

/// Tile size for hierarchical edge walk (matching RTL's 4×4 tiles).
const TILE_SIZE: u16 = 4;

// ── Public convenience functions ──────────────────────────────────────────

/// Rasterize a triangle from precomputed setup data, returning fragments
/// as a collected `Vec`.
///
/// Convenience wrapper around [`rasterize_iter`]; prefer the iterator
/// form when fragments are consumed one-at-a-time.
///
/// Hi-Z rejection is disabled (no metadata store, `z_test_en=false`).
pub fn rasterize_triangle(setup: &TriangleSetup) -> Vec<RasterFragment> {
    rasterize_iter(*setup).collect()
}

/// Rasterize a triangle with Hi-Z tile rejection, returning fragments
/// as a collected `Vec`.
///
/// Convenience wrapper around [`rasterize_iter_hiz`].
pub fn rasterize_triangle_hiz(
    setup: &TriangleSetup,
    hiz: &HizMetadata,
    z_test_en: bool,
    width_log2: u32,
) -> Vec<RasterFragment> {
    rasterize_iter_hiz(*setup, hiz, z_test_en, width_log2).collect()
}

/// Return an iterator that yields [`RasterFragment`]s for a triangle.
///
/// Walks the bounding box in 4×4 tiles with hierarchical rejection,
/// per-pixel edge testing, incremental attribute accumulation, and
/// perspective correction — matching `raster_edge_walk.sv` +
/// `raster_attr_accum.sv`.
///
/// Hi-Z rejection is disabled.
/// Use [`rasterize_iter_hiz`] to enable it.
pub fn rasterize_iter(setup: TriangleSetup) -> TriangleIter<'static> {
    TriangleIter::new(setup, None, false, 0)
}

/// Return an iterator with Hi-Z tile rejection enabled.
///
/// # Arguments
///
/// * `setup` - Precomputed triangle setup data.
/// * `hiz` - Reference to the Hi-Z metadata store.
/// * `z_test_en` - When `true`, tiles are checked against Hi-Z metadata
///   before pixel-level edge testing (UNIT-005.05 HIZ_TEST).
/// * `width_log2` - Log2 of the framebuffer width (e.g. 9 for 512 pixels),
///   used to compute `tile_cols_log2 = width_log2 - 2`.
pub fn rasterize_iter_hiz<'h>(
    setup: TriangleSetup,
    hiz: &'h HizMetadata,
    z_test_en: bool,
    width_log2: u32,
) -> TriangleIter<'h> {
    TriangleIter::new(setup, Some(hiz), z_test_en, width_log2)
}

/// Return a debug-aware iterator that captures accumulator state for a
/// specific pixel coordinate.
///
/// When `debug_pixel` is `Some((x, y))`, the iterator captures raw
/// accumulator state and perspective correction intermediates for
/// fragments at that coordinate.
/// The caller retrieves this via [`TriangleIter::take_debug`] after
/// each [`Iterator::next`] call.
pub fn rasterize_iter_debug(
    setup: TriangleSetup,
    debug_pixel: Option<(u16, u16)>,
) -> TriangleIter<'static> {
    let mut iter = TriangleIter::new(setup, None, false, 0);
    iter.debug_pixel = debug_pixel;
    iter
}

/// Return a debug-aware iterator with Hi-Z tile rejection enabled.
///
/// Combines the features of [`rasterize_iter_hiz`] and
/// [`rasterize_iter_debug`].
pub fn rasterize_iter_hiz_debug<'h>(
    setup: TriangleSetup,
    hiz: &'h HizMetadata,
    z_test_en: bool,
    width_log2: u32,
    debug_pixel: Option<(u16, u16)>,
) -> TriangleIter<'h> {
    let mut iter = TriangleIter::new(setup, Some(hiz), z_test_en, width_log2);
    iter.debug_pixel = debug_pixel;
    iter
}

// ── TriangleIter ──────────────────────────────────────────────────────────

/// Streaming iterator over rasterized fragments of a single triangle.
///
/// Created by [`rasterize_iter`].
/// Each call to [`Iterator::next`] advances the hierarchical 4×4 tile
/// walker to the next inside-triangle pixel and returns its fully-formed
/// [`RasterFragment`].
///
/// The lifetime `'h` ties the iterator to a borrowed [`HizMetadata`] store
/// (when Hi-Z rejection is enabled).
/// When Hi-Z is disabled, `'h` is `'static` and has no runtime cost.
pub struct TriangleIter<'h> {
    // ── Copied setup fields ──────────────────────────────────────
    edges: [EdgeCoeffs; 3],
    ccw: bool,
    max_x: u16,
    max_y: u16,
    min_x: u16,
    min_y: u16,

    // ── Precomputed tile-step constants ──────────────────────────
    a4: [i32; 3],
    b4: [i32; 3],
    a3: [i32; 3],
    b3: [i32; 3],

    // ── Edge accumulator hierarchy (belongs to raster_edge_walk.sv) ──
    e_trow: [i32; 3],
    e_tcol: [i32; 3],
    e_row: [i32; 3],
    e_acc: [i32; 3],

    // ── Attribute accumulator (delegated to AttrAccum) ──────────
    accum: AttrAccum,

    // ── Loop positions ───────────────────────────────────────────
    tile_y: u16,
    tile_x: u16,
    py_offset: u16,
    px_offset: u16,

    done: bool,

    // ── Hi-Z metadata ────────────────────────────────────────────
    /// Reference to the Hi-Z metadata store (`None` when Hi-Z is disabled).
    hiz: Option<&'h HizMetadata>,

    /// Whether Z testing is enabled (RENDER_MODE.Z_TEST_EN).
    z_test_en: bool,

    /// Log2 of tile columns: `width_log2 - 2`.
    tile_cols_log2: u32,

    // ── Debug pixel support ─────────────────────────────────────
    /// When set, capture accumulator debug state for fragments at this pixel.
    debug_pixel: Option<(u16, u16)>,

    /// Last captured debug state (taken by caller after each `next()`).
    last_debug: Option<RasterAccumulatorDebug>,
}

impl<'h> TriangleIter<'h> {
    fn new(
        setup: TriangleSetup,
        hiz: Option<&'h HizMetadata>,
        z_test_en: bool,
        width_log2: u32,
    ) -> Self {
        let min_x = setup.bbox_min_x;
        let min_y = setup.bbox_min_y;
        let max_x = setup.bbox_max_x;
        let max_y = setup.bbox_max_y;
        let tile_cols_log2 = width_log2.saturating_sub(2);

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

        let accum = AttrAccum::new(setup.inits, setup.dx, setup.dy);

        let mut iter = Self {
            edges: setup.edges,
            ccw: setup.ccw,
            max_x,
            max_y,
            min_x,
            min_y,
            a4,
            b4,
            a3,
            b3,
            e_trow,
            e_tcol: e_trow,
            e_row: e_trow,
            e_acc: e_trow,
            accum,
            tile_y: min_y,
            tile_x: min_x,
            py_offset: 0,
            px_offset: 0,
            done: false,
            hiz,
            z_test_en,
            tile_cols_log2,
            debug_pixel: None,
            last_debug: None,
        };

        // Advance past the first tile if it is rejected (edge or Hi-Z).
        if tile_reject(&iter.e_tcol, &a3, &b3, setup.ccw) || iter.hiz_reject_current_tile() {
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
            min_x: 0,
            min_y: 0,
            a4: [0; 3],
            b4: [0; 3],
            a3: [0; 3],
            b3: [0; 3],
            e_trow: [0; 3],
            e_tcol: [0; 3],
            e_row: [0; 3],
            e_acc: [0; 3],
            accum: AttrAccum::new([0; NUM_ATTRS], setup.dx, setup.dy),
            tile_y: 0,
            tile_x: 0,
            py_offset: 0,
            px_offset: 0,
            done: true,
            hiz: None,
            z_test_en: false,
            tile_cols_log2: 0,
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
    /// non-rejected tile.
    /// Returns `true` if one was found.
    fn scan_tile_row(&mut self) -> bool {
        while self.tile_x <= self.max_x {
            if !tile_reject(&self.e_tcol, &self.a3, &self.b3, self.ccw)
                && !self.hiz_reject_current_tile()
            {
                self.init_tile_pixels();
                return true;
            }
            self.step_tile_col();
        }
        false
    }

    /// Perform Hi-Z tile rejection for the current tile.
    ///
    /// Returns `true` if the tile should be rejected (all fragments in this
    /// tile are guaranteed to fail the depth test).
    ///
    /// Matches the HIZ_TEST procedure in UNIT-005.05:
    /// - Bypass (return `false`) when `z_test_en=false` or no metadata store.
    /// - Return `false` when `min_z == 0x1FF` (sentinel — tile has no
    ///   Z-writes since last clear, cannot reject).
    /// - Reject when `frag_z_9bit > min_z_9bit` (GEQUAL / reverse-Z:
    ///   fragment further than every pixel in tile).
    fn hiz_reject_current_tile(&self) -> bool {
        if !self.z_test_en {
            return false;
        }
        let hiz = match self.hiz {
            Some(h) => h,
            None => return false,
        };

        // Compute 14-bit tile index using absolute screen coordinates,
        // matching the pixel writer's update path.
        let tile_row = self.tile_y / TILE_SIZE;
        let tile_col = self.tile_x / TILE_SIZE;
        let tile_index = ((tile_row as usize) << self.tile_cols_log2) | (tile_col as usize);

        let min_z_9bit = hiz.read(tile_index);

        // Sentinel 0x1FF means no Z-write since last clear — cannot reject.
        if min_z_9bit == HizMetadata::sentinel() {
            return false;
        }

        // Use tile-representative Z: the Z accumulator value at the tile origin.
        // Extract Z[15:7] from the attribute accumulator (9-bit, matching
        // the Hi-Z metadata store's resolution).
        let z_top16 = ((self.accum.attr_tcol[ATTR_Z] as u32) >> 16) as u16;
        let frag_z_9bit = z_top16 >> 7;

        // GEQUAL (reverse-Z): fragment passes when frag_z >= stored_z.
        // Conservative reject: frag_z < tile min_z guarantees failure
        // against every pixel in the tile.
        let rejected = frag_z_9bit < min_z_9bit;
        if rejected {
            hiz.record_rejection();
        }
        rejected
    }

    /// Step tile-col accumulators to the next 4×4 column.
    fn step_tile_col(&mut self) {
        step_edges(&mut self.e_tcol, &self.a4);
        self.accum.step_tile_col();
        self.tile_x = self.tile_x.saturating_add(TILE_SIZE);
    }

    /// Advance to the next tile-row, resetting tile-col to `min_x`.
    /// Sets `self.done` if beyond `max_y`.
    fn advance_tile_row(&mut self) {
        step_edges(&mut self.e_trow, &self.b4);
        self.accum.step_tile_row();
        self.tile_y = self.tile_y.saturating_add(TILE_SIZE);

        if self.tile_y > self.max_y {
            self.done = true;
            return;
        }

        self.e_tcol = self.e_trow;
        self.accum.reset_tile_col();
        self.tile_x = self.min_x;
    }

    /// Initialize pixel-row and pixel-col accumulators from the current
    /// tile-col accumulators, resetting offsets to 0.
    fn init_tile_pixels(&mut self) {
        self.e_row = self.e_tcol;
        self.e_acc = self.e_tcol;
        self.accum.init_tile_pixels();
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
        self.accum.step_x();
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
        self.accum.step_y();
        self.e_acc = self.e_row;
        self.px_offset = 0;
        true
    }
}

impl Iterator for TriangleIter<'_> {
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

impl TriangleIter<'_> {
    /// Scan remaining pixels in the current pixel-row, returning the
    /// first inside-triangle fragment (if any).
    /// Advances `px_offset` and steps X accumulators for every pixel visited.
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
            let (f, dbg) = emit_fragment_debug(px, py, self.accum.acc());
            self.last_debug = Some(dbg);
            f
        } else {
            emit_fragment(px, py, self.accum.acc())
        }
    }

    /// Take the last captured debug accumulator state, if any.
    ///
    /// Returns `Some` only when the most recently yielded fragment was
    /// at the debug pixel coordinate.
    /// The value is consumed (set to `None`) by this call.
    pub fn take_debug(&mut self) -> Option<RasterAccumulatorDebug> {
        self.last_debug.take()
    }
}

// ── Helper functions ───────────────────────────────────────────────────────

/// Increment 3 edge accumulators by the given deltas.
fn step_edges(edges: &mut [i32; 3], deltas: &[i32; 3]) {
    for (e, d) in edges.iter_mut().zip(deltas.iter()) {
        *e = e.wrapping_add(*d);
    }
}

/// Test whether a 4×4 tile can be rejected by hierarchical edge testing.
///
/// Tests all 4 corners of the tile.
/// If all corners fail any single edge, the entire tile is outside.
pub fn tile_reject(e_tl: &[i32; 3], a3: &[i32; 3], b3: &[i32; 3], ccw: bool) -> bool {
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

/// Apply perspective correction to a texture coordinate accumulator.
///
/// Matches `raster_edge_walk.sv`:
///   `mul = $signed(s_acc[31:16]) * $signed(persp_recip)`
///   `result = mul[25:10]` → Q4.12
///
/// `s_acc`: 32-bit signed attribute accumulator (top 16 bits = Q4.12).
/// `inv_q`: UQ7.10 (17-bit unsigned in 18-bit register from `recip_q`).
pub fn persp_correct(s_acc: i32, inv_q: u32) -> qfixed::Q<4, 12> {
    // Extract top 16 bits as signed Q4.12
    let s_top = (s_acc >> 16) as i16 as i32;

    // Signed multiply: signed(16) × signed(18) = signed 34-bit
    // persp_recip is UQ7.10 in 18-bit register (bit 17 always 0),
    // so $signed(persp_recip) is non-negative.
    let inv_q_signed = inv_q as i32;
    let product = (s_top as i64) * (inv_q_signed as i64); // Q12.22 (34-bit)

    // Extract bits [25:10] → Q4.12 (16-bit signed)
    let result = ((product >> 10) & 0xFFFF) as i16;
    qfixed::Q::from_bits(result as i64)
}

/// Emit a fragment from the current accumulator state.
///
/// Performs color promotion, Z extraction, perspective correction,
/// and LOD computation.
pub fn emit_fragment(px: u16, py: u16, acc: &[i32; NUM_ATTRS]) -> RasterFragment {
    let z = attr_accum::extract_z(acc[ATTR_Z]);

    // Perspective correction: compute 1/Q from Q accumulator
    let q_top = (acc[ATTR_Q] >> 16) as u16;
    let rq = recip::recip_q(q_top as u32);

    RasterFragment {
        x: px,
        y: py,
        z,
        shade0: ColorQ412 {
            r: attr_accum::promote_color_q412(acc[ATTR_C0R]),
            g: attr_accum::promote_color_q412(acc[ATTR_C0G]),
            b: attr_accum::promote_color_q412(acc[ATTR_C0B]),
            a: attr_accum::promote_color_q412(acc[ATTR_C0A]),
        },
        shade1: ColorQ412 {
            r: attr_accum::promote_color_q412(acc[ATTR_C1R]),
            g: attr_accum::promote_color_q412(acc[ATTR_C1G]),
            b: attr_accum::promote_color_q412(acc[ATTR_C1B]),
            a: attr_accum::promote_color_q412(acc[ATTR_C1A]),
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
    let result = ((product >> 10) & 0xFFFF) as i16;
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
    let z = attr_accum::extract_z(acc[ATTR_Z]);

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
            r: attr_accum::promote_color_q412(acc[ATTR_C0R]),
            g: attr_accum::promote_color_q412(acc[ATTR_C0G]),
            b: attr_accum::promote_color_q412(acc[ATTR_C0B]),
            a: attr_accum::promote_color_q412(acc[ATTR_C0A]),
        },
        shade1: ColorQ412 {
            r: attr_accum::promote_color_q412(acc[ATTR_C1R]),
            g: attr_accum::promote_color_q412(acc[ATTR_C1G]),
            b: attr_accum::promote_color_q412(acc[ATTR_C1B]),
            a: attr_accum::promote_color_q412(acc[ATTR_C1A]),
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
        recip_clz: rq.clz,
        recip_lut_index: rq.lut_index,
        recip_error_lsb: rq.error_lsb,
    };

    (frag, dbg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::setup::triangle_setup;
    use gs_twin_core::triangle::{RasterTriangle, RasterVertex, Rgba8888};

    /// Create a simple flat-shaded triangle that covers a single 4×4 tile
    /// at the origin.
    /// All vertices have the same Z value so the tile-representative Z
    /// equals that value.
    fn make_test_triangle(z: u16) -> RasterTriangle {
        // A large right triangle covering at least the first 4×4 tile (0,0)-(3,3).
        // Vertices at (0,0), (8,0), (0,8) — well inside a 512×512 surface.
        RasterTriangle {
            verts: [
                RasterVertex {
                    px: 0,
                    py: 0,
                    z,
                    q: 0x4000,
                    color0: Rgba8888(0xFF80_8040),
                    color1: Rgba8888(0),
                    s0: 0,
                    t0: 0,
                    s1: 0,
                    t1: 0,
                },
                RasterVertex {
                    px: 8,
                    py: 0,
                    z,
                    q: 0x4000,
                    color0: Rgba8888(0xFF80_8040),
                    color1: Rgba8888(0),
                    s0: 0,
                    t0: 0,
                    s1: 0,
                    t1: 0,
                },
                RasterVertex {
                    px: 0,
                    py: 8,
                    z,
                    q: 0x4000,
                    color0: Rgba8888(0xFF80_8040),
                    color1: Rgba8888(0),
                    s0: 0,
                    t0: 0,
                    s1: 0,
                    t1: 0,
                },
            ],
            bbox_min_x: 0,
            bbox_max_x: 7,
            bbox_min_y: 0,
            bbox_max_y: 7,
            gouraud_en: false,
        }
    }

    // ── HizMetadata unit tests ──────────────────────────────────────────────

    #[test]
    fn hiz_metadata_new_all_sentinel() {
        let hiz = HizMetadata::new();
        for i in 0..16384 {
            let min_z = hiz.read(i);
            assert_eq!(
                min_z,
                HizMetadata::sentinel(),
                "entry {i} should be sentinel after new()"
            );
        }
    }

    #[test]
    fn hiz_metadata_update_and_read() {
        let mut hiz = HizMetadata::new();

        // First write: sentinel → 0 (lazy-fill invariant: unwritten pixels
        // are Z=0x0000, so tile min must be 0).
        hiz.update(42, 0x4000);
        let min_z = hiz.read(42);
        assert_eq!(min_z, 0, "first write must store 0 for lazy-fill invariant");

        // Subsequent write with smaller Z cannot go below 0
        hiz.update(42, 0x2000);
        let min_z = hiz.read(42);
        assert_eq!(min_z, 0);

        // Larger value does not change min_z
        hiz.update(42, 0x6000);
        let min_z = hiz.read(42);
        assert_eq!(min_z, 0);
    }

    #[test]
    fn hiz_metadata_reset_all() {
        let mut hiz = HizMetadata::new();
        hiz.update(100, 0x5500);
        hiz.reset_all();
        let min_z = hiz.read(100);
        assert_eq!(
            min_z,
            HizMetadata::sentinel(),
            "entry should be sentinel after reset_all()"
        );
    }

    // ── Hi-Z tile rejection integration tests ───────────────────────────────

    #[test]
    fn hiz_reject_tile_with_low_z() {
        // Triangle Z=0x2000 → frag_z_9bit = 0x2000 >> 7 = 0x40.
        // Tile min_z_9bit = 0x80 > 0x40 → rejected (fragment further
        // than all pixels in tile under reverse-Z GEQUAL).
        let tri = make_test_triangle(0x2000);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let mut hiz = HizMetadata::new();
        hiz.force_entry(0, 0x80);

        let frags = rasterize_triangle_hiz(&setup, &hiz, true, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            tile0_frags.is_empty(),
            "expected zero fragments from rejected tile, got {}",
            tile0_frags.len()
        );
    }

    #[test]
    fn hiz_pass_tile_with_high_z() {
        // Triangle Z=0x8000 → frag_z_9bit = 0x8000 >> 7 = 0x100.
        // Tile min_z_9bit = 0x40 < 0x100 → not rejected (fragment
        // closer than tile minimum).
        let tri = make_test_triangle(0x8000);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let mut hiz = HizMetadata::new();
        hiz.force_entry(0, 0x40);

        let frags = rasterize_triangle_hiz(&setup, &hiz, true, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            !tile0_frags.is_empty(),
            "expected fragments from non-rejected tile"
        );
    }

    #[test]
    fn hiz_sentinel_never_rejects() {
        let tri = make_test_triangle(0x8000);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let hiz = HizMetadata::new(); // all entries = sentinel (0x1FF)

        let frags = rasterize_triangle_hiz(&setup, &hiz, true, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            !tile0_frags.is_empty(),
            "expected fragments from sentinel tile (no Z-writes)"
        );
    }

    #[test]
    fn hiz_bypass_when_z_test_disabled() {
        let tri = make_test_triangle(0x8000);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let mut hiz = HizMetadata::new();
        hiz.force_entry(0, 0x40);

        let frags = rasterize_triangle_hiz(&setup, &hiz, false, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            !tile0_frags.is_empty(),
            "expected fragments when z_test_en=false"
        );
    }

    #[test]
    fn hiz_sentinel_passthrough_any_z() {
        // Even a far-plane triangle (Z=0xFFFF → frag_z_9bit = 0x1FF)
        // should pass through a sentinel tile (0x1FF) — sentinel never
        // rejects, regardless of fragment Z.
        let tri = make_test_triangle(0xFFFF);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let hiz = HizMetadata::new(); // all entries = sentinel (0x1FF)

        let frags = rasterize_triangle_hiz(&setup, &hiz, true, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            !tile0_frags.is_empty(),
            "expected fragments from sentinel tile even with far-plane Z"
        );
    }

    #[test]
    fn hiz_equal_z_not_rejected() {
        // Triangle Z=0x4000 → frag_z_9bit = 0x4000 >> 7 = 0x80.
        // Tile min_z_9bit = 0x80 == frag_z_9bit → not rejected
        // (equal Z passes GEQUAL).
        let tri = make_test_triangle(0x4000);
        let setup = triangle_setup(&tri).expect("non-degenerate");

        let mut hiz = HizMetadata::new();
        hiz.force_entry(0, 0x80);

        let frags = rasterize_triangle_hiz(&setup, &hiz, true, 9);
        let tile0_frags: Vec<_> = frags.iter().filter(|f| f.x < 4 && f.y < 4).collect();
        assert!(
            !tile0_frags.is_empty(),
            "expected fragments when fragment_Z[15:8] == stored_min_z"
        );
    }
}
