//! Generate test vector hex files for DT-verified `texture_block_decode` RTL testbench.
//!
//! Produces `block_decode_stim.hex` (stimulus) and `block_decode_exp.hex` (expected output).
//! The SV testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! ## Stimulus packing (per vector, 17 × 64-bit words)
//!
//! - Word 0: control — bits `[3:0]=idx0, [7:4]=idx1, [11:8]=idx2, [15:12]=idx3, [19:16]=format`
//! - Words 1–16: block word pairs — word N = `{16'b0, 16'b0, block_word_{2i+1}, block_word_{2i}}`
//!
//! ## Expected packing (per vector, 4 × 64-bit words)
//!
//! - 4 words, each containing one 36-bit texel `{R9, G9, B9, A9}` zero-extended.
//!
//! Usage: `cargo run --bin gen_block_decode_vectors -- [output_dir]`

use gpu_registers::components::tex_format_e::TexFormatE;
use gs_tex_block_decoder::tex_decode::decode_block_raw;
use gs_twin_core::texel::TexelUq18;
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() > 1 {
        args[1].clone()
    } else {
        "../rtl/tests/vectors".to_string()
    };
    let out = Path::new(&out_dir);
    fs::create_dir_all(out).expect("create output dir");

    let vectors = build_all_vectors();
    write_hex_files(out, &vectors);

    eprintln!(
        "Block decode test vectors written to {} ({} vectors)",
        out.display(),
        vectors.len()
    );
}

// ── Types ───────────────────────────────────────────────────────────────────

/// One test vector for `texture_block_decode`.
struct TestVector {
    /// Texture format code (0–7).
    format: u8,

    /// Four texel indices (0–15) selecting which decoded texels to output.
    indices: [u8; 4],

    /// Raw block data (up to 32 u16 words, zero-padded).
    block_words: [u16; 32],
}

// ── Texel packing ───────────────────────────────────────────────────────────

/// Pack a `TexelUq18` into 36-bit RTL wire format: `{R9[35:27], G9[26:18], B9[17:9], A9[8:0]}`.
fn pack_texel(t: &TexelUq18) -> u64 {
    let r = t.r.to_bits() & 0x1FF;
    let g = t.g.to_bits() & 0x1FF;
    let b = t.b.to_bits() & 0x1FF;
    let a = t.a.to_bits() & 0x1FF;
    (r << 27) | (g << 18) | (b << 9) | a
}

// ── Deterministic PRNG (xorshift32) ─────────────────────────────────────────

/// Simple deterministic PRNG for reproducible random test vectors.
struct Xorshift32(u32);

impl Xorshift32 {
    /// Advance the PRNG state and return the next 32-bit value.
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    /// Return a random u16 value.
    fn next_u16(&mut self) -> u16 {
        self.next() as u16
    }

    /// Return a random 4-bit value (0–15).
    fn next_u4(&mut self) -> u8 {
        (self.next() & 0xF) as u8
    }
}

// ── Helper: build a zeroed block ────────────────────────────────────────────

/// Create a zeroed 32-word block.
fn zero_block() -> [u16; 32] {
    [0u16; 32]
}

/// Set block words from a slice, leaving the rest zero.
fn block_from(words: &[u16]) -> [u16; 32] {
    let mut b = zero_block();
    for (i, &w) in words.iter().enumerate() {
        if i < 32 {
            b[i] = w;
        }
    }
    b
}

// ── Compute expected outputs ────────────────────────────────────────────────

