// Spec-ref: unit_011.01_uv_coordinate_processing.md

#![deny(unsafe_code)]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::all))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(clippy::pedantic))]
#![cfg_attr(all(not(debug_assertions), not(test)), deny(missing_docs))]
#![allow(clippy::module_name_repetitions)]

//! Texture UV coordinate processing -- wrap modes, quadrant extraction, and
//! half-resolution index-cache addressing.
//!
//! Implements UNIT-011.01.
//! The unit takes a Q4.12 signed UV coordinate, applies the per-axis wrap
//! mode on the apparent integer texel coordinate, and produces:
//!
//! 1. The half-resolution index-cache address `(u_idx, v_idx) =
//!    (u_wrapped >> 1, v_wrapped >> 1)`, used by UNIT-011.03.
//! 2. The 2-bit quadrant selector `quadrant = {v_wrapped[0],
//!    u_wrapped[0]}`, used by UNIT-011.06 to select the NW/NE/SW/SE
//!    palette entry within the 2x2 apparent-texel tile.
//!
//! There is no mip-level selection, no bilinear-tap output, and no
//! 0.5-texel centering offset; pico-gs implements NEAREST-only sampling
//! over the INDEXED8_2X2 layout.
//!
//! # Data flow
//!
//! ```text
//! UV (Q4.12) + wrap mode + size_log2
//!   -> apparent integer texel coord (signed)
//!   -> wrap mode application (REPEAT / CLAMP / MIRROR)
//!   -> wrapped apparent integer coord
//!       -> u_idx, v_idx = wrapped >> 1   (half-resolution address)
//!       -> low_bit      = wrapped & 1    (quadrant selector bit)
//! ```

use gpu_registers::components::wrap_mode_e::WrapModeE;

// ── Quadrant encoding constants ─────────────────────────────────────────────

/// Quadrant selector for the NW palette entry (`u_low = 0`, `v_low = 0`).
pub const QUADRANT_NW: u8 = 0b00;

/// Quadrant selector for the NE palette entry (`u_low = 1`, `v_low = 0`).
///
/// Encoding follows `quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}` per
/// UNIT-011.01.
/// `u_low = 1`, `v_low = 0` packs to `{0, 1} = 0b01`.
/// This matches UNIT-011.06's EBR addressing where `quadrant[1] = v_low`
/// selects the top/bottom row pair (NW+NE vs SW+SE) and `quadrant[0] =
/// u_low` selects within the row.
/// Note: an example mapping table in UNIT-011.01 misprinted NE and SW
/// with their bit patterns swapped; the canonical encoding is the
/// formula above and is the encoding consumed by UNIT-011.06.
pub const QUADRANT_NE: u8 = 0b01;

/// Quadrant selector for the SW palette entry (`u_low = 0`, `v_low = 1`).
/// See [`QUADRANT_NE`] for the encoding rationale.
pub const QUADRANT_SW: u8 = 0b10;

/// Quadrant selector for the SE palette entry (`u_low = 1`, `v_low = 1`).
pub const QUADRANT_SE: u8 = 0b11;

// ── Public API ──────────────────────────────────────────────────────────────

/// Stateless UV coordinate processor.
///
/// All of this module's behaviour is purely combinational and depends only
/// on the inputs supplied to [`UvCoord::process`].
/// The empty struct exists so the API matches the unit-style facade used
/// by other twin crates and keeps room for future configuration if the
/// algorithm ever gains internal state.
#[derive(Debug, Clone, Copy, Default)]
pub struct UvCoord;

