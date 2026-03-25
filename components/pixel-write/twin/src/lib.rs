//! Pixel write — final framebuffer and Z-buffer output.
//!
//! Writes the fragment's RGB565 color to the framebuffer and
//! optionally updates the Z-buffer, controlled by per-draw-call
//! write-enable flags.
//! When Z-writes are enabled, the Hi-Z metadata store (UNIT-005.06)
//! is also updated with the written Z value's upper 8 bits.
//!
//! # RTL Implementation Notes
//!
//! Color writes go through a write-coalescing buffer before reaching
//! the SDRAM arbiter; Z updates go through the Z-buffer tile cache.
//! See UNIT-006, pixel_write stage.

// Spec-ref: unit_006_pixel_pipeline.md `0000000000000000` 1970-01-01

use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
use gs_memory::GpuMemory;
use gs_twin_core::fragment::PixelOut;
use gs_twin_core::hiz::HizMetadata;

/// Write a fragment to the framebuffer and Z-buffer in SDRAM.
///
/// Performs tiled writes to both the color buffer and Z-buffer, and
/// updates the Hi-Z metadata store when Z-writes are enabled.
///
/// # Arguments
///
/// * `frag` - Final pixel output (RGB565 color + depth).
/// * `memory` - GPU memory (SDRAM backing store).
/// * `fb_config` - Framebuffer configuration (base addresses, dimensions).
/// * `color_write_en` - Whether color writes are enabled.
/// * `z_write_en` - Whether Z-buffer writes are enabled.
/// * `hiz` - Hi-Z metadata store (UNIT-005.06); updated on Z-writes.
pub fn pixel_write(
    frag: &PixelOut,
    memory: &mut GpuMemory,
    fb_config: &FbConfigReg,
    color_write_en: bool,
    z_write_en: bool,
    hiz: &mut HizMetadata,
) {
    let wl2 = fb_config.width_log2();
    let fx = u32::from(frag.x);
    let fy = u32::from(frag.y);

    if color_write_en {
        memory.write_tiled(fb_config.color_base(), wl2, fx, fy, frag.color.0);
    }

    if z_write_en {
        memory.write_tiled(fb_config.z_base(), wl2, fx, fy, frag.z);

        // Compute tile index: tile_row * tile_cols + tile_col
        // tile_col = x >> 2, tile_row = y >> 2
        // tile_cols_log2 = width_log2 - 2
        let tile_col = fx >> 2;
        let tile_row = fy >> 2;
        let tile_cols_log2 = wl2 as u32 - 2;
        let tile_index = ((tile_row << tile_cols_log2) | tile_col) as usize;

        hiz.update(tile_index, (frag.z >> 8) as u8);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
    use gs_twin_core::math::Rgb565;

    /// Helper: create an `FbConfigReg` with the given parameters.
    fn make_fb_config(color_base: u16, z_base: u16, width_log2: u8) -> FbConfigReg {
        let mut cfg = FbConfigReg::default();
        cfg.set_color_base(color_base);
        cfg.set_z_base(z_base);
        cfg.set_width_log2(width_log2);
        cfg.set_height_log2(width_log2);
        cfg
    }

    /// Helper: create a `PixelOut` at the given position with the given Z.
    fn make_frag(x: u16, y: u16, z: u16) -> PixelOut {
        PixelOut {
            x,
            y,
            z,
            color: Rgb565(0x1234),
        }
    }

    /// Compute the expected tile index for a pixel at (x, y) with given
    /// width_log2.
    fn tile_index(x: u16, y: u16, width_log2: u8) -> usize {
        let tile_col = (x >> 2) as usize;
        let tile_row = (y >> 2) as usize;
        let tile_cols_log2 = width_log2 as usize - 2;
        (tile_row << tile_cols_log2) | tile_col
    }

    #[test]
    fn z_write_updates_hiz_first_write() {
        let mut memory = GpuMemory::new();
        let mut hiz = HizMetadata::new();
        let fb_cfg = make_fb_config(0, 64, 9); // 512-wide, z_base=64
        let frag = make_frag(8, 12, 0x4000); // tile (2, 3)

        pixel_write(&frag, &mut memory, &fb_cfg, false, true, &mut hiz);

        let idx = tile_index(8, 12, 9);
        let (valid, min_z) = hiz.read(idx);
        assert!(valid, "entry should be valid after Z-write");
        assert_eq!(min_z, 0x40, "min_z should be z[15:8] = 0x40");
    }

    #[test]
    fn z_write_does_not_lower_min_z_on_larger_value() {
        let mut memory = GpuMemory::new();
        let mut hiz = HizMetadata::new();
        let fb_cfg = make_fb_config(0, 64, 9);
        let idx = tile_index(8, 12, 9);

        // First write: Z=0x4000 → min_z=0x40
        let frag1 = make_frag(8, 12, 0x4000);
        pixel_write(&frag1, &mut memory, &fb_cfg, false, true, &mut hiz);

        // Second write: Z=0x8000 → min_z should stay 0x40
        let frag2 = make_frag(9, 13, 0x8000);
        pixel_write(&frag2, &mut memory, &fb_cfg, false, true, &mut hiz);

        let (valid, min_z) = hiz.read(idx);
        assert!(valid);
        assert_eq!(min_z, 0x40, "min_z should remain 0x40 (smaller value)");
    }

    #[test]
    fn z_write_updates_min_z_on_smaller_value() {
        let mut memory = GpuMemory::new();
        let mut hiz = HizMetadata::new();
        let fb_cfg = make_fb_config(0, 64, 9);
        let idx = tile_index(8, 12, 9);

        // First write: Z=0x4000 → min_z=0x40
        let frag1 = make_frag(8, 12, 0x4000);
        pixel_write(&frag1, &mut memory, &fb_cfg, false, true, &mut hiz);

        // Third write: Z=0x1000 → min_z should update to 0x10
        let frag3 = make_frag(8, 12, 0x1000);
        pixel_write(&frag3, &mut memory, &fb_cfg, false, true, &mut hiz);

        let (valid, min_z) = hiz.read(idx);
        assert!(valid);
        assert_eq!(min_z, 0x10, "min_z should update to 0x10");
    }

    #[test]
    fn z_write_disabled_does_not_modify_hiz() {
        let mut memory = GpuMemory::new();
        let mut hiz = HizMetadata::new();
        let fb_cfg = make_fb_config(0, 64, 9);
        let idx = tile_index(8, 12, 9);

        let frag = make_frag(8, 12, 0x4000);
        pixel_write(&frag, &mut memory, &fb_cfg, false, false, &mut hiz);

        let (valid, _) = hiz.read(idx);
        assert!(!valid, "entry should remain invalid when z_write_en=false");
    }

    #[test]
    fn color_write_stores_rgb565() {
        let mut memory = GpuMemory::new();
        let mut hiz = HizMetadata::new();
        let fb_cfg = make_fb_config(0, 64, 9);

        let frag = make_frag(4, 4, 0x5000);
        pixel_write(&frag, &mut memory, &fb_cfg, true, false, &mut hiz);

        let stored = memory.read_tiled(fb_cfg.color_base(), fb_cfg.width_log2(), 4, 4);
        assert_eq!(stored, 0x1234, "color should be written to SDRAM");
    }
}
