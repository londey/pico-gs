// Spec-ref: unit_011_texture_sampler.md

//! Texture sampling — fetch texels from TEX0 and TEX1 units.
//!
//! This module provides the [`TextureSampler`] facade.
//! Each sampler owns one half-resolution [`IndexCache`] and delegates
//! palette lookup to a shared [`PaletteLut`] that the orchestrator
//! configures via [`TextureSampler::load_palette_slot`].
//!
//! # Pipeline (per UNIT-011)
//!
//! ```text
//! TextureSampler::sample
//!   -> UvCoord::process       (UNIT-011.01: wrap + half-resolution split)
//!   -> compute_quadrant       (UNIT-011.01: NW/NE/SW/SE selector)
//!   -> IndexCache::lookup     (UNIT-011.03: 8-bit palette index, fill on miss)
//!   -> PaletteLut::lookup     (UNIT-011.06: UQ1.8 RGBA quadrant colour)
//!   -> TexelUq18::to_q412     (UQ1.8 -> Q4.12 promotion, see fp_types_pkg.sv)
//! ```
//!
//! NEAREST point-sampling only — no bilinear taps, no mip selection,
//! no block decompression. INDEXED8_2X2 is the sole supported format.

use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;
use gs_tex_l1_cache::{IndexCache, INDICES_PER_LINE};
use gs_tex_palette_lut::{PaletteLut, PALETTE_BLOB_BYTES};
use gs_tex_uv_coord::{compute_quadrant, UvCoord};
use gs_twin_core::fragment::{ColorQ412, RasterFragment, TexturedFragment};
pub use gs_twin_core::texel::TexelUq18;
use qfixed::Q;

// ── TextureSampler facade ───────────────────────────────────────────────────

/// Per-unit texture sampler owning the index cache for one hardware
/// texture unit (TEX0 or TEX1).
///
/// The shared palette LUT lives outside the sampler so two samplers can
/// look up colours from the same 2-slot codebook without duplicating
/// storage; the orchestrator passes an immutable reference into
/// [`TextureSampler::sample`] each fragment.
///
/// See: UNIT-006 (Pixel Pipeline), UNIT-011 (Texture Sampler),
///      UNIT-011.01 / UNIT-011.03 / UNIT-011.06, INT-014.
pub struct TextureSampler {
    /// Current texture configuration, `None` if unconfigured.
    cfg: Option<TexCfgReg>,

    /// Half-resolution index cache (UNIT-011.03).
    index_cache: IndexCache,
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
            index_cache: IndexCache::new(),
        }
    }

    /// Configure the sampler from a `TEXn_CFG` register write.
    ///
    /// Stores the new configuration and invalidates the index cache,
    /// matching the RTL behaviour where any write to `TEXn_CFG` clears
    /// every valid bit in that sampler's index cache (UNIT-011.03).
    /// The shared palette LUT is *not* invalidated — palette contents
    /// persist across `TEXn_CFG` writes per UNIT-011.
    pub fn set_tex_cfg(&mut self, cfg: TexCfgReg) {
        self.cfg = Some(cfg);
        let base_words = u32::from(cfg.base_addr()) * 256;
        self.index_cache.set_tex_base(base_words);
        self.index_cache.invalidate();
    }

    /// Get the current texture configuration, if set.
    #[must_use]
    pub fn tex_cfg(&self) -> Option<TexCfgReg> {
        self.cfg
    }

    /// Return the current configuration, if any.
    #[must_use]
    pub fn config(&self) -> Option<&TexCfgReg> {
        self.cfg.as_ref()
    }

    /// Number of currently valid index-cache lines (diagnostic).
    #[must_use]
    pub fn valid_index_lines(&self) -> usize {
        self.index_cache.valid_line_count()
    }
}