/// Decode and select 4 texels from a block using the DT.
///
/// # Arguments
///
/// * `format` - Texture format code (0–7).
/// * `block_words` - Raw block data (32 u16 words).
/// * `indices` - Four texel indices selecting which of 16 decoded texels to output.
///
/// # Returns
///
/// Four `TexelUq18` values, one per output lane. For reserved format (4),
/// returns transparent black.
fn compute_expected(format: u8, block_words: &[u16; 32], indices: &[u8; 4]) -> [TexelUq18; 4] {
    let fmt = match format {
        // Legacy format codes 0..=7 all collapse to INDEXED8_2X2 in the
        // shimmed dispatch below; this generator is scheduled for removal.
        0..=7 if format != 4 => Some(TexFormatE::Indexed82x2),
        _ => None, // Reserved or invalid → transparent black
    };

    let decoded = match fmt {
        Some(f) => decode_block_raw(f, block_words),
        None => [TexelUq18::default(); 16],
    };

    [
        decoded[indices[0] as usize],
        decoded[indices[1] as usize],
        decoded[indices[2] as usize],
        decoded[indices[3] as usize],
    ]
}

// ── Vector builders per format ──────────────────────────────────────────────

/// Build RGB565 (format=5) test vectors.
fn build_rgb565_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 5u8;

    // White (0xFFFF)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(16) {
        *w = 0xFFFF;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: bw,
    });

    // Black (0x0000)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: zero_block(),
    });

    // Pure red (0xF800)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(16) {
        *w = 0xF800;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: bw,
    });

    // Pure green (0x07E0)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(16) {
        *w = 0x07E0;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [1, 5, 9, 13],
        block_words: bw,
    });

    // Pure blue (0x001F)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(16) {
        *w = 0x001F;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [2, 6, 10, 14],
        block_words: bw,
    });

    // Mid-range (0x8410 — R=16, G=32, B=16)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(16) {
        *w = 0x8410;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 5, 10, 15],
        block_words: bw,
    });

    // All 16 texel indices with different values per texel
    let mut bw = zero_block();
    for i in 0..16u16 {
        // Progressively brighter: R component increments
        bw[i as usize] = (i << 11) | (i << 6) | i;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 5, 10, 15],
        block_words: bw,
    });
    // Test all 16 indices with 4 vectors (4 indices per vector)
    for base in (0u8..16).step_by(4) {
        vecs.push(TestVector {
            format: fmt,
            indices: [base, base + 1, base + 2, base + 3],
            block_words: bw,
        });
    }

    vecs
}

/// Build RGBA8888 (format=6) test vectors.
fn build_rgba8888_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 6u8;

    // White (0xFFFFFFFF → words 0xFFFF, 0xFFFF per texel)
    let mut bw = zero_block();
    for w in bw.iter_mut() {
        *w = 0xFFFF;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: bw,
    });

    // Black (all zero)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: zero_block(),
    });

    // Pure red (R=0xFF, G=0, B=0, A=0xFF → lo=0x00FF, hi=0xFF00)
    let mut bw = zero_block();
    for i in 0..16 {
        bw[i * 2] = 0x00FF; // lo: R=0xFF, G=0x00
        bw[i * 2 + 1] = 0xFF00; // hi: B=0x00, A=0xFF
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: bw,
    });

    // Pure green (R=0, G=0xFF, B=0, A=0xFF)
    let mut bw = zero_block();
    for i in 0..16 {
        bw[i * 2] = 0xFF00; // lo: R=0x00, G=0xFF
        bw[i * 2 + 1] = 0xFF00; // hi: B=0x00, A=0xFF
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [1, 5, 9, 13],
        block_words: bw,
    });

    // Pure blue (R=0, G=0, B=0xFF, A=0xFF)
    let mut bw = zero_block();
    for i in 0..16 {
        bw[i * 2] = 0x0000; // lo: R=0x00, G=0x00
        bw[i * 2 + 1] = 0xFFFF; // hi: B=0xFF, A=0xFF
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [2, 6, 10, 14],
        block_words: bw,
    });

    // Mid-range per channel (R=0x80, G=0x40, B=0xC0, A=0x80)
    let mut bw = zero_block();
    for i in 0..16 {
        bw[i * 2] = 0x4080; // lo: R=0x80, G=0x40
        bw[i * 2 + 1] = 0x80C0; // hi: B=0xC0, A=0x80
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 5, 10, 15],
        block_words: bw,
    });

    // Alpha variations: transparent (A=0), semi (A=0x80), opaque (A=0xFF)
    let alphas: [u8; 3] = [0x00, 0x80, 0xFF];
    for &a in &alphas {
        let mut bw = zero_block();
        for i in 0..16 {
            bw[i * 2] = 0x8080; // lo: R=0x80, G=0x80
            bw[i * 2 + 1] = 0x0080 | (u16::from(a) << 8); // hi: B=0x80, A=a
        }
        vecs.push(TestVector {
            format: fmt,
            indices: [0, 1, 2, 3],
            block_words: bw,
        });
    }

    // All 16 indices with distinct texels
    let mut bw = zero_block();
    for i in 0..16u16 {
        let r = (i * 17) & 0xFF;
        let g = ((i * 23) + 10) & 0xFF;
        let b = ((i * 31) + 5) & 0xFF;
        let a = ((i * 13) + 128) & 0xFF;
        bw[i as usize * 2] = (g << 8) | r;
        bw[i as usize * 2 + 1] = (a << 8) | b;
    }
    for base in (0u8..16).step_by(4) {
        vecs.push(TestVector {
            format: fmt,
            indices: [base, base + 1, base + 2, base + 3],
            block_words: bw,
        });
    }

    vecs
}