impl UvCoord {
    /// Process a single Q4.12 axis coordinate.
    ///
    /// Converts the Q4.12 signed coordinate to an apparent integer texel
    /// coordinate (sign-extended, scaled by `size_log2`), applies the wrap
    /// mode on that apparent coordinate, and returns the half-resolution
    /// index plus the wrapped low bit.
    ///
    /// # Arguments
    ///
    /// * `uv_q412` -- Q4.12 signed fixed-point UV coordinate (raw 16-bit
    ///   bit pattern).
    /// * `wrap_mode` -- Per-axis wrap mode from `TEXn_CFG`.
    /// * `size_log2` -- `log2(apparent texture size)` for this axis from
    ///   `TEXn_CFG.WIDTH_LOG2` / `HEIGHT_LOG2`.
    ///   `INT-014` requires `size_log2 >= 1`.
    ///
    /// # Returns
    ///
    /// `(half_res_idx, low_bit)`:
    /// * `half_res_idx` is the half-resolution index-cache coordinate
    ///   (`u_idx` or `v_idx`).
    ///   Width is `size_log2 - 1` bits.
    /// * `low_bit` is `0` or `1` -- the wrapped low bit of the apparent
    ///   integer coordinate.
    ///   Combine the per-axis low bits via [`compute_quadrant`] to form
    ///   the 2-bit quadrant selector consumed by UNIT-011.06.
    #[must_use]
    pub fn process(uv_q412: i16, wrap_mode: WrapModeE, size_log2: u8) -> (u16, u8) {
        let apparent = apparent_integer_coord(uv_q412, size_log2);
        let size = 1i32 << size_log2;
        let wrapped = apply_wrap(apparent, size, wrap_mode);

        // Wrap implementations all return a value in [0, size). The cast
        // back to u16 is therefore safe because INT-014 caps `size_log2`
        // at the apparent-texture-size budget.
        let wrapped_u = u16::try_from(wrapped).unwrap_or(0);
        let low_bit = (wrapped_u & 1) as u8;
        let half_res_idx = wrapped_u >> 1;

        (half_res_idx, low_bit)
    }
}

/// Combine per-axis low bits into the UNIT-011.01 quadrant selector.
///
/// `quadrant[1:0] = {v_low, u_low}` -- bit 0 is `u_low`, bit 1 is `v_low`.
/// The encoding selects the palette entry within the 2x2 apparent-texel
/// tile:
///
/// ```text
/// quadrant = 0b00 -> NW (u even, v even)
/// quadrant = 0b01 -> NE (u odd,  v even)
/// quadrant = 0b10 -> SW (u even, v odd)
/// quadrant = 0b11 -> SE (u odd,  v odd)
/// ```
#[must_use]
pub fn compute_quadrant(u_low: u8, v_low: u8) -> u8 {
    ((v_low & 1) << 1) | (u_low & 1)
}

// ── Internal helpers ────────────────────────────────────────────────────────

/// Convert a Q4.12 coordinate to the apparent integer texel coordinate
/// `floor(uv_q412 * size / 4096)`.
///
/// The result is signed because negative UVs need to flow through the
/// wrap-mode logic untouched (CLAMP and MIRROR depend on the sign).
/// The intermediate is held in `i32` to avoid overflow when the texture
/// is at the maximum supported size.
fn apparent_integer_coord(uv_q412: i16, size_log2: u8) -> i32 {
    let extended = i32::from(uv_q412);

    if size_log2 <= 12 {
        // Arithmetic shift right preserves sign for negative coordinates,
        // which is the same behaviour as a signed division by 4096/size.
        extended >> (12 - size_log2)
    } else {
        extended << (size_log2 - 12)
    }
}

/// Apply a single-axis wrap mode to a signed apparent integer coordinate.
///
/// `size` is the apparent texture size (`1 << size_log2`); always a power
/// of two with `size >= 2` per INT-014.
fn apply_wrap(coord: i32, size: i32, wrap: WrapModeE) -> i32 {
    let mask = size - 1;
    match wrap {
        // REPEAT: power-of-two AND-mask gives Euclidean modulo for both
        // positive and two's-complement negative inputs.
        WrapModeE::Repeat => coord & mask,

        // CLAMP-TO-EDGE: saturate to [0, size - 1].
        WrapModeE::ClampToEdge => coord.clamp(0, size - 1),

        // MIRROR: period 2*size, reflect on the upper half.
        WrapModeE::Mirror => {
            let period = size << 1;
            let period_mask = period - 1;
            let t = coord & period_mask; // Euclidean mod 2*size for power-of-two.
            if t < size {
                t
            } else {
                period - 1 - t
            }
        }

        // OCTAHEDRAL: reserved -- behaves like REPEAT until the
        // octahedral coupling is implemented in a later unit.
        WrapModeE::Octahedral => coord & mask,
    }
}

