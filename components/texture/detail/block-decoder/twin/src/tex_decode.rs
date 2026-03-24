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

use gs_twin_core::texel::{block_size_words, TexelUq18};

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
/// Formula: `ch8 + (ch8 >> 7)`.
/// This maps 0x00 → 0, 0xFF → 0x100 (exactly 1.0), with
/// sub-LSB correction for the 255→256 range stretch.
///
/// # RTL Implementation Notes
///
/// RTL equivalent: `{1'b0, ch8} + {8'b0, ch8[7]}`.
/// The previous RTL expansion `{ch8, ch8[7]}` was a UQ0.9 value
/// (range [0, 511]) incorrectly fed into a UQ1.8 pipeline, producing
/// ~2× overbright texels.
/// See: DD-038, `texture_rgba8888.sv`.
fn ch8_to_uq18(ch8: u16) -> UQ<1, 8> {
    let val = (ch8 & 0xFF) + ((ch8 >> 7) & 1);
    UQ::from_bits(val as u64)
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

// ── BC1 decoder ─────────────────────────────────────────────────────────────

/// Decode BC1 (DXT1) texels (4 bpp, compressed).
///
/// BC1 block structure (4 u16 words = 8 bytes, little-endian):
///   - `raw[0]`: color0 (RGB565)
///   - `raw[1]`: color1 (RGB565)
///   - `raw[2..3]`: 32-bit index word (2 bits per texel, texel 0 = bits \[1:0\])
///
/// Two modes determined by `color0` vs `color1` comparison:
///   - `color0 > color1`: 4-color opaque mode.
///     Palette = \[C0, C1, lerp(C0,C1,1/3), lerp(C0,C1,2/3)\], all A=opaque.
///   - `color0 <= color1`: 3-color + transparent mode.
///     Palette = \[C0, C1, lerp(C0,C1,1/2), transparent black\].
///
/// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
///   - 1/3: `(2*C0 + C1 + 1) * 683 >> 11`
///   - 2/3: `(C0 + 2*C1 + 1) * 683 >> 11`
///   - 1/2: `(C0 + C1 + 1) >> 1`
///
/// Endpoints expanded to UQ1.8 before interpolation.
///
/// See: `texture_bc1.sv`, INT-014 (Format 0), DD-038, DD-039.
pub struct Bc1Decoder;

/// Interpolate 1/3 point: `(2*a + b + 1) * 683 >> 11`.
///
/// Matches RTL `sum13 * 683 >> 11` exactly for UQ1.8 operands.
fn bc1_interp_13(a: u32, b: u32) -> u16 {
    let sum = 2 * a + b + 1;
    ((sum * 683) >> 11) as u16
}

/// Interpolate 2/3 point: `(a + 2*b + 1) * 683 >> 11`.
fn bc1_interp_23(a: u32, b: u32) -> u16 {
    let sum = a + 2 * b + 1;
    ((sum * 683) >> 11) as u16
}

/// Interpolate 1/2 point: `(a + b + 1) >> 1`.
fn bc1_interp_12(a: u32, b: u32) -> u16 {
    ((a + b + 1) >> 1) as u16
}

impl TexelDecoder for Bc1Decoder {
    const BLOCK_SIZE_WORDS: u32 = 4;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        let color0 = raw.first().copied().unwrap_or(0);
        let color1 = raw.get(1).copied().unwrap_or(0);
        let indices = raw.get(2).copied().unwrap_or(0) as u32
            | (raw.get(3).copied().unwrap_or(0) as u32) << 16;

        let four_color_mode = color0 > color1;

        // Expand endpoints to UQ1.8.
        let c0_r = ch5_to_uq18((color0 >> 11) & 0x1F);
        let c0_g = ch6_to_uq18((color0 >> 5) & 0x3F);
        let c0_b = ch5_to_uq18(color0 & 0x1F);
        let c1_r = ch5_to_uq18((color1 >> 11) & 0x1F);
        let c1_g = ch6_to_uq18((color1 >> 5) & 0x3F);
        let c1_b = ch5_to_uq18(color1 & 0x1F);

        let opaque = UQ::<1, 8>::from_bits(0x100);

        // Build 4-entry palette.
        let p0 = TexelUq18 {
            r: c0_r,
            g: c0_g,
            b: c0_b,
            a: opaque,
        };
        let p1 = TexelUq18 {
            r: c1_r,
            g: c1_g,
            b: c1_b,
            a: opaque,
        };

        let (p2, p3) = if four_color_mode {
            // 4-color opaque: 1/3 and 2/3 interpolation.
            let p2 = TexelUq18 {
                r: UQ::from_bits(bc1_interp_13(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                g: UQ::from_bits(bc1_interp_13(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                b: UQ::from_bits(bc1_interp_13(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
                a: opaque,
            };
            let p3 = TexelUq18 {
                r: UQ::from_bits(bc1_interp_23(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                g: UQ::from_bits(bc1_interp_23(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                b: UQ::from_bits(bc1_interp_23(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
                a: opaque,
            };
            (p2, p3)
        } else {
            // 3-color + transparent: 1/2 interpolation, palette[3] = transparent black.
            let p2 = TexelUq18 {
                r: UQ::from_bits(bc1_interp_12(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                g: UQ::from_bits(bc1_interp_12(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                b: UQ::from_bits(bc1_interp_12(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
                a: opaque,
            };
            (p2, TexelUq18::default())
        };

        let palette = [p0, p1, p2, p3];

        // Look up each texel's 2-bit index in the palette.
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            let ci = ((indices >> (i * 2)) & 0x3) as usize;
            *texel = palette[ci];
        }
        block
    }
}

// ── BC2 decoder ─────────────────────────────────────────────────────────────

/// Decode BC2 texels (8 bpp, compressed with explicit alpha).
///
/// BC2 block structure (8 u16 words = 16 bytes, little-endian):
///   - `raw[0..3]`: Explicit 4-bit alpha per texel (4 u16 rows, 4 texels each).
///     Row bits \[3:0\] = col 0, \[7:4\] = col 1, \[11:8\] = col 2, \[15:12\] = col 3.
///   - `raw[4]`: color0 (RGB565)
///   - `raw[5]`: color1 (RGB565)
///   - `raw[6..7]`: 32-bit index word (2 bits per texel, texel 0 = bits \[1:0\])
///
/// The color block is always decoded in 4-color opaque mode (the `color0 > color1`
/// comparison from BC1 is forced true for BC2).
///
/// Alpha expansion: A4 to UQ1.8 via `{1'b0, a4, a4} + a4[3]`.
/// Full-scale 15 → 0x100 (exactly 1.0).
///
/// Color interpolation uses the same shift+add reciprocal-multiply as BC1 (DD-039).
///
/// See: `texture_bc2.sv`, INT-014 (Format 1), DD-038, DD-039.
pub struct Bc2Decoder;

/// Expand a 4-bit alpha to 9-bit UQ1.8 via bit-replication + correction.
///
/// Formula: `(a4 << 4 | a4) + (a4 >> 3)`.
/// Matches RTL: `{1'b0, a4, a4} + {8'b0, a4[3]}`.
/// Full-scale 15 → 0x100 (exactly 1.0).
fn ch4_to_uq18(a4: u16) -> UQ<1, 8> {
    let val = ((a4 & 0xF) << 4 | (a4 & 0xF)) + ((a4 >> 3) & 1);
    UQ::from_bits(val as u64)
}

impl TexelDecoder for Bc2Decoder {
    const BLOCK_SIZE_WORDS: u32 = 8;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        // ── Color block (words 4..7, BC1 4-color opaque mode forced) ──
        let color0 = raw.get(4).copied().unwrap_or(0);
        let color1 = raw.get(5).copied().unwrap_or(0);
        let indices = raw.get(6).copied().unwrap_or(0) as u32
            | (raw.get(7).copied().unwrap_or(0) as u32) << 16;

        // Expand endpoints to UQ1.8.
        let c0_r = ch5_to_uq18((color0 >> 11) & 0x1F);
        let c0_g = ch6_to_uq18((color0 >> 5) & 0x3F);
        let c0_b = ch5_to_uq18(color0 & 0x1F);
        let c1_r = ch5_to_uq18((color1 >> 11) & 0x1F);
        let c1_g = ch6_to_uq18((color1 >> 5) & 0x3F);
        let c1_b = ch5_to_uq18(color1 & 0x1F);

        // Build 4-entry color palette (always 4-color opaque mode).
        let colors: [[UQ<1, 8>; 3]; 4] = [
            [c0_r, c0_g, c0_b],
            [c1_r, c1_g, c1_b],
            [
                UQ::from_bits(bc1_interp_13(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_13(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_13(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
            ],
            [
                UQ::from_bits(bc1_interp_23(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_23(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_23(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
            ],
        ];

        // ── Decode each texel ──
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            // Alpha: 4-bit value from the alpha rows (words 0..3).
            let row = i / 4;
            let col = i % 4;
            let alpha_word = raw.get(row).copied().unwrap_or(0);
            let a4 = (alpha_word >> (col * 4)) & 0xF;

            // Color: 2-bit index into the palette.
            let ci = ((indices >> (i * 2)) & 0x3) as usize;
            let rgb = colors[ci];

            *texel = TexelUq18 {
                r: rgb[0],
                g: rgb[1],
                b: rgb[2],
                a: ch4_to_uq18(a4),
            };
        }
        block
    }
}

// ── BC3 decoder ─────────────────────────────────────────────────────────────

/// Decode BC3 texels (8 bpp, compressed with interpolated alpha).
///
/// BC3 block structure (8 u16 words = 16 bytes, little-endian):
///   - `raw[0]`: alpha0 (low byte), alpha1 (high byte)
///   - `raw[1..3]`: 48-bit alpha index table (3 bits per texel, texel 0 = bits \[2:0\])
///   - `raw[4]`: color0 (RGB565)
///   - `raw[5]`: color1 (RGB565)
///   - `raw[6..7]`: 32-bit color index word (2 bits per texel, texel 0 = bits \[1:0\])
///
/// Alpha palette generation:
///   - `alpha0 > alpha1`: 8-entry interpolated palette.
///     Division by 7: `(sum + 3) * 2341 >> 14` (DD-039).
///   - `alpha0 <= alpha1`: 6-entry interpolated + palette\[6\]=0, palette\[7\]=255.
///     Division by 5: `(sum + 2) * 3277 >> 14` (DD-039).
///
/// The color block is always decoded in 4-color opaque mode (same as BC2).
/// Alpha is expanded from u8 to UQ1.8 via `ch8_to_uq18`.
///
/// See: `texture_bc3.sv`, INT-014 (Format 2), DD-038, DD-039.
pub struct Bc3Decoder;

/// Interpolate alpha for 8-entry mode (divide by 7).
///
/// Formula: `(w0 * a0 + w1 * a1 + 3) * 2341 >> 14`, extracting bits \[21:14\].
/// Matches RTL exactly for operands in range.
fn bc3_alpha_interp_7(a0: u32, a1: u32, w0: u32, w1: u32) -> u8 {
    let sum = w0 * a0 + w1 * a1 + 3;
    ((sum * 2341) >> 14) as u8
}

/// Interpolate alpha for 6-entry mode (divide by 5).
///
/// Formula: `(w0 * a0 + w1 * a1 + 2) * 3277 >> 14`, extracting bits \[21:14\].
/// Matches RTL exactly for operands in range.
fn bc3_alpha_interp_5(a0: u32, a1: u32, w0: u32, w1: u32) -> u8 {
    let sum = w0 * a0 + w1 * a1 + 2;
    ((sum * 3277) >> 14) as u8
}

impl TexelDecoder for Bc3Decoder {
    const BLOCK_SIZE_WORDS: u32 = 8;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        // ── Alpha block (words 0..3) ──
        let alpha_word0 = raw.first().copied().unwrap_or(0);
        let alpha0 = (alpha_word0 & 0xFF) as u32;
        let alpha1 = ((alpha_word0 >> 8) & 0xFF) as u32;

        // 48-bit alpha index table from words 1..3.
        let alpha_indices: u64 = raw.get(1).copied().unwrap_or(0) as u64
            | (raw.get(2).copied().unwrap_or(0) as u64) << 16
            | (raw.get(3).copied().unwrap_or(0) as u64) << 32;

        // Build 8-entry alpha palette.
        let alpha_palette: [u8; 8] = if alpha0 > alpha1 {
            // 8-entry interpolated mode (divide by 7).
            [
                alpha0 as u8,
                alpha1 as u8,
                bc3_alpha_interp_7(alpha0, alpha1, 6, 1),
                bc3_alpha_interp_7(alpha0, alpha1, 5, 2),
                bc3_alpha_interp_7(alpha0, alpha1, 4, 3),
                bc3_alpha_interp_7(alpha0, alpha1, 3, 4),
                bc3_alpha_interp_7(alpha0, alpha1, 2, 5),
                bc3_alpha_interp_7(alpha0, alpha1, 1, 6),
            ]
        } else {
            // 6-entry interpolated + 0 and 255 (divide by 5).
            [
                alpha0 as u8,
                alpha1 as u8,
                bc3_alpha_interp_5(alpha0, alpha1, 4, 1),
                bc3_alpha_interp_5(alpha0, alpha1, 3, 2),
                bc3_alpha_interp_5(alpha0, alpha1, 2, 3),
                bc3_alpha_interp_5(alpha0, alpha1, 1, 4),
                0,
                255,
            ]
        };

        // ── Color block (words 4..7, BC1 4-color opaque mode forced) ──
        let color0 = raw.get(4).copied().unwrap_or(0);
        let color1 = raw.get(5).copied().unwrap_or(0);
        let color_indices = raw.get(6).copied().unwrap_or(0) as u32
            | (raw.get(7).copied().unwrap_or(0) as u32) << 16;

        // Expand color endpoints to UQ1.8.
        let c0_r = ch5_to_uq18((color0 >> 11) & 0x1F);
        let c0_g = ch6_to_uq18((color0 >> 5) & 0x3F);
        let c0_b = ch5_to_uq18(color0 & 0x1F);
        let c1_r = ch5_to_uq18((color1 >> 11) & 0x1F);
        let c1_g = ch6_to_uq18((color1 >> 5) & 0x3F);
        let c1_b = ch5_to_uq18(color1 & 0x1F);

        // Build 4-entry color palette (always 4-color opaque mode).
        let colors: [[UQ<1, 8>; 3]; 4] = [
            [c0_r, c0_g, c0_b],
            [c1_r, c1_g, c1_b],
            [
                UQ::from_bits(bc1_interp_13(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_13(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_13(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
            ],
            [
                UQ::from_bits(bc1_interp_23(c0_r.to_bits() as u32, c1_r.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_23(c0_g.to_bits() as u32, c1_g.to_bits() as u32) as u64),
                UQ::from_bits(bc1_interp_23(c0_b.to_bits() as u32, c1_b.to_bits() as u32) as u64),
            ],
        ];

        // ── Decode each texel ──
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            // Alpha: 3-bit index into the alpha palette.
            let ai = ((alpha_indices >> (i * 3)) & 0x7) as usize;
            let decoded_alpha = alpha_palette[ai];

            // Color: 2-bit index into the color palette.
            let ci = ((color_indices >> (i * 2)) & 0x3) as usize;
            let rgb = colors[ci];

            *texel = TexelUq18 {
                r: rgb[0],
                g: rgb[1],
                b: rgb[2],
                a: ch8_to_uq18(decoded_alpha as u16),
            };
        }
        block
    }
}

// ── BC4 decoder ─────────────────────────────────────────────────────────────

/// Decode BC4 texels (4 bpp, compressed single channel).
///
/// BC4 block structure (4 u16 words = 8 bytes, little-endian):
///   - `raw[0]`: red0 (low byte), red1 (high byte)
///   - `raw[1..3]`: 48-bit red index table (3 bits per texel, texel 0 = bits \[2:0\])
///
/// Uses the same encoding as the BC3 alpha block:
///   - `red0 > red1`: 8-entry interpolated palette.
///     Division by 7: `(sum + 3) * 2341 >> 14` (DD-039).
///   - `red0 <= red1`: 6-entry interpolated + palette\[6\]=0, palette\[7\]=255.
///     Division by 5: `(sum + 2) * 3277 >> 14` (DD-039).
///
/// Output: decoded red channel expanded to UQ1.8 via `ch8_to_uq18`,
/// replicated to R=G=B, with A=opaque (0x100).
///
/// See: `texture_bc4.sv`, INT-014 (Format 3), DD-038, DD-039.
pub struct Bc4Decoder;

impl TexelDecoder for Bc4Decoder {
    const BLOCK_SIZE_WORDS: u32 = 4;

    fn decode_block(raw: &[u16]) -> [TexelUq18; 16] {
        // ── Red block (same encoding as BC3 alpha block) ──
        let red_word0 = raw.first().copied().unwrap_or(0);
        let red0 = (red_word0 & 0xFF) as u32;
        let red1 = ((red_word0 >> 8) & 0xFF) as u32;

        // 48-bit red index table from words 1..3.
        let red_indices: u64 = raw.get(1).copied().unwrap_or(0) as u64
            | (raw.get(2).copied().unwrap_or(0) as u64) << 16
            | (raw.get(3).copied().unwrap_or(0) as u64) << 32;

        // Build 8-entry red palette (identical to BC3 alpha palette).
        let red_palette: [u8; 8] = if red0 > red1 {
            // 8-entry interpolated mode (divide by 7).
            [
                red0 as u8,
                red1 as u8,
                bc3_alpha_interp_7(red0, red1, 6, 1),
                bc3_alpha_interp_7(red0, red1, 5, 2),
                bc3_alpha_interp_7(red0, red1, 4, 3),
                bc3_alpha_interp_7(red0, red1, 3, 4),
                bc3_alpha_interp_7(red0, red1, 2, 5),
                bc3_alpha_interp_7(red0, red1, 1, 6),
            ]
        } else {
            // 6-entry interpolated + 0 and 255 (divide by 5).
            [
                red0 as u8,
                red1 as u8,
                bc3_alpha_interp_5(red0, red1, 4, 1),
                bc3_alpha_interp_5(red0, red1, 3, 2),
                bc3_alpha_interp_5(red0, red1, 2, 3),
                bc3_alpha_interp_5(red0, red1, 1, 4),
                0,
                255,
            ]
        };

        let opaque = UQ::<1, 8>::from_bits(0x100);

        // ── Decode each texel ──
        let mut block = [TexelUq18::default(); 16];
        for (i, texel) in block.iter_mut().enumerate() {
            let ri = ((red_indices >> (i * 3)) & 0x7) as usize;
            let ch = ch8_to_uq18(red_palette[ri] as u16);

            *texel = TexelUq18 {
                r: ch,
                g: ch,
                b: ch,
                a: opaque,
            };
        }
        block
    }
}

// ── Format dispatch ─────────────────────────────────────────────────────────

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
            // 0x80 → ch8_to_uq18 → 0x80 + 1 = 0x81
            assert_eq!(texel.r.to_bits(), 0x81, "R should be 0x81");
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
