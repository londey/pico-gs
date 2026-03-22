//! Pixel write — final framebuffer and Z-buffer output.
//!
//! Writes the fragment's RGB565 color to the framebuffer and
//! optionally updates the Z-buffer, controlled by per-draw-call
//! write-enable flags.
//!
//! # RTL Implementation Notes
//!
//! Color writes go through a write-coalescing buffer before reaching
//! the SDRAM arbiter; Z updates go through the Z-buffer tile cache.
//! See UNIT-006, pixel_write stage.

use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
use gs_memory::GpuMemory;
use gs_twin_core::fragment::PixelOut;

/// Write a fragment to the framebuffer and Z-buffer in SDRAM.
///
/// # Arguments
///
/// * `frag` - Final pixel output (RGB565 color + depth).
/// * `memory` - GPU memory (SDRAM backing store).
/// * `fb_config` - Framebuffer configuration (base addresses, dimensions).
/// * `color_write_en` - Whether color writes are enabled.
/// * `z_write_en` - Whether Z-buffer writes are enabled.
pub fn pixel_write(
    _frag: &PixelOut,
    _memory: &mut GpuMemory,
    _fb_config: &FbConfigReg,
    _color_write_en: bool,
    _z_write_en: bool,
) {
    // TODO: implement framebuffer and Z-buffer writes via tiled SDRAM
}
