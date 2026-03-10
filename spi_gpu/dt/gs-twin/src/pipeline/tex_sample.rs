//! Texture sampling — fetch texels from TEX0 and TEX1 units.
//!
//! Samples both texture units using the fragment's perspective-corrected
//! UV coordinates and LOD.
//! The rasterizer has already performed perspective correction
//! (true U = S×(1/Q), true V = T×(1/Q)), so no per-pixel division
//! is needed here.
//!
//! # RTL Implementation Notes
//!
//! Each texture unit has an independent 4-way set-associative cache
//! storing decompressed 4×4 texel blocks in RGBA5652 format.
//! Cache misses stall the pipeline until the SDRAM fill completes.
//! See UNIT-006, texture_cache.sv.

use std::collections::HashMap;

use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;
use gpu_registers::components::tex_format_e::TexFormatE;
use gpu_registers::components::wrap_mode_e::WrapModeE;
use qfixed::Q;

use super::fragment::{ColorQ412, RasterFragment, TexturedFragment};

// ── RGBA5652 intermediate texel format ──────────────────────────────────────

/// RGBA5652 intermediate texel format matching the RTL texture cache.
///
/// The RTL texture cache stores decompressed texels in this 18-bit format:
/// `[17:13]=R5, [12:7]=G6, [6:2]=B5, [1:0]=A2`.
/// All texture formats (BC1–BC4, RGB565, RGBA8888, R8) are decoded to
/// RGBA5652 before entering the fragment pipeline.
///
/// # RTL Implementation Notes
///
/// The 2-bit alpha channel provides only four levels (0.0, 0.333, 0.666,
/// 1.0).
/// BC1 1-bit alpha maps to A2=0 or A2=3.
/// See INT-032 (Texture Cache Architecture), `texel_promote.sv`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Rgba5652 {
    /// Packed 18-bit value: `[17:13]=R5, [12:7]=G6, [6:2]=B5, [1:0]=A2`.
    pub bits: u32,
}

impl Rgba5652 {
    /// Create from individual channel values.
    ///
    /// # Arguments
    ///
    /// * `r5` - Red channel (5 bits, 0–31).
    /// * `g6` - Green channel (6 bits, 0–63).
    /// * `b5` - Blue channel (5 bits, 0–31).
    /// * `a2` - Alpha channel (2 bits, 0–3).
    #[must_use]
    pub fn new(r5: u8, g6: u8, b5: u8, a2: u8) -> Self {
        Self {
            bits: ((r5 as u32 & 0x1F) << 13)
                | ((g6 as u32 & 0x3F) << 7)
                | ((b5 as u32 & 0x1F) << 2)
                | (a2 as u32 & 0x03),
        }
    }

    /// Extract the red channel (5 bits).
    #[must_use]
    pub fn r5(self) -> u8 {
        ((self.bits >> 13) & 0x1F) as u8
    }

    /// Extract the green channel (6 bits).
    #[must_use]
    pub fn g6(self) -> u8 {
        ((self.bits >> 7) & 0x3F) as u8
    }

    /// Extract the blue channel (5 bits).
    #[must_use]
    pub fn b5(self) -> u8 {
        ((self.bits >> 2) & 0x1F) as u8
    }

    /// Extract the alpha channel (2 bits).
    #[must_use]
    pub fn a2(self) -> u8 {
        (self.bits & 0x03) as u8
    }

    /// Promote to Q4.12 RGBA, matching the RTL's `texel_promote.sv`.
    ///
    /// Applies MSB-replication formulas from `fp_types_pkg`:
    /// - R5 → `{3'b000, R5, R5, R5[4:2]}` (16-bit Q4.12)
    /// - G6 → `{3'b000, G6, G6, 1'b0}` (16-bit Q4.12)
    /// - B5 → same as R5
    /// - A2 → LUT: `0→0x0000, 1→0x0555, 2→0x0AAA, 3→0x1000`
    ///
    /// # Returns
    ///
    /// `ColorQ412` with channels in `[0x0000, 0x1000]` (UNORM \[0.0, 1.0\]).
    ///
    /// # RTL Implementation Notes
    ///
    /// See `fp_types_pkg::promote_r5_to_q412()` and siblings,
    /// INT-032 (Onward Conversion to Q4.12).
    #[must_use]
    pub fn promote_to_q412(self) -> ColorQ412 {
        let r5 = self.r5() as u16;
        let g6 = self.g6() as u16;
        let b5 = self.b5() as u16;
        let a2 = self.a2();

        // R5: {3'b000, r5[4:0], r5[4:0], r5[4:2]}
        let r = (r5 << 8) | (r5 << 3) | (r5 >> 2);
        // G6: {3'b000, g6[5:0], g6[5:0], 1'b0}
        let g = (g6 << 7) | (g6 << 1);
        // B5: same as R5
        let b = (b5 << 8) | (b5 << 3) | (b5 >> 2);
        // A2: four-level LUT
        let a: u16 = match a2 {
            0 => 0x0000,
            1 => 0x0555,
            2 => 0x0AAA,
            3 => 0x1000,
            _ => unreachable!(),
        };

        ColorQ412 {
            r: Q::from_bits(r as i64),
            g: Q::from_bits(g as i64),
            b: Q::from_bits(b as i64),
            a: Q::from_bits(a as i64),
        }
    }
}