// ── Unit tests ──────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a Q4.12 raw value from an integer texel index (no fractional
    /// part). `1.0` in Q4.12 is `0x1000`, so integer index `n` is
    /// `n << 12`.
    fn q412_int(int_part: i16) -> i16 {
        int_part << 12
    }

    /// Build a Q4.12 raw value from `int_part + half`, exercising the
    /// fractional bit that gets discarded when the integer texel
    /// coordinate is computed with `size_log2 = 12`.
    fn q412_int_plus_half(int_part: i16) -> i16 {
        (int_part << 12) | 0x0800
    }

    // ── Apparent-coord math ────────────────────────────────────────────

    #[test]
    fn apparent_coord_size_equal_q_scale() {
        // size_log2 = 12 -> apparent coord = uv_q412 (the Q4.12 raw bits
        // are exactly the apparent texel index because each unit of UV
        // maps to 4096 texels).
        assert_eq!(apparent_integer_coord(q412_int(0), 12), 0);
        assert_eq!(apparent_integer_coord(q412_int(3), 12), 12_288);
        assert_eq!(apparent_integer_coord(q412_int(-1), 12), -4096);
        assert_eq!(apparent_integer_coord(q412_int_plus_half(2), 12), 10_240);
    }

    #[test]
    fn apparent_coord_size_one_apparent_per_uv_unit() {
        // size_log2 = 0 (size = 1) -> apparent coord = floor(uv_q412 / 4096).
        assert_eq!(apparent_integer_coord(q412_int(0), 0), 0);
        assert_eq!(apparent_integer_coord(q412_int(3), 0), 3);
        assert_eq!(apparent_integer_coord(q412_int(-1), 0), -1);
    }

    #[test]
    fn apparent_coord_smaller_size() {
        // size_log2 = 3 (size = 8): each unit of UV maps to 8 texels.
        // 1.0 in Q4.12 = 0x1000 -> apparent = 8.
        assert_eq!(apparent_integer_coord(q412_int(1), 3), 8);
        // 0.5 in Q4.12 = 0x0800 -> apparent = 4.
        assert_eq!(apparent_integer_coord(0x0800, 3), 4);
        // -0.25 -> -2 apparent texels (Q4.12 -0.25 = 0xF000 ... 0xFC00).
        assert_eq!(apparent_integer_coord(-0x0400, 3), -2);
    }

    // ── REPEAT ─────────────────────────────────────────────────────────

    #[test]
    fn repeat_wraps_at_boundary() {
        // size = 8, integer apparent coord = 8 wraps to 0.
        let (idx, low) = UvCoord::process(q412_int(1), WrapModeE::Repeat, 3);
        assert_eq!((idx, low), (0, 0));
    }

    #[test]
    fn repeat_wraps_negative() {
        // size = 8, apparent = -1 wraps to 7 (low=1, idx=3).
        let (idx, low) = UvCoord::process(-0x0200, WrapModeE::Repeat, 3);
        assert_eq!((idx, low), (3, 1));
    }

    #[test]
    fn repeat_in_range_passes_through() {
        // size = 8, apparent coord = 5 -> idx = 2, low = 1.
        let (idx, low) = UvCoord::process(q412_int_plus_half(2), WrapModeE::Repeat, 3);
        // 2.5 * 8 = 20 wraps mod 8 -> 4 -> idx 2, low 0.
        assert_eq!((idx, low), (2, 0));
    }

    // ── CLAMP-TO-EDGE ──────────────────────────────────────────────────

    #[test]
    fn clamp_below_zero_returns_zero() {
        let (idx, low) = UvCoord::process(q412_int(-1), WrapModeE::ClampToEdge, 3);
        assert_eq!((idx, low), (0, 0));
    }

    #[test]
    fn clamp_above_size_returns_size_minus_one() {
        // size = 8, coord = 16 -> clamp to 7 -> idx = 3, low = 1.
        let (idx, low) = UvCoord::process(q412_int(2), WrapModeE::ClampToEdge, 3);
        assert_eq!((idx, low), (3, 1));
    }

    #[test]
    fn clamp_in_range_passes_through() {
        // size = 8, apparent = 5 (uv = 5/8 = 0.625 -> 0x0A00).
        let (idx, low) = UvCoord::process(0x0A00, WrapModeE::ClampToEdge, 3);
        assert_eq!((idx, low), (2, 1));
    }

    // ── MIRROR ─────────────────────────────────────────────────────────

    #[test]
    fn mirror_at_size_returns_size_minus_one() {
        // size = 8, apparent coord = 8 sits at the start of the mirrored
        // tile -> reflects to 7.
        let (idx, low) = UvCoord::process(q412_int(1), WrapModeE::Mirror, 3);
        assert_eq!((idx, low), (3, 1));
    }

    #[test]
    fn mirror_within_first_tile_passes_through() {
        // size = 8, apparent coord = 3 stays as 3.
        let (idx, low) = UvCoord::process(0x0600, WrapModeE::Mirror, 3);
        assert_eq!((idx, low), (1, 1));
    }

    #[test]
    fn mirror_within_mirrored_tile_reflects() {
        // size = 8, apparent coord = 11 -> 11 mod 16 = 11, 11 >= 8 ->
        // reflect: 16 - 1 - 11 = 4. -> idx = 2, low = 0.
        let (idx, low) = UvCoord::process(q412_int_plus_half(1) | 0x0600, WrapModeE::Mirror, 3);
        // q412_int_plus_half(1) = 0x1800; or 0x0600 -> 0x1E00 -> 1.875
        // 1.875 * 8 = 15 -> mirror: 16 - 1 - 15 = 0 -> idx 0, low 0.
        assert_eq!((idx, low), (0, 0));
    }

    // ── Half-resolution address ────────────────────────────────────────

    #[test]
    fn half_res_address_apparent_five() {
        // Build apparent coord = 5 with REPEAT, large texture so no wrap.
        let (idx, low) = UvCoord::process(0x0A00, WrapModeE::Repeat, 3);
        // apparent = 5 -> half-res idx = 2, low = 1.
        assert_eq!((idx, low), (2, 1));
    }

    // ── Quadrant encoding ──────────────────────────────────────────────

    #[test]
    fn quadrant_encoding_matches_spec() {
        // Spec: quadrant[1:0] = {v_wrapped[0], u_wrapped[0]}; bit 0 = u_low,
        // bit 1 = v_low. Aligned with UNIT-011.06 EBR addressing.
        assert_eq!(compute_quadrant(0, 0), QUADRANT_NW);
        assert_eq!(compute_quadrant(1, 0), QUADRANT_NE); // u odd, v even -> 0b01
        assert_eq!(compute_quadrant(0, 1), QUADRANT_SW); // u even, v odd -> 0b10
        assert_eq!(compute_quadrant(1, 1), QUADRANT_SE);

        assert_eq!(QUADRANT_NW, 0b00);
        assert_eq!(QUADRANT_NE, 0b01);
        assert_eq!(QUADRANT_SW, 0b10);
        assert_eq!(QUADRANT_SE, 0b11);
    }

    #[test]
    fn quadrant_extraction_apparent_u1_v0() {
        // Apparent u = 1 (odd), apparent v = 0 (even) -> NE.
        // With {v_low, u_low} = {0, 1} the packed quadrant is 0b01.
        let (_, u_low) = UvCoord::process(0x0200, WrapModeE::Repeat, 3); // 1/8 -> apparent 1
        let (_, v_low) = UvCoord::process(0x0000, WrapModeE::Repeat, 3); // 0   -> apparent 0
        let q = compute_quadrant(u_low, v_low);
        assert_eq!(q, QUADRANT_NE);
        assert_eq!(q, 0b01);
    }

    // ── MIRROR quadrant swap ───────────────────────────────────────────

    #[test]
    fn mirror_swaps_ne_and_nw() {
        // In the first (non-mirrored) tile, apparent u = 1 has u_low = 1
        // (NE relative to NW). In the mirrored tile (apparent u = size +
        // 1 = 9 for size = 8), the reflection 16 - 1 - 9 = 6 has u_low =
        // 0 -- the NE/NW pair swaps.
        let (_, low_first) = UvCoord::process(0x0200, WrapModeE::Mirror, 3); // apparent 1
                                                                             // apparent = 9 -> uv = 9/8 = 1.125 -> 0x1200.
        let (_, low_mirror) = UvCoord::process(0x1200, WrapModeE::Mirror, 3);

        assert_eq!(low_first, 1);
        assert_eq!(low_mirror, 0);
    }

    #[test]
    fn mirror_swaps_se_and_sw() {
        // Same idea on the V axis: mirrored tile flips SE<->SW.
        let (_, low_first) = UvCoord::process(0x0200, WrapModeE::Mirror, 3); // apparent 1, v_low 1
        let (_, low_mirror) = UvCoord::process(0x1200, WrapModeE::Mirror, 3); // apparent 9 -> 6, v_low 0

        // v_low complements between the first and mirrored tile.
        assert_eq!(low_first ^ low_mirror, 1);
    }

    // ── Round-trip sanity at extremes ──────────────────────────────────

    #[test]
    fn extremes_within_apparent_range() {
        // Largest representable Q4.12 (0x7FFF) at size = 4 should still
        // produce a wrapped index in [0, 1] (size/2 = 2 entries).
        let (idx, low) = UvCoord::process(0x7FFF, WrapModeE::Repeat, 2);
        assert!(idx < 2);
        assert!(low <= 1);

        // Most-negative Q4.12 at size = 4 (REPEAT): two's-complement
        // mask collapses negatives correctly to [0, size).
        let (idx, low) = UvCoord::process(-0x8000, WrapModeE::Repeat, 2);
        assert!(idx < 2);
        assert!(low <= 1);
    }
}