impl TextureSampler {
    /// Sample a texel at the given UV coordinates.
    ///
    /// # Arguments
    ///
    /// * `u` - Horizontal texture coordinate, Q4.12 signed.
    /// * `v` - Vertical texture coordinate, Q4.12 signed.
    /// * `palette` - Shared palette LUT used to resolve the 8-bit index.
    /// * `sdram` - SDRAM backing store, used for index-cache miss fills.
    ///
    /// # Returns
    ///
    /// Sampled texel colour in Q4.12 RGBA format.
    pub fn sample(
        &mut self,
        u: Q<4, 12>,
        v: Q<4, 12>,
        palette: &PaletteLut,
        sdram: &[u16],
    ) -> ColorQ412 {
        let cfg = match &self.cfg {
            Some(c) if c.enable() => c,
            _ => return ColorQ412::OPAQUE_WHITE,
        };

        // INDEXED8_2X2 is the sole supported format; reject any reserved
        // encoding by falling back to opaque white (matches the legacy
        // disabled-sampler behaviour).
        if cfg.format().is_err() {
            return ColorQ412::OPAQUE_WHITE;
        }

        let slot = usize::from(cfg.palette_idx());
        if !palette.slot_ready(slot) {
            // Match the RTL stall-on-not-ready behaviour at the
            // transaction level: produce opaque white until firmware
            // loads the slot. The integration harness loads slots
            // before rendering so this path should not normally fire.
            return ColorQ412::OPAQUE_WHITE;
        }

        let w_log2 = cfg.width_log2();
        let h_log2 = cfg.height_log2();

        // UNIT-011.01 — wrap + half-resolution split.
        let u_bits = u.to_bits() as u16 as i16;
        let v_bits = v.to_bits() as u16 as i16;
        let (u_idx, u_low) = UvCoord::process(u_bits, cfg.u_wrap(), w_log2);
        let (v_idx, v_low) = UvCoord::process(v_bits, cfg.v_wrap(), h_log2);
        let quadrant = compute_quadrant(u_low, v_low);

        // UNIT-011.03 — index cache lookup (fill from SDRAM on miss).
        let idx = self
            .index_cache
            .lookup(u_idx, v_idx)
            .unwrap_or_else(|| self.fill_and_lookup(u_idx, v_idx, w_log2, sdram));

        // UNIT-011.06 — palette LUT lookup; UQ1.8 -> Q4.12 promotion.
        palette.lookup(slot, idx, quadrant).to_q412()
    }
}

impl TextureSampler {
    /// Service an index-cache miss: read the 4×4 index block from SDRAM,
    /// fill the cache line, and return the requested index.
    ///
    /// The SDRAM layout is INT-014's row-major, block-tiled index array:
    /// 16 bytes per 4×4 index block, blocks laid out left-to-right,
    /// top-to-bottom across the index grid.
    fn fill_and_lookup(&mut self, u_idx: u16, v_idx: u16, w_log2: u8, sdram: &[u16]) -> u8 {
        let payload = read_index_block(self.index_cache_base_words(), u_idx, v_idx, w_log2, sdram);
        self.index_cache.fill_line(u_idx, v_idx, &payload);
        // The just-filled line is guaranteed to satisfy the lookup; treat
        // any residual miss as a 0 index (matches an uninitialised SDRAM
        // word and avoids panics on out-of-range coordinates).
        self.index_cache.lookup(u_idx, v_idx).unwrap_or(0)
    }

    /// Cached base-words value used when computing SDRAM offsets.
    /// Mirrors the value last latched by [`Self::set_tex_cfg`] so that
    /// fills target the configured texture even if the cache's
    /// `tex_base_words` field is changed independently in future.
    fn index_cache_base_words(&self) -> u32 {
        self.cfg
            .as_ref()
            .map_or(0, |c| u32::from(c.base_addr()) * 256)
    }
}