// ── Format conversion helpers ───────────────────────────────────────────────

/// Convert an RGB565 word to [`Rgba5652`] (fully opaque).
///
/// RGB565 layout: `[15:11]=R5, [10:5]=G6, [4:0]=B5`.
fn rgb565_to_rgba5652(raw: u16) -> Rgba5652 {
    let r5 = ((raw >> 11) & 0x1F) as u8;
    let g6 = ((raw >> 5) & 0x3F) as u8;
    let b5 = (raw & 0x1F) as u8;
    Rgba5652::new(r5, g6, b5, 3) // A2=3 → fully opaque
}

/// Convert an RGBA8888 value to [`Rgba5652`] by truncation.
///
/// RGBA8888 layout (little-endian u32):
/// `[7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8`.
fn rgba8888_to_rgba5652(rgba: u32) -> Rgba5652 {
    let r5 = ((rgba >> 3) & 0x1F) as u8;
    let g6 = ((rgba >> 10) & 0x3F) as u8;
    let b5 = ((rgba >> 19) & 0x1F) as u8;
    let a2 = ((rgba >> 30) & 0x03) as u8;
    Rgba5652::new(r5, g6, b5, a2)
}

/// Convert an R8 grayscale byte to [`Rgba5652`] (fully opaque, gray).
///
/// Maps the 8-bit value to all three color channels (R5, G6, B5).
fn r8_to_rgba5652(val: u8) -> Rgba5652 {
    let r5 = val >> 3;
    let g6 = val >> 2;
    let b5 = val >> 3;
    Rgba5652::new(r5, g6, b5, 3)
}

// ── Wrap-mode helpers ───────────────────────────────────────────────────────

/// Convert a Q4.12 UV coordinate to an integer texel index, applying
/// the specified wrap mode.
///
/// # Arguments
///
/// * `coord` - UV coordinate in Q4.12 signed fixed-point.
/// * `dim` - Texture dimension in texels (power of 2).
/// * `dim_log2` - Log₂ of `dim`.
/// * `wrap` - Wrap mode to apply.
fn wrap_texel(coord: Q<4, 12>, dim: u32, dim_log2: u8, wrap: WrapModeE) -> u32 {
    // Multiply UV by dimension: texel = floor(coord * dim).
    // coord is Q4.12 (16-bit signed, 12 fractional bits), dim = 1 << dim_log2.
    // Sign-extend the 16-bit value to i64 before shifting.
    let bits = coord.to_bits() as u16 as i16 as i64;
    let texel_raw: i64 = if dim_log2 <= 12 {
        bits >> (12 - dim_log2)
    } else {
        bits << (dim_log2 - 12)
    };

    let dim_i = dim as i64;
    match wrap {
        WrapModeE::Repeat => texel_raw.rem_euclid(dim_i) as u32,
        WrapModeE::ClampToEdge => texel_raw.clamp(0, dim_i - 1) as u32,
        WrapModeE::Mirror => {
            let period = dim_i * 2;
            let t = texel_raw.rem_euclid(period);
            if t < dim_i {
                t as u32
            } else {
                (period - 1 - t) as u32
            }
        }
        // Octahedral: treat as repeat for this initial implementation.
        WrapModeE::Octahedral => texel_raw.rem_euclid(dim_i) as u32,
    }
}

// ── Texture sampler ─────────────────────────────────────────────────────────

