//! GPU memory model.
//!
//! Models the SRAM layout as defined in INT-011. The ECP5-25K has limited
//! block RAM, so the real SRAM is external. This module provides a flat
//! memory model with typed accessors for framebuffer, z-buffer, vertex
//! buffers, and texture storage.

use crate::math::{Depth, Rgb565, TexCoord};
use gpu_registers::components::z_compare_e::ZCompareE;
use std::path::Path;

/// Complete GPU memory state.
pub struct GpuMemory {
    /// RGB565 framebuffer surface.
    pub framebuffer: Framebuffer,

    /// Signed Q4.12 depth buffer (high-level pipeline path).
    pub depth_buffer: DepthBuffer,

    /// Raw unsigned 16-bit Z-buffer for the register-write path.
    ///
    /// The RTL's early_z.sv uses unsigned 16-bit Z values (smaller = nearer).
    /// This is separate from `depth_buffer` (signed Q4.12) used by the
    /// high-level pipeline. Initialized to 0 (all near-plane).
    pub raw_zbuf: RawZBuffer,

    /// Vertex / index SRAM (64 KiB).
    pub vertex_sram: Vec<u8>,

    /// Texture slot storage.
    pub textures: TextureStore,

    /// Flat SDRAM backing store (16-bit words).
    ///
    /// TODO: Replace typed `framebuffer` / `raw_zbuf` with views into this
    /// flat store so that MEM_FILL, pixel writes, and Z-test all operate on
    /// the same address space.
    pub sdram: Vec<u16>,
}

impl GpuMemory {
    /// Total SDRAM size in 16-bit words (32 MiB / 2).
    const SDRAM_WORDS: usize = 32 * 1024 * 1024 / 2;

    /// Create GPU memory with the given framebuffer dimensions.
    ///
    /// # Arguments
    ///
    /// * `width` - Framebuffer width in pixels.
    /// * `height` - Framebuffer height in pixels.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            framebuffer: Framebuffer::new(width, height),
            depth_buffer: DepthBuffer::new(width, height),
            raw_zbuf: RawZBuffer::new(width, height),
            vertex_sram: vec![0u8; 64 * 1024], // 64 KiB vertex/index SRAM
            textures: TextureStore::default(),
            sdram: vec![0u16; Self::SDRAM_WORDS],
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
}

// ── Framebuffer ─────────────────────────────────────────────────────────────

/// RGB565 framebuffer matching the RTL's SRAM framebuffer region.
pub struct Framebuffer {
    /// Width in pixels.
    pub width: u32,

    /// Height in pixels.
    pub height: u32,

    /// Row-major, top-left origin. Each entry is a packed RGB565 pixel.
    pub pixels: Vec<Rgb565>,
}

impl Framebuffer {
    /// Create a zeroed framebuffer.
    ///
    /// # Arguments
    ///
    /// * `width` - Width in pixels.
    /// * `height` - Height in pixels.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            pixels: vec![Rgb565(0); (width * height) as usize],
        }
    }

    /// Write a pixel at (x, y). Out-of-bounds writes are silently ignored.
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `color` - RGB565 color value.
    pub fn put_pixel(&mut self, x: u32, y: u32, color: Rgb565) {
        if x < self.width && y < self.height {
            self.pixels[(y * self.width + x) as usize] = color;
        }
    }

    /// Read a pixel at (x, y). Returns black for out-of-bounds coordinates.
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    ///
    /// # Returns
    ///
    /// The RGB565 pixel value, or `Rgb565(0)` if out of bounds.
    pub fn get_pixel(&self, x: u32, y: u32) -> Rgb565 {
        if x < self.width && y < self.height {
            self.pixels[(y * self.width + x) as usize]
        } else {
            Rgb565(0)
        }
    }

    /// Fill the entire framebuffer with a single color.
    ///
    /// # Arguments
    ///
    /// * `color` - RGB565 fill value.
    pub fn clear(&mut self, color: Rgb565) {
        self.pixels.fill(color);
    }

    /// Export as a 24-bit PNG (expanding RGB565 to RGB8).
    ///
    /// # Arguments
    ///
    /// * `path` - Output file path.
    ///
    /// # Errors
    ///
    /// Returns `image::ImageError` if the PNG cannot be written.
    pub fn save_png(&self, path: &Path) -> Result<(), image::ImageError> {
        let mut img = image::RgbImage::new(self.width, self.height);
        for y in 0..self.height {
            for x in 0..self.width {
                let (r, g, b) = self.get_pixel(x, y).to_rgb8();
                img.put_pixel(x, y, image::Rgb([r, g, b]));
            }
        }
        img.save(path)
    }

    /// Load a raw RGB565 framebuffer dump (as produced by Verilator testbench).
    ///
    /// Format: little-endian u16 per pixel, row-major.
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
    pub fn load_raw_rgb565(path: &Path, width: u32, height: u32) -> std::io::Result<Self> {
        let data = std::fs::read(path)?;
        let expected = (width * height * 2) as usize;
        assert_eq!(
            data.len(),
            expected,
            "raw framebuffer size mismatch: got {}, expected {}",
            data.len(),
            expected
        );
        let pixels: Vec<Rgb565> = data
            .chunks_exact(2)
            .map(|chunk| Rgb565(u16::from_le_bytes([chunk[0], chunk[1]])))
            .collect();
        Ok(Self {
            width,
            height,
            pixels,
        })
    }
}

