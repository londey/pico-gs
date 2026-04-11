//! Color tile buffer -- 4x4 pixel cache for burst SDRAM access.
//!
//! The tile buffer holds one 4x4 tile of RGB565 pixels, reducing
//! framebuffer SDRAM traffic from per-pixel reads/writes to per-tile
//! burst transfers.
//! On tile entry, the buffer is prefetched from SDRAM (16-word burst read).
//! On tile exit, dirty data is flushed back (16-word burst write).
//!
//! # RTL Implementation Notes
//!
//! Implemented as a 16x16-bit register file in distributed LUTs.
//! See UNIT-006 (Pixel Pipeline), color tile buffer.

use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
use gs_memory::GpuMemory;
use gs_twin_core::fragment::ColorQ412;
use gs_twin_core::math::Rgb565;
use qfixed::Q;

/// 4x4 color tile buffer for burst framebuffer access.
///
/// Caches one 4x4 tile of RGB565 pixels to amortize SDRAM read/write
/// costs across multiple fragments in the same tile.
pub struct ColorTileBuffer {
    /// 4x4 array of RGB565 pixel values (row-major, 16 entries).
    pixels: [u16; 16],

    /// Current tile column (x >> 2).
    tile_col: u32,

    /// Current tile row (y >> 2).
    tile_row: u32,

    /// Whether any pixel has been written since the last prefetch.
    dirty: bool,

    /// Whether the buffer contains valid data (has been prefetched).
    valid: bool,
}

impl Default for ColorTileBuffer {
    fn default() -> Self {
        Self::new()
    }
}

impl ColorTileBuffer {
    /// Create a new, empty tile buffer.
    #[must_use]
    pub fn new() -> Self {
        Self {
            pixels: [0; 16],
            tile_col: u32::MAX,
            tile_row: u32::MAX,
            dirty: false,
            valid: false,
        }
    }

    /// Ensure the buffer contains data for the tile at the given pixel coordinates.
    ///
    /// If the pixel is in a different tile than currently cached, flush the
    /// old tile (if dirty) and prefetch the new one.
    ///
    /// # Arguments
    ///
    /// * `memory` - GPU memory (SDRAM backing store).
    /// * `fb_config` - Framebuffer configuration.
    /// * `px` - Pixel X coordinate.
    /// * `py` - Pixel Y coordinate.
    pub fn ensure_tile(
        &mut self,
        memory: &mut GpuMemory,
        fb_config: &FbConfigReg,
        px: u32,
        py: u32,
    ) {
        let new_col = px >> 2;
        let new_row = py >> 2;

        if self.valid && new_col == self.tile_col && new_row == self.tile_row {
            return;
        }

        // Flush current tile if dirty
        if self.dirty {
            self.flush(memory, fb_config);
        }

        // Prefetch new tile
        self.prefetch(memory, fb_config, new_col, new_row);
    }

    /// Prefetch a tile from SDRAM into the buffer.
    ///
    /// # Arguments
    ///
    /// * `memory` - GPU memory (SDRAM backing store).
    /// * `fb_config` - Framebuffer configuration.
    /// * `tile_col` - Tile column index (pixel_x >> 2).
    /// * `tile_row` - Tile row index (pixel_y >> 2).
    fn prefetch(
        &mut self,
        memory: &GpuMemory,
        fb_config: &FbConfigReg,
        tile_col: u32,
        tile_row: u32,
    ) {
        let wl2 = fb_config.width_log2();
        let base_x = tile_col << 2;
        let base_y = tile_row << 2;

        for ly in 0..4u32 {
            for lx in 0..4u32 {
                let idx = (ly * 4 + lx) as usize;
                self.pixels[idx] =
                    memory.read_tiled(fb_config.color_base(), wl2, base_x + lx, base_y + ly);
            }
        }

        self.tile_col = tile_col;
        self.tile_row = tile_row;
        self.dirty = false;
        self.valid = true;
    }

    /// Read a pixel from the buffer.
    ///
    /// # Arguments
    ///
    /// * `local_x` - X coordinate within the tile (0..3).
    /// * `local_y` - Y coordinate within the tile (0..3).
    ///
    /// # Returns
    ///
    /// The RGB565 pixel value.
    #[must_use]
    pub fn read_pixel(&self, local_x: u32, local_y: u32) -> Rgb565 {
        debug_assert!(local_x < 4 && local_y < 4);
        let idx = (local_y * 4 + local_x) as usize;
        Rgb565(self.pixels[idx])
    }

    /// Write a pixel into the buffer, marking it dirty.
    ///
    /// # Arguments
    ///
    /// * `local_x` - X coordinate within the tile (0..3).
    /// * `local_y` - Y coordinate within the tile (0..3).
    /// * `value` - RGB565 pixel value to store.
    pub fn write_pixel(&mut self, local_x: u32, local_y: u32, value: Rgb565) {
        debug_assert!(local_x < 4 && local_y < 4);
        let idx = (local_y * 4 + local_x) as usize;
        self.pixels[idx] = value.0;
        self.dirty = true;
    }