/// Read a 4×4 index block (16 bytes) from SDRAM into a row-major byte array.
///
/// Implements the INT-014 INDEXED8_2X2 index-array layout:
/// `byte_offset = base + block_index * 16 + (local_y * 4 + local_x)`,
/// with `block_index = block_y * (index_width / 4) + block_x`.
fn read_index_block(
    base_words: u32,
    u_idx: u16,
    v_idx: u16,
    w_log2: u8,
    sdram: &[u16],
) -> [u8; INDICES_PER_LINE] {
    let block_x = u32::from(u_idx >> 2);
    let block_y = u32::from(v_idx >> 2);

    // index_width = apparent_width / 2 = 1 << (w_log2 - 1); minimum
    // INT-014 size is 2x2 apparent so w_log2 >= 1 and index_width >= 1.
    // Index arrays whose index_width is < 4 are padded to a single full
    // 4x4 index block (INT-014 §"Minimum and maximum sizes").
    let index_width = 1u32 << w_log2.saturating_sub(1);
    let blocks_per_row = index_width.div_ceil(4).max(1);
    let block_index = block_y * blocks_per_row + block_x;

    // 16 bytes per block = 8 SDRAM u16 words per block.
    let block_byte_offset = block_index * 16;
    let base_byte_offset = base_words * 2;
    let block_base_word = (base_byte_offset + block_byte_offset) / 2;

    let mut payload = [0u8; INDICES_PER_LINE];
    for (i, slot) in payload.iter_mut().enumerate() {
        let byte_in_block = i; // row-major: (local_y * 4 + local_x)
        let word_idx = block_base_word as usize + (byte_in_block / 2);
        let word = sdram.get(word_idx).copied().unwrap_or(0);
        // Little-endian within the 16-bit word: byte 0 = low, byte 1 = high.
        *slot = if byte_in_block & 1 == 0 {
            (word & 0xFF) as u8
        } else {
            (word >> 8) as u8
        };
    }
    payload
}

// ── Pipeline stage entry point ──────────────────────────────────────────────