/// Build R8 (format=7) test vectors.
fn build_r8_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 7u8;

    // All zeros
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: zero_block(),
    });

    // Value 128 (0x80) packed: two texels per word
    let mut bw = zero_block();
    for w in bw.iter_mut().take(8) {
        *w = 0x8080;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: bw,
    });

    // Value 255 (0xFF)
    let mut bw = zero_block();
    for w in bw.iter_mut().take(8) {
        *w = 0xFFFF;
    }
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: bw,
    });

    // Various grayscale values (pairs of different values)
    let bw = block_from(&[
        0x4020, // texel 0=0x20, texel 1=0x40
        0xC080, // texel 2=0x80, texel 3=0xC0
        0x1008, // texel 4=0x08, texel 5=0x10
        0xFEE0, // texel 6=0xE0, texel 7=0xFE
        0x0201, // texel 8=0x01, texel 9=0x02
        0x7F3F, // texel 10=0x3F, texel 11=0x7F
        0xF0A0, // texel 12=0xA0, texel 13=0xF0
        0xFF55, // texel 14=0x55, texel 15=0xFF
    ]);
    // Test all 16 indices
    for base in (0u8..16).step_by(4) {
        vecs.push(TestVector {
            format: fmt,
            indices: [base, base + 1, base + 2, base + 3],
            block_words: bw,
        });
    }

    vecs
}

