//! Texture format decoders — decode raw SDRAM data into UQ1.8 RGBA texels.
//!
//! Each texture format implements the [`TexelDecoder`] trait, providing a
//! uniform interface for decoding a 4×4 texel block from raw SDRAM words
//! into [`TexelUq18`] format.
//!
//! The decoders match the corresponding RTL modules exactly:
//!
//! | Decoder | RTL Module | Block Size |
//! |---------|------------|------------|
//! | [`Rgb565Decoder`] | `texture_rgb565.sv` | 16 words |
//! | [`Rgba8888Decoder`] | `texture_rgba8888.sv` | 32 words |
//! | [`R8Decoder`] | `texture_r8.sv` | 8 words |
//! | [`Bc1Decoder`] | `texture_bc1.sv` | 4 words |
//! | [`Bc2Decoder`] | `texture_bc2.sv` | 8 words |
//! | [`Bc3Decoder`] | `texture_bc3.sv` | 8 words |
//! | [`Bc4Decoder`] | `texture_bc4.sv` | 4 words |
//!
//! See: INT-032 (Texture Cache Architecture), INT-014 (Texture Memory Layout).

use gpu_registers::components::tex_format_e::TexFormatE;
use qfixed::UQ;

use super::texel::TexelUq18;

// ── TexelDecoder trait ──────────────────────────────────────────────────────

/// Decode a 4×4 block of raw SDRAM words into 16 UQ1.8 RGBA texels.
///
/// Each texture format has a different block size in SDRAM and a different
/// decode algorithm, but all produce the same `[TexelUq18; 16]` output
/// in row-major order within the 4×4 block.
pub trait TexelDecoder {
    /// Size of one 4×4 block in u16 words within SDRAM.
    const BLOCK_SIZE_WORDS: u32;

    /// Decode raw SDRAM words into 16 decompressed texels.
    ///
    /// # Arguments
    ///
    /// * `raw` - Slice of at least [`Self::BLOCK_SIZE_WORDS`] u16 words
    ///   containing the compressed/raw block data.
    ///
    /// # Returns
    ///
    /// 16 texels in row-major order within the 4×4 block.
    fn decode_block(raw: &[u16]) -> [TexelUq18; 16];
}

// ── Channel expansion helpers ───────────────────────────────────────────────

/// Expand an 8-bit UNORM channel to 9-bit UQ1.8.
///
/// Replicates the MSB: `{ch8, ch8[7]}`.
/// Full-scale 0xFF maps to 0x1FF which is clamped to 0x100 (= 1.0).
///
/// # RTL Implementation Notes
///
/// Matches the RTL decoder expansion in `texture_rgba8888.sv`.
fn ch8_to_uq18(ch8: u16) -> UQ<1, 8> {
    let expanded = ((ch8 & 0xFF) << 1) | ((ch8 >> 7) & 1);
    // Clamp to UQ1.8 max (0x100 = 1.0).
    UQ::from_bits(expanded.min(0x100) as u64)
}

/// Expand a 5-bit channel to 9-bit UQ1.8 via MSB-replication + correction.
///
/// Formula: `(r5 << 3) | (r5 >> 2) + (r5 >> 4)`.
/// Full-scale 31 → 0x100 (exactly 1.0).
///
/// # RTL Implementation Notes
///
/// Matches the RTL decoder expansion in `texture_rgb565.sv`.
fn ch5_to_uq18(ch5: u16) -> UQ<1, 8> {
    let val = ((ch5 << 3) | (ch5 >> 2)) + (ch5 >> 4);
    UQ::from_bits(val as u64)
}

/// Expand a 6-bit channel to 9-bit UQ1.8 via MSB-replication + correction.
///
/// Formula: `(g6 << 2) | (g6 >> 4) + (g6 >> 5)`.
/// Full-scale 63 → 0x100 (exactly 1.0).
///
/// # RTL Implementation Notes
///
/// Matches the RTL decoder expansion in `texture_rgb565.sv`.
fn ch6_to_uq18(ch6: u16) -> UQ<1, 8> {
    let val = ((ch6 << 2) | (ch6 >> 4)) + (ch6 >> 5);
    UQ::from_bits(val as u64)
}

// ── RGB565 decoder ──────────────────────────────────────────────────────────

