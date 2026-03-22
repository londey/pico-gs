//! GPU memory model.
//!
//! Models the full 32 MiB SDRAM as a flat `Vec<u16>` backing store.
//! All memory operations (MEM_FILL, pixel writes, Z-test, display scanout,
//! PNG export) go through the same address space using 4x4 block-tiled
//! addressing as defined in INT-011.

use gpu_registers::components::z_compare_e::ZCompareE;
use gs_twin_core::math::Rgb565;
use std::path::Path;

// ── Block-tiled addressing (INT-011) ────────────────────────────────────────

/// Compute the SDRAM word address for a pixel at (x, y) in a 4x4
/// block-tiled surface (INT-011).
///
/// # Arguments
///
/// * `base_word` - Surface base address in 16-bit word units.
/// * `width_log2` - Log2 of surface width in pixels (e.g. 9 for 512).
/// * `x` - Pixel column.
/// * `y` - Pixel row.
///
/// # Returns
///
/// The flat word index into `sdram`.
pub fn tiled_word_addr(base_word: usize, width_log2: u8, x: u32, y: u32) -> usize {
    let block_x = (x >> 2) as usize;
    let block_y = (y >> 2) as usize;
    let local_x = (x & 3) as usize;
    let local_y = (y & 3) as usize;
    let block_idx = (block_y << (width_log2 as usize - 2)) | block_x;
    base_word + block_idx * 16 + local_y * 4 + local_x
}

/// Convert a register base field (COLOR_BASE / Z_BASE) to a word address.
///
/// Register encoding: `byte_addr = field_value << 9`, so
/// `word_addr = field_value << 8` (512-byte / 256-word granularity).
fn base_reg_to_word(base_reg: u16) -> usize {
    (base_reg as usize) << 8
}

// ── GPU memory ──────────────────────────────────────────────────────────────

/// Complete GPU memory state.
pub struct GpuMemory {
    /// Flat SDRAM backing store (16-bit words, 32 MiB).
    ///
    /// All framebuffer, Z-buffer, and texture data lives here.
    /// Addressed via 4x4 block-tiled layout (INT-011).
    pub sdram: Vec<u16>,
}

impl Default for GpuMemory {
    fn default() -> Self {
        Self::new()
    }
}

impl GpuMemory {
    /// Total SDRAM size in 16-bit words (32 MiB / 2).
    const SDRAM_WORDS: usize = 32 * 1024 * 1024 / 2;

    /// Create GPU memory with pseudo-random SDRAM contents.
    ///
    /// Real SDRAM powers up with indeterminate contents.
    /// Using a deterministic PRNG ensures reproducible results while
    /// catching any code that reads uninitialized memory.
    pub fn new() -> Self {
        let mut sdram = vec![0u16; Self::SDRAM_WORDS];
        // Simple xorshift32 PRNG — deterministic, fast, good enough
        // for filling uninitialized memory with non-zero garbage.
        let mut state: u32 = 0xDEAD_BEEF;
        for word in &mut sdram {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            *word = state as u16;
        }
        Self { sdram }
    }

    /// Fill a contiguous SDRAM region with a 16-bit constant (MEM_FILL).
    ///
    /// Writes directly to the flat SDRAM backing store.  Independent of
    /// framebuffer configuration — purely an address + value + count
    /// operation matching the RTL fill unit.
    ///
    /// # Arguments
    ///
    /// * `byte_addr` - Start byte address in SDRAM.
    /// * `value` - 16-bit fill value (RGB565 or Z16).
    /// * `count` - Number of 16-bit words to fill.
    pub fn fill(&mut self, byte_addr: usize, value: u16, count: usize) {
        let word_addr = byte_addr / 2;
        let end = (word_addr + count).min(self.sdram.len());
        if word_addr < end {
            self.sdram[word_addr..end].fill(value);
        }
    }