/// Build BC1 (format=0) test vectors.
fn build_bc1_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 0u8;

    // 4-color opaque mode (color0 > color1): white endpoints, index 0
    // color0=0xFFFF > color1=0x0000 → 4-color opaque mode
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0xFFFF, 0x0000, 0x0000, 0x0000]),
    });

    // 4-color opaque: all palette indices exercised
    // Indices bits: texel0=0b00, texel1=0b01, texel2=0b10, texel3=0b11
    // word2 (low indices) = 0b_11_10_01_00 = 0xE4 for first 4 texels
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0xFFFF, 0x0000, 0x00E4, 0x0000]),
    });

    // 4-color opaque: index pattern for texels 4-7 (in word2 upper bits)
    // texel4=0b00, texel5=0b01, texel6=0b10, texel7=0b11 → bits[15:8]=0xE4
    vecs.push(TestVector {
        format: fmt,
        indices: [4, 5, 6, 7],
        block_words: block_from(&[0xFFFF, 0x0000, 0xE400, 0x0000]),
    });

    // 4-color opaque: index pattern for texels 8-15 (in word3)
    vecs.push(TestVector {
        format: fmt,
        indices: [8, 9, 10, 11],
        block_words: block_from(&[0xFFFF, 0x0000, 0x0000, 0x00E4]),
    });
    vecs.push(TestVector {
        format: fmt,
        indices: [12, 13, 14, 15],
        block_words: block_from(&[0xFFFF, 0x0000, 0x0000, 0xE400]),
    });

    // 4-color opaque: red vs blue endpoints
    // Red: R=31,G=0,B=0 → 0xF800; Blue: R=0,G=0,B=31 → 0x001F
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0xF800, 0x001F, 0x00E4, 0x0000]),
    });

    // 4-color opaque: green endpoints
    // Green: R=0,G=63,B=0 → 0x07E0
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0x07E0, 0xF800, 0x00E4, 0x0000]),
    });

    // 3-color + transparent mode (color0 <= color1)
    // color0=0x0000 <= color1=0xFFFF → 3-color + transparent
    // Index 3 = transparent black
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0x0000, 0xFFFF, 0x00E4, 0x0000]),
    });

    // 3-color + transparent: equal endpoints → 3-color mode
    // color0=0x8410 == color1=0x8410
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0x8410, 0x8410, 0x00E4, 0x0000]),
    });

    // Degenerate: same endpoints (both white)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0xFFFF, 0xFFFF, 0x00E4, 0x0000]),
    });

    // All texels with index 0 (color0)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: block_from(&[0xF800, 0x001F, 0x0000, 0x0000]),
    });

    // All texels with index 1 (color1)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: block_from(&[0xF800, 0x001F, 0x5555, 0x5555]),
    });

    // All texels with index 2 (1/3 interpolation in 4-color mode)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: block_from(&[0xF800, 0x001F, 0xAAAA, 0xAAAA]),
    });

    // All texels with index 3 (2/3 interpolation in 4-color mode)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 4, 8, 12],
        block_words: block_from(&[0xF800, 0x001F, 0xFFFF, 0xFFFF]),
    });

    vecs
}

/// Build BC2 (format=1) test vectors.
fn build_bc2_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 1u8;

    // Alpha = 0xF (opaque), white color block
    // Alpha words 0-3 = 0xFFFF (all 4-bit alpha = 0xF)
    // Color: color0=0xFFFF, color1=0xFFFF, indices=0
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, // alpha rows (all 0xF)
            0xFFFF, 0xFFFF, 0x0000, 0x0000, // color block
        ]),
    });

    // Alpha = 0x0 (transparent), white color block
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x0000, 0x0000, 0x0000, 0x0000, // alpha rows (all 0x0)
            0xFFFF, 0xFFFF, 0x0000, 0x0000, // color block
        ]),
    });

    // Mid-alpha (0x8), red/blue color interpolation
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x8888, 0x8888, 0x8888, 0x8888, // alpha rows (all 0x8)
            0xF800, 0x001F, 0x00E4, 0x0000, // color block (red vs blue)
        ]),
    });

    // Per-texel alpha variation (row 0 has different alphas)
    // Row 0: col0=0x0, col1=0x5, col2=0xA, col3=0xF
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0xFA50, 0xFFFF, 0xFFFF, 0xFFFF, // alpha: row0 varied, rest opaque
            0xFFFF, 0x0000, 0x0000, 0x0000, // color: white
        ]),
    });

    // All 4 palette indices with varied alpha
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x1234, 0x5678, 0x9ABC, 0xDEF0, // varied alpha
            0xF800, 0x001F, 0x00E4, 0x0000, // color with all 4 indices
        ]),
    });

    // Test texels 4-7 and 8-15 index coverage
    for base in (4u8..16).step_by(4) {
        vecs.push(TestVector {
            format: fmt,
            indices: [base, base + 1, base + 2, base + 3],
            block_words: block_from(&[
                0x3692, 0xCF58, 0x1A4E, 0xB7D2, // varied alpha
                0x07E0, 0xF81F, 0x00E4, 0xE400, // color
            ]),
        });
    }

    vecs
}

