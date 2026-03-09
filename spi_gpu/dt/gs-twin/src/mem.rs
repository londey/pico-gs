//! GPU memory model.
//!
//! Models the full 32 MiB SDRAM as a flat `Vec<u16>` backing store.
//! All memory operations (MEM_FILL, pixel writes, Z-test, display scanout,
//! PNG export) go through the same address space using 4x4 block-tiled
//! addressing as defined in INT-011.

use crate::math::{Rgb565, TexCoord};
use gpu_registers::components::z_compare_e::ZCompareE;
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

    /// Vertex / index SRAM (64 KiB).
    pub vertex_sram: Vec<u8>,

    /// Texture slot storage.
    pub textures: TextureStore,
}

impl Default for GpuMemory {
    fn default() -> Self {
        Self::new()
    }
}

impl GpuMemory {
    /// Total SDRAM size in 16-bit words (32 MiB / 2).
    const SDRAM_WORDS: usize = 32 * 1024 * 1024 / 2;

    /// Create GPU memory with zeroed 32 MiB SDRAM.
    pub fn new() -> Self {
        Self {
            sdram: vec![0u16; Self::SDRAM_WORDS],
            vertex_sram: vec![0u8; 64 * 1024],
            textures: TextureStore::default(),
        }
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

// ── Texture store ───────────────────────────────────────────────────────────

/// Simple texture slot storage. Mirrors the RTL's texture SRAM region.
#[derive(Default)]
pub struct TextureStore {
    /// Up to 16 texture slots (indexed by texture unit).
    pub slots: [Option<Texture>; 16],
}

/// A single texture in GPU memory.
pub struct Texture {
    /// Texture width in texels.
    pub width: u16,

    /// Texture height in texels.
    pub height: u16,

    /// RGB565 texel data, row-major.
    pub data: Vec<u16>,
}

impl TextureStore {
    /// Sample a texture with nearest-neighbor filtering.
    ///
    /// # Arguments
    ///
    /// * `slot` - Texture slot index (0..15).
    /// * `u` - Horizontal texture coordinate (Q2.14).
    /// * `v` - Vertical texture coordinate (Q2.14).
    ///
    /// # Returns
    ///
    /// Sampled RGB565 texel color, or white if no texture is bound.
    ///
    /// # Numeric Behavior
    ///
    /// - Input UVs: Q2.14, wrapping to [0, 1) by masking off the integer bits
    /// - Texel address: `floor(u_frac * width)`, `floor(v_frac * height)`
    /// - No filtering (nearest-neighbor only, matching RTL)
    ///
    /// # RTL Implementation Notes
    ///
    /// UV wrapping is a bitmask on the 14 fractional bits. The texel
    /// address computation is a multiply of the fractional UV by the
    /// texture dimension (power-of-two only in v1.0, so this becomes
    /// a shift). Non-power-of-two textures require a full multiply.
    pub fn sample_nearest(&self, slot: u8, u: TexCoord, v: TexCoord) -> Rgb565 {
        let Some(tex) = &self.slots[slot as usize] else {
            return Rgb565(0xFFFF); // white if no texture bound
        };

        // Wrap to [0, 1): mask off integer bits, keep 14 fractional bits
        let u_frac = (u.to_bits() as i16) & 0x3FFF; // 14-bit fractional part
        let v_frac = (v.to_bits() as i16) & 0x3FFF;

        // Texel address: (frac * dimension) >> 14
        // This is a Q0.14 * u16 multiply, yielding the integer texel index.
        let tx = ((u_frac as u32 * tex.width as u32) >> 14) as u16 % tex.width;
        let ty = ((v_frac as u32 * tex.height as u32) >> 14) as u16 % tex.height;

        Rgb565(tex.data[(ty as usize) * (tex.width as usize) + (tx as usize)])
    }
}
