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
    pub fn sample(&mut self, _u: Q<4, 12>, _v: Q<4, 12>, _lod: u8, _sdram: &[u16]) -> ColorQ412 {
        // Stub: return opaque white (matching current pipeline behavior)
        ColorQ412::default()
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