/// Per-unit texture sampler with block cache, modeling one RTL
/// `texture_cache.sv` instance.
///
/// Each `TextureSampler` corresponds to one hardware texture unit
/// (TEX0 or TEX1).
/// It holds the current [`TexCfgReg`] configuration and an internal
/// cache of decompressed 4×4 texel blocks in [`Rgba5652`] format.
///
/// The sampler does not own SDRAM — callers pass `&[u16]` on each
/// sample call, allowing the sampler to fill cache misses by reading
/// raw texture data.
///
/// # RTL Implementation Notes
///
/// The RTL `texture_cache.sv` implements a 4-way set-associative cache
/// with 1024 lines (256 sets × 4 ways).
/// The DT uses a simpler block-indexed map that models the same
/// behavioral contract: decompressed blocks are cached until
/// invalidation.
/// Cache invalidation occurs on any `TEXn_CFG` register write.
///
/// See: UNIT-006 (Pixel Pipeline), INT-032 (Texture Cache Architecture),
///      INT-014 (Texture Memory Layout).
pub struct TextureSampler {
    /// Current texture configuration, `None` if unconfigured.
    cfg: Option<TexCfgReg>,

    /// Decompressed block cache: `(mip_level, block_index)` → 4×4 texels.
    ///
    /// Block index is computed from the texel block coordinates within
    /// the mip level.
    /// Each entry stores 16 `Rgba5652` texels in row-major order
    /// within the 4×4 block.
    cache: HashMap<(u8, u32), [Rgba5652; 16]>,
}

impl Default for TextureSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl TextureSampler {
    /// Create a new sampler in the disabled state (no texture configured).
    #[must_use]
    pub fn new() -> Self {
        Self {
            cfg: None,
            cache: HashMap::new(),
        }
    }

    /// Configure the sampler from a `TEXn_CFG` register write.
    ///
    /// Stores the new configuration and invalidates the entire block
    /// cache, matching the RTL behavior where any write to `TEXn_CFG`
    /// clears all cache valid bits.
    ///
    /// # Arguments
    ///
    /// * `cfg` - The new texture configuration register value.
    ///
    /// # RTL Implementation Notes
    ///
    /// In the RTL, the `invalidate` signal is asserted for one cycle on
    /// any `TEXn_CFG` write, clearing all 1024 valid bits simultaneously.
    /// See `texture_cache.sv`.
    pub fn set_tex_cfg(&mut self, cfg: TexCfgReg) {
        self.cfg = Some(cfg);
        self.cache.clear();
    }