// ── Depth buffer ────────────────────────────────────────────────────────────

/// 16-bit depth buffer using Q4.12 fixed-point values.
///
/// # RTL Implementation Notes
///
/// The Z-buffer occupies a contiguous SRAM region, one 16-bit word per
/// pixel. The depth comparison is a signed 16-bit comparison on the
/// raw Q4.12 bits, which is equivalent to comparing the fixed-point
/// values directly since Q4.12 uses two's complement.
pub struct DepthBuffer {
    /// Width in pixels.
    pub width: u32,

    /// Height in pixels.
    pub height: u32,

    /// Per-pixel depth values. Cleared to MAX (far plane).
    pub values: Vec<Depth>,
}

impl DepthBuffer {
    /// Create a depth buffer cleared to far plane (MAX).
    ///
    /// # Arguments
    ///
    /// * `width` - Width in pixels.
    /// * `height` - Height in pixels.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            values: vec![Depth::MAX; (width * height) as usize],
        }
    }

    /// Clear all pixels to a raw 16-bit depth value.
    ///
    /// # Arguments
    ///
    /// * `raw_value` - Raw u16 interpreted as signed Q4.12.
    pub fn clear_raw(&mut self, raw_value: u16) {
        let depth = Depth::from_bits(raw_value as i16 as i64);
        self.values.fill(depth);
    }

    /// Read the stored depth at (x, y).
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    pub fn get(&self, x: u32, y: u32) -> Depth {
        self.values[(y * self.width + x) as usize]
    }

    /// Write a depth value at (x, y).
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `value` - Q4.12 depth value.
    pub fn set(&mut self, x: u32, y: u32, value: Depth) {
        self.values[(y * self.width + x) as usize] = value;
    }

    /// Depth test: returns true if the fragment passes (and updates the buffer).
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `depth` - Fragment depth to test.
    /// * `func` - Comparison function.
    ///
    /// # Returns
    ///
    /// `true` if the fragment passes the depth test.
    ///
    /// # RTL Implementation Notes
    ///
    /// This is a single SRAM read (current depth) -> compare -> conditional
    /// SRAM write (new depth). The comparison operates on the raw i16
    /// representation of Q4.12 values.
    pub fn test_and_set(&mut self, x: u32, y: u32, depth: Depth, func: ZCompareE) -> bool {
        let stored = self.get(x, y);
        let pass = match func {
            ZCompareE::Never => false,
            ZCompareE::Less => depth < stored,
            ZCompareE::Lequal => depth <= stored,
            ZCompareE::Equal => depth == stored,
            ZCompareE::Greater => depth > stored,
            ZCompareE::Gequal => depth >= stored,
            ZCompareE::Notequal => depth != stored,
            ZCompareE::Always => true,
        };
        if pass {
            self.set(x, y, depth);
        }
        pass
    }
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

// ── Raw Z-buffer (unsigned 16-bit, for register-write path) ──────────────

/// Unsigned 16-bit Z-buffer matching the RTL's early_z.sv.
///
/// Smaller values are nearer. The RTL performs unsigned comparison on
/// raw 16-bit Z values from the rasterizer.
pub struct RawZBuffer {
    /// Width in pixels.
    pub width: u32,

    /// Height in pixels.
    pub height: u32,

    /// Per-pixel Z values. Initialized to 0.
    pub values: Vec<u16>,
}

impl RawZBuffer {
    /// Create a Z-buffer initialized to zero.
    ///
    /// # Arguments
    ///
    /// * `width` - Width in pixels.
    /// * `height` - Height in pixels.
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            values: vec![0u16; (width * height) as usize],
        }
    }

    /// Fill the entire Z-buffer with a constant value.
    ///
    /// # Arguments
    ///
    /// * `value` - Raw u16 Z value to fill with.
    pub fn clear(&mut self, value: u16) {
        self.values.fill(value);
    }

    /// Read the stored Z value at (x, y).
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    pub fn get(&self, x: u32, y: u32) -> u16 {
        self.values[(y * self.width + x) as usize]
    }

    /// Write a Z value at (x, y).
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `value` - Raw u16 Z value.
    pub fn set(&mut self, x: u32, y: u32, value: u16) {
        self.values[(y * self.width + x) as usize] = value;
    }

    /// Depth test + conditional write.
    ///
    /// # Arguments
    ///
    /// * `x` - Pixel column.
    /// * `y` - Pixel row.
    /// * `z` - Fragment Z value to test.
    /// * `func` - Comparison function.
    ///
    /// # Returns
    ///
    /// `true` if the fragment passes the depth test.
    pub fn test_and_set(&mut self, x: u32, y: u32, z: u16, func: ZCompareE) -> bool {
        let stored = self.get(x, y);
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
            self.set(x, y, z);
        }
        pass
    }
}