    /// Flush dirty data back to SDRAM.
    ///
    /// # Arguments
    ///
    /// * `memory` - GPU memory (SDRAM backing store).
    /// * `fb_config` - Framebuffer configuration.
    pub fn flush(&mut self, memory: &mut GpuMemory, fb_config: &FbConfigReg) {
        if !self.dirty {
            return;
        }

        let wl2 = fb_config.width_log2();
        let base_x = self.tile_col << 2;
        let base_y = self.tile_row << 2;

        for ly in 0..4u32 {
            for lx in 0..4u32 {
                let idx = (ly * 4 + lx) as usize;
                memory.write_tiled(
                    fb_config.color_base(),
                    wl2,
                    base_x + lx,
                    base_y + ly,
                    self.pixels[idx],
                );
            }
        }

        self.dirty = false;
    }

    /// Flush any remaining dirty data (call at end of triangle).
    ///
    /// # Arguments
    ///
    /// * `memory` - GPU memory (SDRAM backing store).
    /// * `fb_config` - Framebuffer configuration.
    pub fn flush_if_dirty(&mut self, memory: &mut GpuMemory, fb_config: &FbConfigReg) {
        self.flush(memory, fb_config);
    }

    /// Invalidate the buffer (e.g. on FB_CONFIG change).
    pub fn invalidate(&mut self) {
        self.valid = false;
        self.dirty = false;
        self.tile_col = u32::MAX;
        self.tile_row = u32::MAX;
    }
}

/// Promote an RGB565 framebuffer pixel to Q4.12 per-channel.
///
/// Maps UNORM [0, 1.0] exactly to Q4.12 [0x0000, 0x1000]. The base
/// MSB-replication produces 0x0FFF at full scale; the extra
/// `(v >> 4)` / `(v >> 5)` term supplies the final LSB so that
/// 5/6-bit all-ones round up to 0x1000 = 1.0, while all smaller
/// values remain within 1 LSB of the ideal `v * 0x1000 / max` ratio.
///
/// Matches RTL `fb_promote.sv`.
pub fn promote_rgb565(pixel: Rgb565) -> ColorQ412 {
    let r5 = (pixel.0 >> 11) & 0x1F;
    let g6 = (pixel.0 >> 5) & 0x3F;
    let b5 = pixel.0 & 0x1F;

    let r_q412 = ((r5 << 7) | (r5 << 2) | (r5 >> 3)) + (r5 >> 4);
    let g_q412 = ((g6 << 6) | g6) + (g6 >> 5);
    let b_q412 = ((b5 << 7) | (b5 << 2) | (b5 >> 3)) + (b5 >> 4);

    ColorQ412 {
        r: Q::from_bits(r_q412 as i64),
        g: Q::from_bits(g_q412 as i64),
        b: Q::from_bits(b_q412 as i64),
        a: Q::from_bits(0x1000), // opaque (promoted dst has no alpha channel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;

    fn make_fb_config(color_base: u16, width_log2: u8) -> FbConfigReg {
        let mut cfg = FbConfigReg::default();
        cfg.set_color_base(color_base);
        cfg.set_width_log2(width_log2);
        cfg.set_height_log2(width_log2);
        cfg
    }

    #[test]
    fn prefetch_read_round_trip() {
        let mut mem = GpuMemory::new();
        let fb_cfg = make_fb_config(0, 8);

        // Write a known pixel at (4, 4) — tile (1, 1)
        mem.write_tiled(0, 8, 4, 4, 0x1234);

        let mut buf = ColorTileBuffer::new();
        buf.ensure_tile(&mut mem, &fb_cfg, 4, 4);

        let pixel = buf.read_pixel(0, 0); // local (0,0) of tile (1,1) = global (4,4)
        assert_eq!(pixel.0, 0x1234);
    }

    #[test]
    fn write_flush_round_trip() {
        let mut mem = GpuMemory::new();
        let fb_cfg = make_fb_config(0, 8);

        let mut buf = ColorTileBuffer::new();
        buf.ensure_tile(&mut mem, &fb_cfg, 0, 0);
        buf.write_pixel(1, 2, Rgb565(0xABCD));
        buf.flush(&mut mem, &fb_cfg);

        let stored = mem.read_tiled(0, 8, 1, 2);
        assert_eq!(stored, 0xABCD);
    }

    #[test]
    fn tile_change_flushes_old() {
        let mut mem = GpuMemory::new();
        let fb_cfg = make_fb_config(0, 8);

        let mut buf = ColorTileBuffer::new();
        buf.ensure_tile(&mut mem, &fb_cfg, 0, 0);
        buf.write_pixel(0, 0, Rgb565(0x5678));

        // Move to a new tile — should flush the old one
        buf.ensure_tile(&mut mem, &fb_cfg, 4, 0);

        let stored = mem.read_tiled(0, 8, 0, 0);
        assert_eq!(stored, 0x5678);
    }

    #[test]
    fn promote_white() {
        let c = promote_rgb565(Rgb565(0xFFFF));
        assert_eq!(c.r.to_bits(), 0x1000);
        assert_eq!(c.g.to_bits(), 0x1000);
        assert_eq!(c.b.to_bits(), 0x1000);
        assert_eq!(c.a.to_bits(), 0x1000);
    }

    #[test]
    fn promote_black() {
        let c = promote_rgb565(Rgb565(0x0000));
        assert_eq!(c.r.to_bits(), 0);
        assert_eq!(c.g.to_bits(), 0);
        assert_eq!(c.b.to_bits(), 0);
        assert_eq!(c.a.to_bits(), 0x1000);
    }
}
