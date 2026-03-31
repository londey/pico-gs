//! Attribute accumulator matching `raster_attr_accum.sv` (UNIT-005.03).
//!
//! Maintains the 4-level accumulator hierarchy (tile-row, tile-col,
//! pixel-row, pixel) and provides step commands and output promotion.

// Spec-ref: unit_005.03_derivative_precomputation.md `0000000000000000` 1970-01-01

use crate::deriv::NUM_ATTRS;

/// Attribute accumulator state matching the RTL's register file.
///
/// Exposes the 4-level hierarchy for testbench verification:
/// tile-row → tile-col → pixel-row → pixel accumulators.
#[derive(Clone, Debug)]
pub struct AttrAccum {
    /// Tile-row base accumulators (reset at start of each tile row).
    pub attr_trow: [i32; NUM_ATTRS],

    /// Tile-column accumulators (stepped by 4×dx per tile).
    pub attr_tcol: [i32; NUM_ATTRS],

    /// Pixel-row accumulators (stepped by dy per row within tile).
    pub attr_row: [i32; NUM_ATTRS],

    /// Current pixel accumulators (stepped by dx per pixel).
    pub attr_acc: [i32; NUM_ATTRS],

    /// Stored dx derivatives (latched on init).
    dx: [i32; NUM_ATTRS],

    /// Stored dy derivatives (latched on init).
    dy: [i32; NUM_ATTRS],
}

impl AttrAccum {
    /// Initialize accumulators from derivative results (matches `latch_derivs`).
    ///
    /// All four hierarchy levels start at the initial values.
    ///
    /// # Arguments
    ///
    /// * `inits` - Initial attribute values at bbox origin.
    /// * `dx` - Per-attribute X derivatives.
    /// * `dy` - Per-attribute Y derivatives.
    pub fn new(inits: [i32; NUM_ATTRS], dx: [i32; NUM_ATTRS], dy: [i32; NUM_ATTRS]) -> Self {
        Self {
            attr_trow: inits,
            attr_tcol: inits,
            attr_row: inits,
            attr_acc: inits,
            dx,
            dy,
        }
    }

    /// Step pixel X: add dx to pixel accumulators (matches `step_x`).
    pub fn step_x(&mut self) {
        for (a, d) in self.attr_acc.iter_mut().zip(self.dx.iter()) {
            *a = a.wrapping_add(*d);
        }
    }

    /// Step pixel Y: add dy to row registers and reload pixel accumulators
    /// (matches `step_y`).
    pub fn step_y(&mut self) {
        for (a, d) in self.attr_row.iter_mut().zip(self.dy.iter()) {
            *a = a.wrapping_add(*d);
        }
        self.attr_acc = self.attr_row;
    }

    /// Step tile column: advance tcol by 4×dx (matches `tile_col_step`).
    pub fn step_tile_col(&mut self) {
        step_attrs(&mut self.attr_tcol, &self.dx, 4);
    }

    /// Step tile row: advance trow by 4×dy (matches `tile_row_step`).
    pub fn step_tile_row(&mut self) {
        step_attrs(&mut self.attr_trow, &self.dy, 4);
    }

    /// Reset tile-col from tile-row values.
    /// Called at the start of each new tile row.
    pub fn reset_tile_col(&mut self) {
        self.attr_tcol = self.attr_trow;
    }

    /// Initialize pixel-row and pixel accumulators from tile-col values.
    /// Called at the start of each tile.
    pub fn init_tile_pixels(&mut self) {
        self.attr_row = self.attr_tcol;
        self.attr_acc = self.attr_tcol;
    }

    /// Read current pixel accumulator (for fragment emission).
    pub fn acc(&self) -> &[i32; NUM_ATTRS] {
        &self.attr_acc
    }
}

/// Increment attribute accumulators by `derivs * scale` (wrapping).
fn step_attrs(attrs: &mut [i32; NUM_ATTRS], derivs: &[i32; NUM_ATTRS], scale: i32) {
    for (a, d) in attrs.iter_mut().zip(derivs.iter()) {
        *a = a.wrapping_add(d.wrapping_mul(scale));
    }
}

/// Promote an 8.16 color accumulator to Q4.12.
///
/// Matches `raster_attr_accum.sv` color promotion:
///   - Negative → 0x0000
///   - Overflow (`acc[31:24] != 0`) → 0x0FFF
///   - Normal: `{4'b0, acc[23:16], acc[23:20]}`
pub fn promote_color_q412(acc: i32) -> qfixed::Q<4, 12> {
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
/// (signed to support derivative addition).
/// Extraction treats the top 16 bits as unsigned — no sign clamp.
///
/// Note: the RTL (`raster_attr_accum.sv`) currently clamps negative
/// accumulators to 0 (`acc[31] ? 0 : acc[31:16]`), which breaks Z
/// values >= 0x8000 because `$signed({z0, 16'b0})` wraps negative.
/// The DT uses unsigned extraction as the correct intended behavior.
pub fn extract_z(acc: i32) -> u16 {
    ((acc as u32) >> 16) as u16
}
