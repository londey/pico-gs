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
    _stipple_en: bool,
    _stipple_pattern: u64,
) -> Option<RasterFragment> {
    // TODO: implement stipple bitmask lookup
    Some(frag)
}