    /// Write a 64-bit dword to flat SDRAM (MEM_DATA).
    ///
    /// Stores four consecutive 16-bit words in little-endian order
    /// starting at `byte_addr`.  This matches the RTL's MEM_DATA
    /// register write path used for texture and data uploads.
    ///
    /// # Arguments
    ///
    /// * `byte_addr` - Start byte address in SDRAM (must be 8-byte aligned
    ///   when originating from MEM_ADDR, but no alignment check is performed).
    /// * `data` - 64-bit value; bits [15:0] go to the lowest address.
    pub fn write_dword(&mut self, byte_addr: usize, data: u64) {
        let word_addr = byte_addr / 2;
        for i in 0..4 {
            let idx = word_addr + i;
            if idx < self.sdram.len() {
                self.sdram[idx] = (data >> (i * 16)) as u16;
            }
        }
    }

    /// Read a 16-bit value from a tiled surface in SDRAM.
    ///
    /// # Arguments
    ///
    /// * `base_reg` - Surface base register field (COLOR_BASE or Z_BASE).
    /// * `width_log2` - Log2 of surface width.
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    pub fn read_tiled(&self, base_reg: u16, width_log2: u8, x: u32, y: u32) -> u16 {
        let addr = tiled_word_addr(base_reg_to_word(base_reg), width_log2, x, y);
        self.sdram[addr]
    }

    /// Write a 16-bit value to a tiled surface in SDRAM.
    ///
    /// # Arguments
    ///
    /// * `base_reg` - Surface base register field (COLOR_BASE or Z_BASE).
    /// * `width_log2` - Log2 of surface width.
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `value` - 16-bit value to write.
    pub fn write_tiled(&mut self, base_reg: u16, width_log2: u8, x: u32, y: u32, value: u16) {
        let addr = tiled_word_addr(base_reg_to_word(base_reg), width_log2, x, y);
        self.sdram[addr] = value;
    }

    /// Unsigned 16-bit Z-test and conditional write in SDRAM.
    ///
    /// Reads the stored Z value at (x, y) from the tiled Z-buffer,
    /// compares with the fragment Z, and writes back if the test passes.
    ///
    /// # Arguments
    ///
    /// * `z_base` - Z_BASE register field.
    /// * `width_log2` - Log2 of surface width.
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `z` - Fragment Z value to test.
    /// * `func` - Comparison function.
    ///
    /// # Returns
    ///
    /// `true` if the fragment passes the depth test.
    pub fn z_test_and_set(
        &mut self,
        z_base: u16,
        width_log2: u8,
        x: u32,
        y: u32,
        z: u16,
        func: ZCompareE,
    ) -> bool {
        let stored = self.read_tiled(z_base, width_log2, x, y);
        let pass = match func {
            ZCompareE::Never => false,
            ZCompareE::Less => z < stored,
            ZCompareE::Lequal => z <= stored,
            ZCompareE::Equal => z == stored,
            ZCompareE::Greater => z > stored,
            ZCompareE::Gequal => z >= stored,
            ZCompareE::Notequal => z != stored,
            ZCompareE::Always => true,
        };
        if pass {
            self.write_tiled(z_base, width_log2, x, y, z);
        }
        pass
    }

    /// Extract a tiled SDRAM region as a linear `Vec<u16>` (row-major).
    ///
    /// Used for exact RGB565 comparison with Verilator dumps.
    ///
    /// # Arguments
    ///
    /// * `base_reg` - Surface base register field (COLOR_BASE).
    /// * `width_log2` - Log2 of surface width.
    /// * `width` - Surface width in pixels.
    /// * `height` - Surface height in pixels.
    pub fn extract_rgb565_linear(
        &self,
        base_reg: u16,
        width_log2: u8,
        width: u32,
        height: u32,
    ) -> Vec<u16> {
        let mut pixels = Vec::with_capacity((width * height) as usize);
        for y in 0..height {
            for x in 0..width {
                pixels.push(self.read_tiled(base_reg, width_log2, x, y));
            }
        }
        pixels
    }

