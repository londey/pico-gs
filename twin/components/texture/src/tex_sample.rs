//! Texture sampling — fetch texels from TEX0 and TEX1 units.
//!
//! This module provides the [`TextureSampler`] facade and the
//! [`TrilinearBlender`] trait.
//! The sampler owns the full texture pipeline stack (fetcher, filter,
//! blender) and presents a simple `sample(u, v, lod)` interface to
//! the fragment pipeline.
//!
//! # Layer stack (owned by `TextureSampler`)
//!
//! ```text
//! TrilinearBlender (this module)
//!   → SampleGatherer + BilinearBlender (tex_filter)
//!     → BlockFetcher (tex_fetch)
//!       → DecodedBlockProvider (tex_cache) + CompressedBlockProvider (tex_compressed)
//!         → TexelDecoder (tex_decode)
//! ```
//!
//! # RTL Implementation Notes
//!
//! Each texture unit has an independent 4-way set-associative cache
//! storing decompressed 4×4 texel blocks in UQ1.8 RGBA format
//! (9 bits per channel, 36 bits per texel) using PDPW16KD EBR banks
//! in 512×36 mode.
//! Cache misses stall the pipeline until the SDRAM fill completes.
//! See UNIT-006, texture_cache.sv.

use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;
use qfixed::Q;

use gs_tex_bilinear_filter::{BilinearBlender, SampleGatherer, StandardBlender, StandardGatherer};
use gs_tex_block_decoder::tex_fetch::{BlockFetcher, ConcreteFetcher};
use gs_tex_l1_cache::CacheStats;
use gs_tex_l2_cache::L2CacheStats;
use gs_twin_core::fragment::{ColorQ412, RasterFragment, TexturedFragment};
pub use gs_twin_core::texel::TexelUq18;

// ── TrilinearBlender trait ──────────────────────────────────────────────────

/// Top-level texture sampling trait.
///
/// Implements trilinear filtering as a blend of two bilinear samples
/// at adjacent mip levels (not yet fully implemented — currently falls
/// back to bilinear).
pub trait TrilinearBlender {
    /// Sample a texel at the given UV coordinates and LOD level.
    ///
    /// # Arguments
    ///
    /// * `u` - Horizontal texture coordinate, Q4.12 signed.
    /// * `v` - Vertical texture coordinate, Q4.12 signed.
    /// * `lod` - Level-of-detail selector, UQ4.4.
    /// * `sdram` - SDRAM backing store.
    ///
    /// # Returns
    ///
    /// Sampled texel color in Q4.12 RGBA format.
    fn sample(&mut self, u: Q<4, 12>, v: Q<4, 12>, lod: u8, sdram: &[u16]) -> ColorQ412;
}

// ── TextureSampler facade ───────────────────────────────────────────────────

/// Per-unit texture sampler owning the full pipeline stack.
///
/// Each `TextureSampler` corresponds to one hardware texture unit
/// (TEX0 or TEX1).
/// It holds the current [`TexCfgReg`] configuration and delegates
/// to the block fetcher, sample gatherer, and bilinear blender.
///
/// See: UNIT-006 (Pixel Pipeline), UNIT-011 (Texture Sampler),
///      INT-014 (Texture Memory Layout).
pub struct TextureSampler {
    /// Current texture configuration, `None` if unconfigured.
    cfg: Option<TexCfgReg>,

    /// Block fetcher owning decoded + compressed caches.
    fetcher: ConcreteFetcher,

    /// Sample gatherer (wrap + tap computation).
    gatherer: StandardGatherer,

    /// Bilinear blender.
    blender: StandardBlender,
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
            fetcher: ConcreteFetcher::new(),
            gatherer: StandardGatherer,
            blender: StandardBlender,
        }
    }

    /// Configure the sampler from a `TEXn_CFG` register write.
    ///
    /// Stores the new configuration and invalidates all caches,
    /// matching the RTL behavior where any write to `TEXn_CFG`
    /// clears all cache valid bits.
    pub fn set_tex_cfg(&mut self, cfg: TexCfgReg) {
        self.cfg = Some(cfg);
        self.fetcher.invalidate();
    }

    /// Get the current texture configuration, if set.
    pub fn tex_cfg(&self) -> Option<TexCfgReg> {
        self.cfg
    }

    /// Return L1 decoded cache statistics for diagnostics.
    #[must_use]
    pub fn cache_stats(&self) -> &CacheStats {
        self.fetcher.cache_stats()
    }

    /// Return L2 compressed cache statistics for diagnostics.
    #[must_use]
    pub fn l2_cache_stats(&self) -> &L2CacheStats {
        self.fetcher.l2_stats()
    }

    /// Return the current configuration, if any.
    #[must_use]
    pub fn config(&self) -> Option<&TexCfgReg> {
        self.cfg.as_ref()
    }

    /// Return the number of cached blocks (for diagnostics/testing).
    #[must_use]
    pub fn cached_block_count(&self) -> usize {
        self.fetcher.cached_block_count()
    }
}

impl TrilinearBlender for TextureSampler {
    fn sample(&mut self, u: Q<4, 12>, v: Q<4, 12>, _lod: u8, sdram: &[u16]) -> ColorQ412 {
        let cfg = match &self.cfg {
            Some(c) if c.enable() => c,
            _ => return ColorQ412::OPAQUE_WHITE,
        };

        // Validate format before gathering.
        if cfg.format().is_err() {
            return ColorQ412::OPAQUE_WHITE;
        }

        let sample = self.gatherer.gather(&mut self.fetcher, u, v, cfg, sdram);
        self.blender.blend(&sample).to_q412()
    }
}

// ── Pipeline stage entry point ──────────────────────────────────────────────

/// Sample TEX0 and TEX1, producing a [`TexturedFragment`].
///
/// Consumes the UV and LOD lanes from the rasterizer output;
/// produces tex0 and tex1 sampled colors.
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