/// Sample TEX0 and TEX1, producing a [`TexturedFragment`].
///
/// Consumes UV lanes from the rasterizer output; produces tex0 and tex1
/// sampled colours. Both samplers share `palette`, the integration
/// orchestrator's [`PaletteLut`].
pub fn tex_sample(
    frag: RasterFragment,
    tex0: &mut TextureSampler,
    tex1: &mut TextureSampler,
    palette: &PaletteLut,
    sdram: &[u16],
) -> TexturedFragment {
    let t0 = tex0.sample(frag.u0, frag.v0, palette, sdram);
    let t1 = tex1.sample(frag.u1, frag.v1, palette, sdram);

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

// ── Palette-load convenience ────────────────────────────────────────────────

impl TextureSampler {
    /// Convenience pre-load entry point used by integration test harnesses.
    ///
    /// The integration crate normally owns the [`PaletteLut`] directly and
    /// calls [`PaletteLut::load_slot`]; this helper exists so unit-level
    /// tests of the texture facade can stage a palette without depending
    /// on the orchestrator.
    ///
    /// # Arguments
    ///
    /// * `palette` - Mutable palette LUT to populate.
    /// * `slot` - Palette slot to load (`0` or `1`).
    /// * `payload` - 4096-byte palette blob in INT-014 layout.
    pub fn load_palette_slot(
        palette: &mut PaletteLut,
        slot: usize,
        payload: &[u8; PALETTE_BLOB_BYTES],
    ) {
        palette.load_slot(slot, payload);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;
    use gpu_registers::components::tex_format_e::TexFormatE;
    use gpu_registers::components::wrap_mode_e::WrapModeE;

    fn make_cfg(base_words: u32, w_log2: u8, h_log2: u8, palette_idx: bool) -> TexCfgReg {
        let mut cfg = TexCfgReg::default();
        cfg.set_enable(true);
        cfg.set_format(TexFormatE::Indexed82x2);
        cfg.set_width_log2(w_log2);
        cfg.set_height_log2(h_log2);
        cfg.set_u_wrap(WrapModeE::Repeat);
        cfg.set_v_wrap(WrapModeE::Repeat);
        cfg.set_palette_idx(palette_idx);
        // BASE_ADDR field is in 512-byte units (256 u16 words).
        cfg.set_base_addr((base_words / 256) as u16);
        cfg
    }

    /// Disabled sampler returns opaque white.
    #[test]
    fn disabled_sampler_returns_opaque_white() {
        let mut sampler = TextureSampler::new();
        let palette = PaletteLut::new();
        let sdram = vec![0u16; 16];
        let q = Q::<4, 12>::from_bits(0);
        let c = sampler.sample(q, q, &palette, &sdram);
        assert_eq!(c.r.to_bits(), ColorQ412::OPAQUE_WHITE.r.to_bits());
    }

    /// Sampler with un-loaded palette slot stalls -> opaque white.
    #[test]
    fn unloaded_palette_returns_opaque_white() {
        let mut sampler = TextureSampler::new();
        sampler.set_tex_cfg(make_cfg(0, 1, 1, false));
        let palette = PaletteLut::new();
        let sdram = vec![0u16; 16];
        let q = Q::<4, 12>::from_bits(0);
        let c = sampler.sample(q, q, &palette, &sdram);
        assert_eq!(c.r.to_bits(), ColorQ412::OPAQUE_WHITE.r.to_bits());
    }

    /// Round-trip: programme a 2x2 texture whose single index cell points
    /// at palette entry 1, slot 0, NW quadrant -> red.
    #[test]
    fn end_to_end_indexed82x2_red_nw() {
        // 2x2 apparent texture (w_log2 = h_log2 = 1) -> 1x1 index grid.
        // Index byte 0 -> palette entry 1; rest of the 16-byte block is 0.
        let mut sdram = vec![0u16; 32];
        // First word holds bytes 0 and 1 of the index block, little-endian.
        sdram[0] = 0x0001;

        let mut palette = PaletteLut::new();
        let mut blob = [0u8; PALETTE_BLOB_BYTES];
        // Entry 1, NW = opaque red (R=0xFF, G=0, B=0, A=0xFF).
        let entry_base = 16; // entry index 1 * 16 bytes per entry
        blob[entry_base] = 0xFF;
        blob[entry_base + 3] = 0xFF;
        palette.load_slot(0, &blob);

        let mut sampler = TextureSampler::new();
        sampler.set_tex_cfg(make_cfg(0, 1, 1, false));

        // UV (0, 0) -> apparent (0, 0) -> NW quadrant of palette entry 1.
        let q0 = Q::<4, 12>::from_bits(0);
        let c = sampler.sample(q0, q0, &palette, &sdram);
        // Promoted UQ1.8(0xFF) = 0x100 -> Q4.12 = 0x1000.
        assert_eq!(c.r.to_bits(), 0x1000);
        assert_eq!(c.g.to_bits(), 0);
        assert_eq!(c.b.to_bits(), 0);
        assert_eq!(c.a.to_bits(), 0x1000);
    }

    /// Repeated samples with the same UV must hit the cache after the
    /// initial fill (no second SDRAM read required).
    #[test]
    fn repeat_sample_hits_cache() {
        let mut sdram = vec![0u16; 32];
        sdram[0] = 0x0000;

        let mut palette = PaletteLut::new();
        palette.load_slot(0, &[0u8; PALETTE_BLOB_BYTES]);

        let mut sampler = TextureSampler::new();
        sampler.set_tex_cfg(make_cfg(0, 1, 1, false));

        let q0 = Q::<4, 12>::from_bits(0);
        let _ = sampler.sample(q0, q0, &palette, &sdram);
        let valid_after_first = sampler.valid_index_lines();
        assert_eq!(valid_after_first, 1);

        let _ = sampler.sample(q0, q0, &palette, &sdram);
        // No additional fill should happen.
        assert_eq!(sampler.valid_index_lines(), 1);
    }
}