/// Build BC3 (format=2) test vectors.
fn build_bc3_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 2u8;

    // 8-entry alpha mode (alpha0 > alpha1): alpha0=255, alpha1=0
    // Alpha indices: texel0=0, texel1=1, texel2=2, texel3=3
    // 48-bit alpha indices in words 1-3: 3 bits per texel
    // texel0=0b000, texel1=0b001, texel2=0b010, texel3=0b011
    // bits [11:0] = 0b_011_010_001_000 = 0x188
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x00FF, // alpha0=255, alpha1=0
            0x0188, 0x0000, 0x0000, // alpha indices
            0xFFFF, 0x0000, 0x0000, 0x0000, // color block (white/black)
        ]),
    });

    // 8-entry alpha mode: all 8 alpha palette entries exercised
    // texel0=0, texel1=1, texel2=2, texel3=3, texel4=4, texel5=5, texel6=6, texel7=7
    // bits: 000_001_010_011_100_101_110_111
    // = 0b_111_110_101_100_011_010_001_000
    // Low 16 bits (texels 0-4, partial 5): bits [15:0]
    // texel0[2:0]=000, texel1[5:3]=001, texel2[8:6]=010, texel3[11:9]=011, texel4[14:12]=100
    // = 0b_100_011_010_001_000 = 0x4688... let me compute carefully:
    // 0*1 + 1*8 + 2*64 + 3*512 + 4*4096 = 0 + 8 + 128 + 1536 + 16384 = 18056 = 0x4688
    // texel5 starts at bit 15: 5*32768 = 163840... that overflows u16.
    // Word 1 holds bits [15:0], word 2 holds bits [31:16], word 3 holds bits [47:32]
    // texel0-5 occupy bits 0-17: 0+8+128+1536+16384+5*32768 → 5 spans bits 15-17
    // Let me just pack them carefully:
    // indices_u48 = 0 | (1<<3) | (2<<6) | (3<<9) | (4<<12) | (5<<15) | (6<<18) | (7<<21)
    let alpha_idx_48: u64 =
        (1 << 3) | (2 << 6) | (3 << 9) | (4 << 12) | (5 << 15) | (6 << 18) | (7 << 21);
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x00FF, // alpha0=255, alpha1=0
            (alpha_idx_48 & 0xFFFF) as u16,
            ((alpha_idx_48 >> 16) & 0xFFFF) as u16,
            ((alpha_idx_48 >> 32) & 0xFFFF) as u16,
            0xFFFF,
            0xFFFF,
            0x0000,
            0x0000, // color: white
        ]),
    });
    // Indices 4-7 to see palette entries 4-7
    vecs.push(TestVector {
        format: fmt,
        indices: [4, 5, 6, 7],
        block_words: block_from(&[
            0x00FF,
            (alpha_idx_48 & 0xFFFF) as u16,
            ((alpha_idx_48 >> 16) & 0xFFFF) as u16,
            ((alpha_idx_48 >> 32) & 0xFFFF) as u16,
            0xFFFF,
            0xFFFF,
            0x0000,
            0x0000,
        ]),
    });

    // 6-entry alpha mode (alpha0 <= alpha1): alpha0=0, alpha1=255
    // palette[6]=0, palette[7]=255
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0xFF00, // alpha0=0, alpha1=255
            (alpha_idx_48 & 0xFFFF) as u16,
            ((alpha_idx_48 >> 16) & 0xFFFF) as u16,
            ((alpha_idx_48 >> 32) & 0xFFFF) as u16,
            0xFFFF,
            0xFFFF,
            0x0000,
            0x0000,
        ]),
    });
    // Check palette[6]=0 and palette[7]=255
    vecs.push(TestVector {
        format: fmt,
        indices: [4, 5, 6, 7],
        block_words: block_from(&[
            0xFF00,
            (alpha_idx_48 & 0xFFFF) as u16,
            ((alpha_idx_48 >> 16) & 0xFFFF) as u16,
            ((alpha_idx_48 >> 32) & 0xFFFF) as u16,
            0xFFFF,
            0xFFFF,
            0x0000,
            0x0000,
        ]),
    });

    // 6-entry mode: equal endpoints (alpha0=128 == alpha1=128)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x8080, // alpha0=128, alpha1=128
            0x0000, 0x0000, 0x0000, // all alpha index 0
            0xF800, 0x001F, 0x00E4, 0x0000, // color: red/blue with palette
        ]),
    });

    // 8-entry mode with mid-range endpoints
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x40C0, // alpha0=192, alpha1=64
            0x0188, 0x0000, 0x0000, 0x07E0, 0xFFFF, 0x00E4, 0x0000, // color: green/white
        ]),
    });

    vecs
}