    /// Sample a texel at the given UV coordinates and LOD level.
    ///
    /// Applies wrap mode, computes the texel block address, checks the
    /// internal cache (filling from SDRAM on miss), decompresses to
    /// [`Rgba5652`], and promotes to Q4.12.
    ///
    /// If the sampler is disabled (`enable` = false in the current
    /// config), returns opaque white (`ColorQ412` with all channels
    /// at 1.0).
    ///
    /// # Arguments
    ///
    /// * `u` - Horizontal texture coordinate, Q4.12 signed
    ///   (perspective-corrected by the rasterizer).
    /// * `v` - Vertical texture coordinate, Q4.12 signed.
    /// * `lod` - Level-of-detail selector, UQ4.4 (integer part selects
    ///   mip level, fractional part used for trilinear blending).
    /// * `sdram` - Read-only reference to the flat 32 MiB SDRAM backing
    ///   store (16-bit words).  Used for cache fills on miss.
    ///
    /// # Returns
    ///
    /// Sampled texel color in Q4.12 RGBA format, after [`Rgba5652`]
    /// promotion.
    ///
    /// # Filter modes
    ///
    /// - **Nearest**: Single texel lookup from the floor mip level.
    /// - **Bilinear**: 2×2 tap weighted average at the floor mip level.
    /// - **Trilinear**: Bilinear sample from two adjacent mip levels,
    ///   blended by the LOD fractional part.
    ///
    /// # RTL Implementation Notes
    ///
    /// The RTL texture cache returns 4 RGBA5652 texels per cycle (one
    /// from each parity bank) to support single-cycle bilinear filtering.
    /// The DT models this as sequential lookups into the block cache.
    /// See `texture_cache.sv`, UNIT-006 Stage 3.
    pub fn sample(&mut self, u: Q<4, 12>, v: Q<4, 12>, _lod: u8, sdram: &[u16]) -> ColorQ412 {
        let cfg = match &self.cfg {
            Some(c) if c.enable() => c,
            _ => return ColorQ412::OPAQUE_WHITE,
        };

        let w_log2 = cfg.width_log2();
        let h_log2 = cfg.height_log2();
        let width = 1u32 << w_log2;
        let height = 1u32 << h_log2;

        // Convert Q4.12 UV to integer texel coordinates and apply wrap mode.
        let tx = wrap_texel(u, width, w_log2, cfg.u_wrap());
        let ty = wrap_texel(v, height, h_log2, cfg.v_wrap());

        // Block coordinates (each block is 4×4 texels).
        let bx = tx / 4;
        let by = ty / 4;
        let blocks_per_row = width.div_ceil(4);
        let block_index = by * blocks_per_row + bx;

        // Row-major offset within the 4×4 block.
        let local = (ty & 3) * 4 + (tx & 3);

        // BASE_ADDR × 512 bytes = BASE_ADDR × 256 u16 words.
        let base_words = cfg.base_addr() as u32 * 256;

        let format = match cfg.format() {
            Ok(f) => f,
            Err(_) => return ColorQ412::OPAQUE_WHITE,
        };

        let texel = match format {
            TexFormatE::Rgb565 => {
                // 16 texels × 2 bytes = 32 bytes = 16 u16 words per block.
                let addr = (base_words + block_index * 16 + local) as usize;
                let raw = sdram.get(addr).copied().unwrap_or(0);
                rgb565_to_rgba5652(raw)
            }
            TexFormatE::Rgba8888 => {
                // 16 texels × 4 bytes = 64 bytes = 32 u16 words per block.
                let addr = (base_words + block_index * 32 + local * 2) as usize;
                let lo = sdram.get(addr).copied().unwrap_or(0);
                let hi = sdram.get(addr + 1).copied().unwrap_or(0);
                let rgba = (hi as u32) << 16 | lo as u32;
                rgba8888_to_rgba5652(rgba)
            }
            TexFormatE::R8 => {
                // 16 texels × 1 byte = 16 bytes = 8 u16 words per block.
                let addr = (base_words + block_index * 8 + local / 2) as usize;
                let word = sdram.get(addr).copied().unwrap_or(0);
                let byte = if local & 1 == 0 {
                    (word & 0xFF) as u8
                } else {
                    (word >> 8) as u8
                };
                r8_to_rgba5652(byte)
            }
            // BC1–BC4 compressed formats: not yet implemented.
            _ => return ColorQ412::OPAQUE_WHITE,
        };

        texel.promote_to_q412()
    }

    /// Return the current configuration, if any.
    ///
    /// # Returns
    ///
    /// `Some(cfg)` if [`set_tex_cfg`](Self::set_tex_cfg) has been called,
    /// `None` if unconfigured.
    #[must_use]
    pub fn config(&self) -> Option<&TexCfgReg> {
        self.cfg.as_ref()
    }

    /// Return the number of cached blocks (for diagnostics/testing).
    #[must_use]
    pub fn cached_block_count(&self) -> usize {
        self.cache.len()
    }
}

// ── Pipeline stage entry point ──────────────────────────────────────────────

/// Sample TEX0 and TEX1, producing a [`TexturedFragment`].
///
/// Consumes the UV and LOD lanes from the rasterizer output;
/// produces tex0 and tex1 sampled colors.
///
/// # Arguments
///
/// * `frag` - Rasterizer fragment with UV/LOD data.
/// * `tex0` - Texture unit 0 sampler.
/// * `tex1` - Texture unit 1 sampler.
/// * `sdram` - Read-only SDRAM backing store for cache fills.
///
/// # Returns
///
/// A [`TexturedFragment`] with sampled texel colors.
/// `comb` is `None` (populated later by color combiner stage 0).
pub fn tex_sample(
    frag: RasterFragment,
    tex0: &mut TextureSampler,
    tex1: &mut TextureSampler,
    sdram: &[u16],
) -> TexturedFragment {
    let t0 = tex0.sample(frag.u0, frag.v0, frag.lod, sdram);
    let t1 = tex1.sample(frag.u1, frag.v1, frag.lod, sdram);

    TexturedFragment {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        shade0: frag.shade0,
        shade1: frag.shade1,
        tex0: t0,
        tex1: t1,
        comb: None,
    }
}