    /// Extract a tiled SDRAM region as an `RgbImage` (RGB565 → RGB888).
    ///
    /// # Arguments
    ///
    /// * `base_reg` - Surface base register field (COLOR_BASE).
    /// * `width_log2` - Log2 of surface width.
    /// * `width` - Surface width in pixels.
    /// * `height` - Surface height in pixels.
    pub fn extract_rgb_image(
        &self,
        base_reg: u16,
        width_log2: u8,
        width: u32,
        height: u32,
    ) -> image::RgbImage {
        let mut img = image::RgbImage::new(width, height);
        for y in 0..height {
            for x in 0..width {
                let raw = self.read_tiled(base_reg, width_log2, x, y);
                let (r, g, b) = Rgb565(raw).to_rgb8();
                img.put_pixel(x, y, image::Rgb([r, g, b]));
            }
        }
        img
    }

    /// Save a tiled SDRAM region as a 24-bit PNG.
    ///
    /// # Arguments
    ///
    /// * `base_reg` - Surface base register field (COLOR_BASE).
    /// * `width_log2` - Log2 of surface width.
    /// * `width` - Surface width in pixels.
    /// * `height` - Surface height in pixels.
    /// * `path` - Output file path.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
    pub fn save_png(
        &self,
        base_reg: u16,
        width_log2: u8,
        width: u32,
        height: u32,
        path: &Path,
    ) -> Result<(), image::ImageError> {
        self.extract_rgb_image(base_reg, width_log2, width, height)
            .save(path)
    }

    /// Save a tiled Z-buffer region as a grayscale PNG with auto-ranging.
    ///
    /// Finds the min/max Z values among written pixels (excluding the
    /// clear value 0x0000) and maps that range to 0–255.
    /// With reverse-Z convention (near = high Z, far = low Z, clear = 0):
    ///   - Near objects appear **white** (high Z → 255).
    ///   - Far objects appear **dark** (low Z → dim).
    ///   - Background (cleared to 0) appears **black**.
    ///
    /// # Arguments
    ///
    /// * `z_base_reg` - Z_BASE register field.
    /// * `width_log2` - Log2 of surface width.
    /// * `width` - Surface width in pixels.
    /// * `height` - Surface height in pixels.
    /// * `path` - Output file path.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
    pub fn save_zbuffer_png(
        &self,
        z_base_reg: u16,
        width_log2: u8,
        width: u32,
        height: u32,
        path: &Path,
    ) -> Result<(), image::ImageError> {
        // First pass: find min/max Z among written pixels.
        let mut z_min: u16 = u16::MAX;
        let mut z_max: u16 = 0;
        let pixels = (0..height).flat_map(|y| (0..width).map(move |x| (x, y)));
        for (x, y) in pixels {
            let z16 = self.read_tiled(z_base_reg, width_log2, x, y);
            if z16 != 0 {
                z_min = z_min.min(z16);
                z_max = z_max.max(z16);
            }
        }

        let range = if z_max > z_min { z_max - z_min } else { 1 };

        // Second pass: render with auto-ranging.
        // Reverse-Z: high Z = near = white, low Z = far = dark, 0 = black.
        let mut img = image::GrayImage::new(width, height);
        let pixels = (0..height).flat_map(|y| (0..width).map(move |x| (x, y)));
        for (x, y) in pixels {
            let z16 = self.read_tiled(z_base_reg, width_log2, x, y);
            let gray = if z16 == 0 {
                0u8
            } else {
                ((z16 - z_min) as u32 * 255 / range as u32) as u8
            };
            img.put_pixel(x, y, image::Luma([gray]));
        }
        img.save(path)
    }
}

/// Load a raw RGB565 framebuffer dump (as produced by Verilator testbench).
///
/// Format: little-endian u16 per pixel, row-major (linear, not tiled).
///
/// # Arguments
///
/// * `path` - Path to the raw dump file.
/// * `width` - Expected framebuffer width in pixels.
/// * `height` - Expected framebuffer height in pixels.
///
/// # Errors
///
/// Returns `std::io::Error` if the file cannot be read.
pub fn load_raw_rgb565(path: &Path, width: u32, height: u32) -> std::io::Result<Vec<u16>> {
    let data = std::fs::read(path)?;
    let expected = (width * height * 2) as usize;
    assert_eq!(
        data.len(),
        expected,
        "raw framebuffer size mismatch: got {}, expected {}",
        data.len(),
        expected
    );
    Ok(data
        .chunks_exact(2)
        .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
        .collect())
}