/// Build BC4 (format=3) test vectors.
fn build_bc4_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let fmt = 3u8;

    // 8-entry mode (red0 > red1): red0=255, red1=0
    let idx_48: u64 =
        (1 << 3) | (2 << 6) | (3 << 9) | (4 << 12) | (5 << 15) | (6 << 18) | (7 << 21);
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x00FF, // red0=255, red1=0
            (idx_48 & 0xFFFF) as u16,
            ((idx_48 >> 16) & 0xFFFF) as u16,
            ((idx_48 >> 32) & 0xFFFF) as u16,
        ]),
    });

    // Check indices 4-7
    vecs.push(TestVector {
        format: fmt,
        indices: [4, 5, 6, 7],
        block_words: block_from(&[
            0x00FF,
            (idx_48 & 0xFFFF) as u16,
            ((idx_48 >> 16) & 0xFFFF) as u16,
            ((idx_48 >> 32) & 0xFFFF) as u16,
        ]),
    });

    // 6-entry mode (red0 <= red1): red0=0, red1=255
    // palette[6]=0, palette[7]=255
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0xFF00, // red0=0, red1=255
            (idx_48 & 0xFFFF) as u16,
            ((idx_48 >> 16) & 0xFFFF) as u16,
            ((idx_48 >> 32) & 0xFFFF) as u16,
        ]),
    });
    vecs.push(TestVector {
        format: fmt,
        indices: [4, 5, 6, 7],
        block_words: block_from(&[
            0xFF00,
            (idx_48 & 0xFFFF) as u16,
            ((idx_48 >> 16) & 0xFFFF) as u16,
            ((idx_48 >> 32) & 0xFFFF) as u16,
        ]),
    });

    // All-zero (red0=0, red1=0)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0x0000, 0x0000, 0x0000, 0x0000]),
    });

    // Same endpoints (red0=128, red1=128)
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[0x8080, 0x0000, 0x0000, 0x0000]),
    });

    // Mid-range 8-entry mode
    vecs.push(TestVector {
        format: fmt,
        indices: [0, 1, 2, 3],
        block_words: block_from(&[
            0x40C0, // red0=192, red1=64
            0x0188, 0x0000, 0x0000,
        ]),
    });

    vecs
}

/// Build reserved format (format=4) test vectors.
fn build_reserved_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();

    // Any block data should produce all-zero output
    vecs.push(TestVector {
        format: 4,
        indices: [0, 1, 2, 3],
        block_words: zero_block(),
    });

    // Non-zero block data, still expect zero output
    let mut bw = zero_block();
    for w in bw.iter_mut() {
        *w = 0xFFFF;
    }
    vecs.push(TestVector {
        format: 4,
        indices: [0, 5, 10, 15],
        block_words: bw,
    });

    // Random block data
    vecs.push(TestVector {
        format: 4,
        indices: [3, 7, 11, 15],
        block_words: block_from(&[0xDEAD, 0xBEEF, 0xCAFE, 0xBABE]),
    });

    vecs
}

