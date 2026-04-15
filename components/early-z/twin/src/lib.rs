//! Early Z test — depth range clipping and depth buffer read-compare.
//!
//! Performs two checks on each incoming fragment:
//!
//! 1. **Depth range clip (Z scissor):** Discards fragments whose Z
//!    value falls outside the configured `[z_range_min, z_range_max]`
//!    window (inclusive).  This is a register-only comparison with no
//!    SDRAM access.
//!
//! 2. **Z-buffer compare:** Tests the fragment's depth against the
//!    stored Z-buffer value at `(x, y)` using the configured compare
//!    function.  If the fragment fails, it is discarded before texture
//!    sampling, saving SDRAM bandwidth.
//!
//! Z-buffer **writes** are deferred to the pixel_write stage, after
//! alpha test, so that alpha-killed fragments do not pollute the
//! Z-buffer.
//!
//! # RTL Implementation Notes
//!
//! The Z-buffer uses a 4-way set-associative tile cache (4×4 tiles,
//! 16 sets) to absorb read/write traffic.
//! Can kill the fragment (✗).
//! See UNIT-006, early_z.sv.

use gpu_registers::components::z_compare_e::ZCompareE;
use gs_twin_core::fragment::RasterFragment;

/// Test whether `fragment_z` passes the depth range clip.
///
/// # Arguments
///
/// * `fragment_z` - The fragment's interpolated depth value.
/// * `z_range_min` - Minimum allowed depth (unsigned 16-bit, inclusive).
/// * `z_range_max` - Maximum allowed depth (unsigned 16-bit, inclusive).
///
/// # Returns
///
/// `true` if the fragment is within range.
pub fn depth_range_pass(fragment_z: u16, z_range_min: u16, z_range_max: u16) -> bool {
    fragment_z >= z_range_min && fragment_z <= z_range_max
}

/// Test whether `fragment_z` passes the Z-buffer comparison.
///
/// When `z_test_en` is false or `z_compare` is `Always`, the test is
/// bypassed and the fragment always passes.
///
/// # Arguments
///
/// * `fragment_z` - The fragment's interpolated depth value.
/// * `zbuffer_z` - The stored Z-buffer value at the fragment's position.
/// * `z_test_en` - Whether depth testing is enabled.
/// * `z_compare` - Depth comparison function.
///
/// # Returns
///
/// `true` if the fragment passes (or testing is bypassed).
pub fn z_compare_pass(
    fragment_z: u16,
    zbuffer_z: u16,
    z_test_en: bool,
    z_compare: ZCompareE,
) -> bool {
    if !z_test_en || matches!(z_compare, ZCompareE::Always) {
        return true;
    }
    match z_compare {
        ZCompareE::Never => false,
        ZCompareE::Less => fragment_z < zbuffer_z,
        ZCompareE::Lequal => fragment_z <= zbuffer_z,
        ZCompareE::Equal => fragment_z == zbuffer_z,
        ZCompareE::Greater => fragment_z > zbuffer_z,
        ZCompareE::Gequal => fragment_z >= zbuffer_z,
        ZCompareE::Notequal => fragment_z != zbuffer_z,
        ZCompareE::Always => true,
    }
}

/// Perform the combined early Z test (depth range + Z-buffer compare).
///
/// Convenience wrapper used by the pipeline orchestrator.  Runs depth
/// range clipping first; if the fragment survives, compares against
/// `zbuffer_z` using `z_compare`.
///
/// # Arguments
///
/// * `frag` - Rasterizer output fragment.
/// * `zbuffer_z` - Stored Z-buffer value (read via Z-cache by caller).
/// * `z_range_min` - Minimum allowed depth (inclusive).
/// * `z_range_max` - Maximum allowed depth (inclusive).
/// * `z_test_en` - Whether depth testing is enabled.
/// * `z_compare` - Depth comparison function.
///
/// # Returns
///
/// `Some(frag)` if the fragment passes both tests, `None` otherwise.
pub fn early_z_test(
    frag: RasterFragment,
    zbuffer_z: u16,
    z_range_min: u16,
    z_range_max: u16,
    z_test_en: bool,
    z_compare: ZCompareE,
) -> Option<RasterFragment> {
    if !depth_range_pass(frag.z, z_range_min, z_range_max) {
        return None;
    }
    if z_compare_pass(frag.z, zbuffer_z, z_test_en, z_compare) {
        Some(frag)
    } else {
        None
    }
}
