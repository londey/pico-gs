//! Stipple test — fragment discard based on screen-position bitmask.
//!
//! The stipple pattern is an 8×8 bitmask stored in the STIPPLE register.
//! For each fragment, `pattern[y%8][x%8]` is tested: if the bit is clear,
//! the fragment is discarded.
//! This enables order-independent transparency effects without
//! framebuffer reads.
//!
//! # RTL Implementation Notes
//!
//! First stage in the fragment pipeline (UNIT-006).
//! Can kill the fragment (✗), skipping all subsequent stages and
//! SDRAM traffic.

use gs_twin_core::fragment::RasterFragment;

/// Test a fragment against the 8×8 stipple bitmask.
///
/// # Arguments
///
/// * `frag` - Rasterizer output fragment.
/// * `stipple_en` - Whether stipple testing is enabled.
/// * `stipple_pattern` - 64-bit bitmask (8 rows × 8 columns, row-major).
///
/// # Returns
///
/// `Some(frag)` if the fragment passes, `None` if discarded.
pub fn stipple_test(
    frag: RasterFragment,
    stipple_en: bool,
    stipple_pattern: u64,
) -> Option<RasterFragment> {
    if !stipple_en {
        return Some(frag);
    }

    // Only low 3 bits of x and y select the 8x8 tile position.
    let bit_index = (frag.y as u32 & 7) * 8 + (frag.x as u32 & 7);

    if (stipple_pattern >> bit_index) & 1 == 1 {
        Some(frag)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a test fragment at the given screen position.
    fn frag_at(x: u16, y: u16) -> RasterFragment {
        RasterFragment {
            x,
            y,
            ..Default::default()
        }
    }

    /// Stipple disabled passes all fragments regardless of pattern.
    #[test]
    fn disabled_passes_all() {
        let pattern = 0x0000_0000_0000_0000_u64;
        for y in 0..8_u16 {
            for x in 0..8_u16 {
                assert!(
                    stipple_test(frag_at(x, y), false, pattern).is_some(),
                    "disabled stipple should pass ({x}, {y})"
                );
            }
        }
    }

    /// All-ones pattern passes every fragment.
    #[test]
    fn all_ones_passes_all() {
        let pattern = 0xFFFF_FFFF_FFFF_FFFF_u64;
        for y in 0..8_u16 {
            for x in 0..8_u16 {
                assert!(
                    stipple_test(frag_at(x, y), true, pattern).is_some(),
                    "all-ones should pass ({x}, {y})"
                );
            }
        }
    }

    /// All-zeros pattern discards every fragment.
    #[test]
    fn all_zeros_discards_all() {
        let pattern = 0x0000_0000_0000_0000_u64;
        for y in 0..8_u16 {
            for x in 0..8_u16 {
                assert!(
                    stipple_test(frag_at(x, y), true, pattern).is_none(),
                    "all-zeros should discard ({x}, {y})"
                );
            }
        }
    }

    /// Checkerboard pattern alternates pass/discard.
    #[test]
    fn checkerboard_alternates() {
        let pattern = 0xAA55_AA55_AA55_AA55_u64;
        for y in 0..8_u16 {
            for x in 0..8_u16 {
                let result = stipple_test(frag_at(x, y), true, pattern);
                let bit_index = (y as u32 & 7) * 8 + (x as u32 & 7);
                let expected_pass = (pattern >> bit_index) & 1 == 1;
                assert_eq!(
                    result.is_some(),
                    expected_pass,
                    "checkerboard mismatch at ({x}, {y}), bit_index={bit_index}"
                );
            }
        }
    }

    /// Single-bit pattern verifies exact bit indexing for each position.
    #[test]
    fn single_bit_indexing() {
        for bit in 0..64_u32 {
            let pattern = 1_u64 << bit;
            let x = (bit % 8) as u16;
            let y = (bit / 8) as u16;

            // The fragment at the matching position should pass.
            assert!(
                stipple_test(frag_at(x, y), true, pattern).is_some(),
                "bit {bit}: ({x}, {y}) should pass"
            );

            // A neighboring position (one column over, wrapping) should not.
            let nx = ((bit + 1) % 8) as u16;
            let ny = ((bit + 1) / 8) as u16;
            if (nx, ny) != (x, y) {
                assert!(
                    stipple_test(frag_at(nx, ny), true, pattern).is_none(),
                    "bit {bit}: ({nx}, {ny}) should be discarded"
                );
            }
        }
    }

    /// Boundary corners of the 8x8 tile.
    #[test]
    fn boundary_corners() {
        // Pattern with only bit 0 set: (0,0) passes, others don't.
        let pattern = 1_u64;
        assert!(stipple_test(frag_at(0, 0), true, pattern).is_some());
        assert!(stipple_test(frag_at(7, 7), true, pattern).is_none());
        assert!(stipple_test(frag_at(7, 0), true, pattern).is_none());
        assert!(stipple_test(frag_at(0, 7), true, pattern).is_none());

        // Pattern with only bit 63 set: (7,7) passes.
        let pattern = 1_u64 << 63;
        assert!(stipple_test(frag_at(7, 7), true, pattern).is_some());
        assert!(stipple_test(frag_at(0, 0), true, pattern).is_none());

        // Bit 7 = (7,0); bit 56 = (0,7).
        let pattern = 1_u64 << 7;
        assert!(stipple_test(frag_at(7, 0), true, pattern).is_some());

        let pattern = 1_u64 << 56;
        assert!(stipple_test(frag_at(0, 7), true, pattern).is_some());
    }

    /// Coordinates larger than 7 wrap via `& 7` — x=8 behaves like x=0.
    #[test]
    fn coordinates_wrap() {
        let pattern = 0xFFFF_FFFF_FFFF_FFFE_u64; // bit 0 clear, all others set

        // (0, 0) maps to bit 0 → discarded.
        assert!(stipple_test(frag_at(0, 0), true, pattern).is_none());

        // (8, 0) wraps to (0, 0) → also discarded.
        assert!(stipple_test(frag_at(8, 0), true, pattern).is_none());

        // (16, 0), (24, 0), (256, 0) all wrap to (0, 0).
        assert!(stipple_test(frag_at(16, 0), true, pattern).is_none());
        assert!(stipple_test(frag_at(256, 0), true, pattern).is_none());

        // (0, 8) wraps to (0, 0) → discarded.
        assert!(stipple_test(frag_at(0, 8), true, pattern).is_none());

        // (1, 0) maps to bit 1 → passes.
        assert!(stipple_test(frag_at(1, 0), true, pattern).is_some());

        // (9, 0) wraps to (1, 0) → passes.
        assert!(stipple_test(frag_at(9, 0), true, pattern).is_some());
    }
}