/// Decode RGB565 texels (16 bpp, uncompressed).
///
/// Each texel is one u16 word: `[15:11]=R5, [10:5]=G6, [4:0]=B5`.
/// Channels are expanded to UQ1.8 via MSB-replication with correction.
/// Alpha is set to fully opaque (0x100).
///
/// See: `texture_rgb565.sv`.
pub struct Rgb565Decoder;

impl TexelDecoder for Rgb565Decoder {
    const BLOCK_SIZE_WORDS: u32 = 16;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            let word = raw.get(i).copied().unwrap_or(0);
            *texel = rgb565_to_uq18(word);
        }
        block
    }
}

/// Convert an RGB565 word to [`TexelUq18`] (fully opaque).
fn rgb565_to_uq18(raw: u16) -> TexelUq18 {
    let r5 = (raw >> 11) & 0x1F;
    let g6 = (raw >> 5) & 0x3F;
    let b5 = raw & 0x1F;
    TexelUq18 {
        r: ch5_to_uq18(r5),
        g: ch6_to_uq18(g6),
        b: ch5_to_uq18(b5),
        a: UQ::from_bits(0x100), // Fully opaque
    }
}

// ── RGBA8888 decoder ────────────────────────────────────────────────────────

/// Decode RGBA8888 texels (32 bpp, uncompressed).
///
/// Each texel is two u16 words (little-endian u32):
/// `[7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8`.
/// Each 8-bit channel is expanded to UQ1.8 via `{ch8, ch8[7]}`.
///
/// See: `texture_rgba8888.sv`.
pub struct Rgba8888Decoder;

impl TexelDecoder for Rgba8888Decoder {
    const BLOCK_SIZE_WORDS: u32 = 32;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            let lo = raw.get(i * 2).copied().unwrap_or(0);
            let hi = raw.get(i * 2 + 1).copied().unwrap_or(0);
            let rgba = (hi as u32) << 16 | lo as u32;
            *texel = rgba8888_to_uq18(rgba);
        }
        block
    }
}

/// Convert an RGBA8888 value to [`TexelUq18`].
fn rgba8888_to_uq18(rgba: u32) -> TexelUq18 {
    let r8 = (rgba & 0xFF) as u16;
    let g8 = ((rgba >> 8) & 0xFF) as u16;
    let b8 = ((rgba >> 16) & 0xFF) as u16;
    let a8 = ((rgba >> 24) & 0xFF) as u16;
    TexelUq18 {
        r: ch8_to_uq18(r8),
        g: ch8_to_uq18(g8),
        b: ch8_to_uq18(b8),
        a: ch8_to_uq18(a8),
    }
}

// ── R8 decoder ──────────────────────────────────────────────────────────────

/// Decode R8 texels (8 bpp, single channel grayscale).
///
/// Two texels are packed per u16 word (little-endian).
/// The 8-bit value is replicated to all three color channels.
/// Alpha is set to fully opaque (0x100).
///
/// See: `texture_r8.sv`.
pub struct R8Decoder;

impl TexelDecoder for R8Decoder {
    const BLOCK_SIZE_WORDS: u32 = 8;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            let word = raw.get(i / 2).copied().unwrap_or(0);
            let byte = if i & 1 == 0 {
                (word & 0xFF) as u8
            } else {
                (word >> 8) as u8
            };
            *texel = r8_to_uq18(byte);
        }
        block
    }
}

/// Convert an R8 grayscale byte to [`TexelUq18`] (fully opaque, gray).
fn r8_to_uq18(val: u8) -> TexelUq18 {
    let ch = ch8_to_uq18(val as u16);
    TexelUq18 {
        r: ch,
        g: ch,
        b: ch,
        a: UQ::from_bits(0x100), // Fully opaque
    }
}

// ── BC1 decoder (stub) ──────────────────────────────────────────────────────

/// Decode BC1 (DXT1) texels (4 bpp, compressed).
///
/// Not yet implemented — returns default (black transparent) texels.
///
/// See: `texture_bc1.sv`.
pub struct Bc1Decoder;

impl TexelDecoder for Bc1Decoder {
    const BLOCK_SIZE_WORDS: u32 = 4;

    fn decode_block(_raw: &[u16]) -> [TexelUq18; 16] {
        // TODO: implement BC1 decoding
        [TexelUq18::default(); 16]
    }
}

