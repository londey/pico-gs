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
use crate::mem::GpuMemory;
use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
use gpu_registers::components::z_compare_e::ZCompareE;

/// Perform the early Z-buffer test.
///
/// # Arguments
///
/// * `frag` - Rasterizer output fragment.
/// * `memory` - GPU memory (SDRAM backing store for Z-buffer).
/// * `fb_config` - Framebuffer configuration (Z_BASE, dimensions).
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
    _memory: &mut GpuMemory,
    _fb_config: &FbConfigReg,
    _z_test_en: bool,
    _z_write_en: bool,
    _z_compare: ZCompareE,
) -> Option<RasterFragment> {
    // TODO: implement Z-buffer test and conditional write via tiled SDRAM
    Some(frag)
}
