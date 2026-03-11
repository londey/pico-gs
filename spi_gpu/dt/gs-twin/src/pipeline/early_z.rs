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
    memory: &mut GpuMemory,
    fb_config: &FbConfigReg,
    z_test_en: bool,
    z_write_en: bool,
    z_compare: ZCompareE,
) -> Option<RasterFragment> {
    let wl2 = fb_config.width_log2();
    let z_base = fb_config.z_base();
    let x = frag.x as u32;
    let y = frag.y as u32;

    if z_test_en {
        let stored = memory.read_tiled(z_base, wl2, x, y);
        let pass = match z_compare {
            ZCompareE::Never => false,
            ZCompareE::Less => frag.z < stored,
            ZCompareE::Lequal => frag.z <= stored,
            ZCompareE::Equal => frag.z == stored,
            ZCompareE::Greater => frag.z > stored,
            ZCompareE::Gequal => frag.z >= stored,
            ZCompareE::Notequal => frag.z != stored,
            ZCompareE::Always => true,
        };
        if !pass {
            return None;
        }
        if z_write_en {
            memory.write_tiled(z_base, wl2, x, y, frag.z);
        }
    } else if z_write_en {
        memory.write_tiled(z_base, wl2, x, y, frag.z);
    }

    Some(frag)
}