// ── BC2 decoder (stub) ──────────────────────────────────────────────────────

/// Decode BC2 texels (8 bpp, compressed with explicit alpha).
///
/// Not yet implemented — returns default (black transparent) texels.
///
/// See: `texture_bc2.sv`.
pub struct Bc2Decoder;

impl TexelDecoder for Bc2Decoder {
    const BLOCK_SIZE_WORDS: u32 = 8;

    fn decode_block(_raw: &[u16]) -> [TexelUq18; 16] {
        // TODO: implement BC2 decoding
        [TexelUq18::default(); 16]
    }
}

// ── BC3 decoder (stub) ──────────────────────────────────────────────────────

/// Decode BC3 texels (8 bpp, compressed with interpolated alpha).
///
/// Not yet implemented — returns default (black transparent) texels.
///
/// See: `texture_bc3.sv`.
pub struct Bc3Decoder;

impl TexelDecoder for Bc3Decoder {
    const BLOCK_SIZE_WORDS: u32 = 8;

    fn decode_block(_raw: &[u16]) -> [TexelUq18; 16] {
        // TODO: implement BC3 decoding
        [TexelUq18::default(); 16]
    }
}

// ── BC4 decoder (stub) ──────────────────────────────────────────────────────

/// Decode BC4 texels (4 bpp, compressed single channel).
///
/// Not yet implemented — returns default (black transparent) texels.
///
/// See: `texture_bc4.sv`.
pub struct Bc4Decoder;

impl TexelDecoder for Bc4Decoder {
    const BLOCK_SIZE_WORDS: u32 = 4;

    fn decode_block(_raw: &[u16]) -> [TexelUq18; 16] {
        // TODO: implement BC4 decoding
        [TexelUq18::default(); 16]
    }
}

// ── Format dispatch ─────────────────────────────────────────────────────────

/// Return the block size in u16 words for the given texture format.
#[must_use]
pub fn block_size_words(format: TexFormatE) -> u32 {
    match format {
        TexFormatE::Bc1 => Bc1Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::Bc2 => Bc2Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::Bc3 => Bc3Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::Bc4 => Bc4Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::Rgb565 => Rgb565Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::Rgba8888 => Rgba8888Decoder::BLOCK_SIZE_WORDS,
        TexFormatE::R8 => R8Decoder::BLOCK_SIZE_WORDS,
    }
}

/// Decode a 4×4 texel block from SDRAM, dispatching to the correct
/// format decoder.
///
/// Reads `block_size_words(format)` u16 words starting at
/// `base_words + block_index * block_size_words(format)`.
///
/// # Arguments
///
/// * `format` - Texture pixel format.
/// * `sdram` - Flat SDRAM backing store.
/// * `base_words` - Texture base address in u16 words.
/// * `block_index` - Block index within the mip level (row-major).
pub fn decode_block(
    format: TexFormatE,
    sdram: &[u16],
    base_words: u32,
    block_index: u32,
) -> [TexelUq18; 16] {
    let bsw = block_size_words(format);
    let offset = (base_words + block_index * bsw) as usize;
    let end = (offset + bsw as usize).min(sdram.len());
    let raw = if offset < sdram.len() {
        &sdram[offset..end]
    } else {
        &[]
    };

    match format {
        TexFormatE::Bc1 => Bc1Decoder::decode_block(raw),
        TexFormatE::Bc2 => Bc2Decoder::decode_block(raw),
        TexFormatE::Bc3 => Bc3Decoder::decode_block(raw),
        TexFormatE::Bc4 => Bc4Decoder::decode_block(raw),
        TexFormatE::Rgb565 => Rgb565Decoder::decode_block(raw),
        TexFormatE::Rgba8888 => Rgba8888Decoder::decode_block(raw),
        TexFormatE::R8 => R8Decoder::decode_block(raw),
    }
}

