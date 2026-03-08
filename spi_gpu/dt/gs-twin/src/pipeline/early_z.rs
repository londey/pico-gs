//! Early Z test — depth buffer read-compare-conditional-write.
//!
//! Tests the fragment's depth against the Z-buffer value at (x, y).
//! If the fragment fails the comparison, it is discarded before
//! texture sampling, saving SDRAM bandwidth.
//!
//! # RTL Implementation Notes
//!
//! The Z-buffer uses a 4-way set-associative tile cache (4×4 tiles,
//! 16 sets) to absorb read/write traffic.
//! Can kill the fragment (✗).
//! See UNIT-006, early_z.sv.

use super::fragment::RasterFragment;
use crate::mem::RawZBuffer;
use gpu_registers::components::z_compare_e::ZCompareE;

/// Perform the early Z-buffer test.
///
/// # Arguments
///
/// * `frag` - Rasterizer output fragment.
/// * `zbuf` - Mutable reference to the Z-buffer for read/write.
/// * `z_test_en` - Whether depth testing is enabled.
/// * `z_write_en` - Whether depth writes are enabled (independent of test).
/// * `z_compare` - Depth comparison function.
///
/// # Returns
///
/// `Some(frag)` if the fragment passes (or testing is disabled),
/// `None` if the fragment fails the depth test.
pub fn early_z_test(
    frag: RasterFragment,
    _zbuf: &mut RawZBuffer,
    _z_test_en: bool,
    _z_write_en: bool,
    _z_compare: ZCompareE,
) -> Option<RasterFragment> {
    // TODO: implement Z-buffer test and conditional write
    Some(frag)
}