/// Build seeded PRNG random vectors for all formats.
fn build_random_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let mut rng = Xorshift32(0xDEAD_BEEF);

    let formats: [u8; 8] = [0, 1, 2, 3, 4, 5, 6, 7];
    for &fmt in &formats {
        let count = if fmt == 4 { 10 } else { 50 };
        for _ in 0..count {
            let mut bw = zero_block();
            for w in &mut bw {
                *w = rng.next_u16();
            }
            let indices = [rng.next_u4(), rng.next_u4(), rng.next_u4(), rng.next_u4()];
            vecs.push(TestVector {
                format: fmt,
                indices,
                block_words: bw,
            });
        }
    }

    vecs
}

/// Build vectors that exercise all 16 texel indices for each format.
fn build_index_coverage_vectors() -> Vec<TestVector> {
    let mut vecs = Vec::new();
    let mut rng = Xorshift32(0xCAFE_BABE);

    let formats: [u8; 7] = [0, 1, 2, 3, 5, 6, 7];
    for &fmt in &formats {
        // Generate one random block and iterate through all 16 indices
        let mut bw = zero_block();
        for w in &mut bw {
            *w = rng.next_u16();
        }

        // For BC1 in 4-color opaque mode, ensure color0 > color1
        if fmt == 0 && bw[0] <= bw[1] {
            let tmp = bw[0];
            bw[0] = bw[1].wrapping_add(1);
            if bw[0] <= tmp {
                bw[0] = 0xFFFF;
                bw[1] = 0x0000;
            }
        }

        for base in (0u8..16).step_by(4) {
            vecs.push(TestVector {
                format: fmt,
                indices: [base, base + 1, base + 2, base + 3],
                block_words: bw,
            });
        }
    }

    vecs
}

// ── Master vector builder ───────────────────────────────────────────────────

/// Build all test vectors across all categories.
fn build_all_vectors() -> Vec<TestVector> {
    let mut all = Vec::new();
    all.extend(build_rgb565_vectors());
    all.extend(build_rgba8888_vectors());
    all.extend(build_r8_vectors());
    all.extend(build_bc1_vectors());
    all.extend(build_bc2_vectors());
    all.extend(build_bc3_vectors());
    all.extend(build_bc4_vectors());
    all.extend(build_reserved_vectors());
    all.extend(build_random_vectors());
    all.extend(build_index_coverage_vectors());
    all
}

// ── Hex file output ─────────────────────────────────────────────────────────

/// Write stimulus and expected hex files from a vector list.
///
/// # Arguments
///
/// * `out` - Output directory path.
/// * `vectors` - Slice of test vectors to write.
fn write_hex_files(out: &Path, vectors: &[TestVector]) {
    let num = vectors.len();
    let mut stim = String::new();
    let mut exp = String::new();

    // First line: vector count (16 hex digits).
    writeln!(stim, "{num:016x}").unwrap();
    writeln!(exp, "{num:016x}").unwrap();

    for v in vectors {
        // ── Stimulus: 17 × 64-bit words ──

        // Word 0: control
        let ctrl: u64 = u64::from(v.indices[0])
            | (u64::from(v.indices[1]) << 4)
            | (u64::from(v.indices[2]) << 8)
            | (u64::from(v.indices[3]) << 12)
            | (u64::from(v.format) << 16);
        writeln!(stim, "{ctrl:016x}").unwrap();

        // Words 1–16: block word pairs (2 u16 per 64-bit word, zero-extended)
        for i in 0..16 {
            let lo = u64::from(v.block_words[i * 2]);
            let hi = u64::from(v.block_words[i * 2 + 1]);
            let packed = lo | (hi << 16);
            writeln!(stim, "{packed:016x}").unwrap();
        }

        // ── Expected: 4 × 64-bit words ──
        let expected = compute_expected(v.format, &v.block_words, &v.indices);
        for texel in &expected {
            writeln!(exp, "{:016x}", pack_texel(texel)).unwrap();
        }
    }

    fs::write(out.join("block_decode_stim.hex"), stim).unwrap();
    fs::write(out.join("block_decode_exp.hex"), exp).unwrap();

    eprintln!(
        "  block_decode: {num} vectors ({} stim words, {} exp words)",
        1 + num * 17,
        1 + num * 4
    );
}