/// Decode a 4×4 texel block from a pre-sliced raw data buffer.
///
/// Unlike [`decode_block`], this function takes the raw block data directly
/// rather than computing the offset within SDRAM.
/// Used by [`BlockFetcher`](super::tex_fetch::BlockFetcher) when raw data
/// has already been fetched by the compressed block cache.
///
/// # Arguments
///
/// * `format` - Texture pixel format.
/// * `raw` - Pre-sliced raw block data (at least `block_size_words(format)` words).
pub fn decode_block_raw(format: TexFormatE, raw: &[u16]) -> [TexelUq18; 16] {
    match format {
        TexFormatE::Bc1 => Bc1Decoder::decode_block(raw),
        TexFormatE::Bc2 => Bc2Decoder::decode_block(raw),
        TexFormatE::Bc3 => Bc3Decoder::decode_block(raw),
        TexFormatE::Bc4 => Bc4Decoder::decode_block(raw),
        TexFormatE::Rgb565 => Rgb565Decoder::decode_block(raw),
        TexFormatE::Rgba8888 => Rgba8888Decoder::decode_block(raw),
        TexFormatE::R8 => R8Decoder::decode_block(raw),
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb565_full_white() {
        let raw = [0xFFFFu16; 16];
        let block = Rgb565Decoder::decode_block(&raw);
        for texel in &block {
            assert_eq!(texel.r.to_bits(), 0x100, "R should be 1.0");
            assert_eq!(texel.g.to_bits(), 0x100, "G should be 1.0");
            assert_eq!(texel.b.to_bits(), 0x100, "B should be 1.0");
            assert_eq!(texel.a.to_bits(), 0x100, "A should be opaque");
        }
    }

    #[test]
    fn rgb565_black() {
        let raw = [0x0000u16; 16];
        let block = Rgb565Decoder::decode_block(&raw);
        for texel in &block {
            assert_eq!(texel.r.to_bits(), 0);
            assert_eq!(texel.g.to_bits(), 0);
            assert_eq!(texel.b.to_bits(), 0);
            assert_eq!(texel.a.to_bits(), 0x100, "A should be opaque");
        }
    }

    #[test]
    fn rgba8888_full_white() {
        // 0xFFFFFFFF as two u16 words (little-endian)
        let mut raw = [0u16; 32];
        for i in 0..16 {
            raw[i * 2] = 0xFFFF;
            raw[i * 2 + 1] = 0xFFFF;
        }
        let block = Rgba8888Decoder::decode_block(&raw);
        for texel in &block {
            assert_eq!(texel.r.to_bits(), 0x100);
            assert_eq!(texel.g.to_bits(), 0x100);
            assert_eq!(texel.b.to_bits(), 0x100);
            assert_eq!(texel.a.to_bits(), 0x100);
        }
    }

    #[test]
    fn r8_mid_gray() {
        // 0x80 in both bytes of each word
        let raw = [0x8080u16; 8];
        let block = R8Decoder::decode_block(&raw);
        for texel in &block {
            // 0x80 → ch8_to_uq18 → (0x80 << 1) | 1 = 0x101 → clamped to 0x100
            assert_eq!(texel.r.to_bits(), texel.g.to_bits());
            assert_eq!(texel.r.to_bits(), texel.b.to_bits());
            assert_eq!(texel.a.to_bits(), 0x100, "A should be opaque");
        }
    }

    #[test]
    fn block_size_words_match() {
        assert_eq!(block_size_words(TexFormatE::Rgb565), 16);
        assert_eq!(block_size_words(TexFormatE::Rgba8888), 32);
        assert_eq!(block_size_words(TexFormatE::R8), 8);
        assert_eq!(block_size_words(TexFormatE::Bc1), 4);
        assert_eq!(block_size_words(TexFormatE::Bc2), 8);
        assert_eq!(block_size_words(TexFormatE::Bc3), 8);
        assert_eq!(block_size_words(TexFormatE::Bc4), 4);
    }

    #[test]
    fn decode_block_dispatch() {
        // Verify dispatch produces same result as direct decoder call.
        let raw_sdram = vec![0xFFFFu16; 256];
        let block_direct = Rgb565Decoder::decode_block(&raw_sdram[0..16]);
        let block_dispatch = decode_block(TexFormatE::Rgb565, &raw_sdram, 0, 0);
        for i in 0..16 {
            assert_eq!(block_direct[i].r.to_bits(), block_dispatch[i].r.to_bits());
            assert_eq!(block_direct[i].g.to_bits(), block_dispatch[i].g.to_bits());
            assert_eq!(block_direct[i].b.to_bits(), block_dispatch[i].b.to_bits());
            assert_eq!(block_direct[i].a.to_bits(), block_dispatch[i].a.to_bits());
        }
    }
}
