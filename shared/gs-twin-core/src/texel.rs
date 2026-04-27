//! UQ1.8 texel type — the sole texture cache storage format.
//!
//! The current pipeline supports only the INDEXED8_2X2 texture format,
//! whose 8-bit indices are resolved through a 2-slot palette LUT into
//! UQ1.8 RGBA quadrant colors before entering the fragment pipeline.
//!
//! This module is the shared leaf dependency for the texture sampling
//! crates (`gs-tex-uv-coord`, `gs-tex-l1-cache`, `gs-tex-palette-lut`,
//! `gs-texture`).

use gpu_registers::components::tex_format_e::TexFormatE;
use qfixed::{Q, UQ};

use crate::fragment::ColorQ412;

// ── UQ1.8 texel format (texture cache intermediate) ─────────────────────────

/// Per-channel UQ1.8 UNORM texel, the sole texture cache storage format.
///
/// Each channel is a 9-bit unsigned fixed-point value in \[0.0, 1.0\]
/// where `0x100` represents exactly 1.0.
/// INDEXED8_2X2 indices are resolved through the palette LUT into this
/// format before entering the fragment pipeline.
///
/// The 36-bit palette codebook layout (per UNIT-011.06):
/// `[35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9`.
///
/// # RTL Implementation Notes
///
/// The RTL multiplies two UQ1.8 operands (texel × weight) in the 9×9
/// sub-mode of the DSP block, producing a UQ2.16 partial product.
/// Four partial products are accumulated and truncated back to UQ1.8.
/// See `texture_cache.sv`, `texel_promote.sv`.
#[derive(Debug, Clone, Copy, Default)]
pub struct TexelUq18 {
    /// Red channel, UQ1.8 UNORM.
    pub r: UQ<1, 8>,

    /// Green channel, UQ1.8 UNORM.
    pub g: UQ<1, 8>,

    /// Blue channel, UQ1.8 UNORM.
    pub b: UQ<1, 8>,

    /// Alpha channel, UQ1.8 UNORM.
    pub a: UQ<1, 8>,
}

// ── Format-level metadata ────────────────────────────────────────────────────

/// Return the 4×4 block size in u16 words for the given texture format.
///
/// Legacy helper retained for the (soon-to-be-deleted) `gs-tex-block-decoder`
/// and `gs-tex-l2-cache` crates.  The current INDEXED8_2X2 pipeline does
/// not use 4×4 blocks; the index cache is line-based and the value
/// returned here is a placeholder until those crates are removed.
#[must_use]
pub fn block_size_words(format: TexFormatE) -> u32 {
    match format {
        // INDEXED8_2X2 is not block-tiled.  The legacy decoder/L2 cache
        // crates that consume this helper are scheduled for deletion.
        TexFormatE::Indexed82x2 => 0,
    }
}

impl TexelUq18 {
    /// Promote to Q4.12 RGBA for the downstream fragment pipeline.
    ///
    /// Converts each UQ1.8 channel (0..=0x100) to Q4.12 (0..=0x1000)
    /// by left-shifting 4 bits, matching `texel_promote.sv`'s
    /// `promote_uq18_to_q412()`.
    ///
    /// # Returns
    ///
    /// `ColorQ412` with channels in \[0x0000, 0x1000\] (UNORM \[0.0, 1.0\]).
    pub fn to_q412(self) -> ColorQ412 {
        ColorQ412 {
            r: Q::from_bits((self.r.to_bits() << 4) as i64),
            g: Q::from_bits((self.g.to_bits() << 4) as i64),
            b: Q::from_bits((self.b.to_bits() << 4) as i64),
            a: Q::from_bits((self.a.to_bits() << 4) as i64),
        }
    }
}
