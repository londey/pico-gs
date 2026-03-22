//! Display scanout pipeline — color grading, horizontal scaling, output.
//!
//! Models the display controller (UNIT-008) scanout path from
//! ARCHITECTURE.md lines 114–124.
//! In the DT, this is triggered by FB_DISPLAY register write to produce
//! a 640×480 RGB888 output image.
//!
//! # Pipeline stages
//!
//! 1. **Scanline Prefetch** — burst-read scanlines from SDRAM
//!    (modeled as tiled SDRAM access in the DT).
//! 2. **Color Grade LUT** — per-channel lookup: R (32-entry, 5→8 bit),
//!    G (64-entry, 6→8 bit), B (32-entry, 5→8 bit).
//!    Maps RGB565 to RGB888.
//! 3. **Horizontal Scale** — nearest-neighbor stretch to 640 pixels
//!    using Bresenham-style accumulator.
//! 4. **DVI TMDS Encode** — not modeled in the DT.
//!
//! # Display modes (ARCHITECTURE.md)
//!
//! | Source | H Scale | V Mode | Use case |
//! |--------|---------|--------|----------|
//! | 512×480 | 512→640 (4:5) | 1:1 | Default rendering |
//! | 256×240 | 256→640 (2:5) | Line double | Half-resolution / retro |

use gs_memory::GpuMemory;
use gs_twin_core::math::Rgb565;
use image::RgbImage;

/// Display output dimensions.
pub const DISPLAY_WIDTH: u32 = 640;

/// Display output height.
pub const DISPLAY_HEIGHT: u32 = 480;

/// Color grading lookup tables (RGB565 → RGB888).
///
/// Three per-channel 1D tables producing RGB888 output.
/// See REQ-006.03 and ARCHITECTURE.md.
///
/// The LUT is double-buffered in EBR and auto-loaded from SDRAM
/// via DMA during vblank in the RTL.
pub struct ColorGradeLut {
    /// Red channel LUT: 5-bit index (0..31) → 8-bit output.
    pub r: [u8; 32],

    /// Green channel LUT: 6-bit index (0..63) → 8-bit output.
    pub g: [u8; 64],

    /// Blue channel LUT: 5-bit index (0..31) → 8-bit output.
    pub b: [u8; 32],
}

impl Default for ColorGradeLut {
    /// Identity LUT: bit-replicate each channel to 8 bits.
    ///
    /// R/B: 5-bit → 8-bit via `(val << 3) | (val >> 2)`.
    /// G: 6-bit → 8-bit via `(val << 2) | (val >> 4)`.
    fn default() -> Self {
        let mut r = [0u8; 32];
        let mut g = [0u8; 64];
        let mut b = [0u8; 32];

        for (i, slot) in r.iter_mut().enumerate() {
            *slot = ((i << 3) | (i >> 2)) as u8;
        }
        for (i, slot) in b.iter_mut().enumerate() {
            *slot = ((i << 3) | (i >> 2)) as u8;
        }
        for (i, slot) in g.iter_mut().enumerate() {
            *slot = ((i << 2) | (i >> 4)) as u8;
        }

        Self { r, g, b }
    }
}

impl ColorGradeLut {
    /// Apply the LUT to a single RGB565 pixel.
    ///
    /// # Arguments
    ///
    /// * `pixel` - Raw RGB565 value.
    ///
    /// # Returns
    ///
    /// `[R, G, B]` in 8-bit per channel.
    pub fn apply(&self, pixel: Rgb565) -> [u8; 3] {
        let r5 = ((pixel.0 >> 11) & 0x1F) as usize;
        let g6 = ((pixel.0 >> 5) & 0x3F) as usize;
        let b5 = (pixel.0 & 0x1F) as usize;

        [self.r[r5], self.g[g6], self.b[b5]]
    }
}

/// Display output configuration latched from FB_DISPLAY register.
///
/// `FB_DISPLAY` latches `FB_WIDTH_LOG2` and `LINE_DOUBLE` atomically
/// at VSYNC, independent of `FB_CONFIG`.
#[derive(Debug, Clone, Copy)]
pub struct DisplayConfig {
    /// Source framebuffer width as log2 (e.g. 9 = 512, 8 = 256).
    pub fb_width_log2: u8,

    /// Line doubling mode (each source row output twice for 256×240).
    pub line_double: bool,
}

impl Default for DisplayConfig {
    /// Default: 512×480 mode (no line doubling).
    fn default() -> Self {
        Self {
            fb_width_log2: 9,
            line_double: false,
        }
    }
}

/// Produce a 640×480 RGB888 output image from SDRAM.
///
/// Reads pixels from a tiled surface in SDRAM, applies color grading
/// LUT (RGB565 → RGB888), then nearest-neighbor horizontal scaling
/// via Bresenham accumulator.
///
/// # Arguments
///
/// * `memory` - GPU memory (SDRAM backing store).
/// * `base_reg` - COLOR_BASE register field for the display framebuffer.
/// * `lut` - Color grading lookup tables.
/// * `config` - Display configuration (width, line doubling).
///
/// # Returns
///
/// A 640×480 `RgbImage` ready for PNG export or comparison.
pub fn scanout(
    memory: &GpuMemory,
    base_reg: u16,
    lut: &ColorGradeLut,
    config: &DisplayConfig,
) -> RgbImage {
    let src_width = 1u32 << config.fb_width_log2;
    let mut img = RgbImage::new(DISPLAY_WIDTH, DISPLAY_HEIGHT);

    for dst_y in 0..DISPLAY_HEIGHT {
        // Vertical: map destination row to source row
        let src_y = if config.line_double { dst_y / 2 } else { dst_y };

        // Horizontal: nearest-neighbor scaling via Bresenham accumulator
        // Ratio: src_width → DISPLAY_WIDTH
        for dst_x in 0..DISPLAY_WIDTH {
            // Bresenham: src_x = dst_x * src_width / DISPLAY_WIDTH
            let src_x = (dst_x as u64 * src_width as u64 / DISPLAY_WIDTH as u64) as u32;

            let raw = memory.read_tiled(base_reg, config.fb_width_log2, src_x, src_y);
            let [r, g, b] = lut.apply(Rgb565(raw));
            img.put_pixel(dst_x, dst_y, image::Rgb([r, g, b]));
        }
    }

    img
}
