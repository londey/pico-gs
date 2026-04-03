//! Generate test vector hex files for DT-verified L1 cache WRAP-mode RTL testbench.
//!
//! Produces `l1_cache_wrap_stim.hex` (stimulus) and `l1_cache_wrap_exp.hex` (expected output).
//! The SV testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! # Hex Format
//!
//! ## Stimulus (`l1_cache_wrap_stim.hex`)
//!
//! Word 0: `{32'b0, vector_count[31:0]}` — total number of operations.
//!
//! Each operation is one of:
//!
//! **Fill (op=0):** 1 header + 8 data words = 9 words total.
//!   - Header: `{8'h00, tex_width_log2[7:0], 5'b0, tex_format[2:0],
//!              6'b0, pixel_y[9:0], 6'b0, pixel_x[9:0], tex_base_addr[23:0]}`
//!     Packed as: `{op[63:56], wlog2[55:48], fmt[50:48], py[41:32], px[25:16], base[23:0]}`
//!     Actually simplified: header word packs op + base + px + py + fmt + wlog2 across 64 bits.
//!   - Data words 1..8: each 64-bit word packs 4 × u16 raw RGB565 values.
//!     `{raw[3][63:48], raw[2][47:32], raw[1][31:16], raw[0][15:0]}` for each pair.
//!     Total: 8 words × 4 u16 = 32, but only first 16 used for RGB565.
//!     Actually: 4 words × 4 u16 = 16 raw words. But we use 8 × 64-bit for 32 u16 max.
//!
//! **Lookup (op=1):** 1 header word only.
//!   - Header: same layout as fill header but op=0x01.
//!
//! ## Expected (`l1_cache_wrap_exp.hex`)
//!
//! Word 0: `{32'b0, lookup_count[31:0]}` — number of lookup results.
//!
//! Per lookup: 4 × 64-bit words, one per bank texel.
//!   `{28'b0, texel[35:0]}` — 36-bit UQ1.8 RGBA packed as `{A[8:0], B[8:0], G[8:0], R[8:0]}`.
//!
//! Usage: `cargo run --bin gen_l1_cache_wrap_vectors -- <output_dir>`

use gs_tex_l1_cache::{DecodedBlockProvider, TextureBlockCache};
use gs_twin_core::texel::TexelUq18;
use qfixed::UQ;
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

// ── Constants ───────────────────────────────────────────────────────────────

/// RGB565 texture format code (matching RTL tex_format encoding).
const FMT_RGB565: u8 = 5;

/// RGB565 burst length in 16-bit words.
const BURST_LEN_RGB565: usize = 16;

// ── Operation types ─────────────────────────────────────────────────────────

/// A cache fill operation: load raw RGB565 data into the cache.
struct FillOp {
    /// Texture base address in SRAM (16-bit word address).
    tex_base_addr: u32,

    /// Pixel X coordinate (used to derive block_x = pixel_x / 4).
    pixel_x: u16,

    /// Pixel Y coordinate (used to derive block_y = pixel_y / 4).
    pixel_y: u16,

    /// Texture format (always `FMT_RGB565` in this generator).
    tex_format: u8,

    /// Log2 of texture width in pixels (e.g., 6 for 64-pixel texture).
    tex_width_log2: u8,

    /// Raw RGB565 u16 words for the 4x4 block (16 words, row-major).
    raw_data: [u16; 16],
}

/// A cache lookup operation: request texels for a pixel coordinate.
struct LookupOp {
    /// Texture base address in SRAM (16-bit word address).
    tex_base_addr: u32,

    /// Pixel X coordinate.
    pixel_x: u16,

    /// Pixel Y coordinate.
    pixel_y: u16,

    /// Texture format.
    tex_format: u8,

    /// Log2 of texture width in pixels.
    tex_width_log2: u8,
}

/// Tagged union of fill and lookup operations.
enum Op {
    /// Fill the cache with a decoded block.
    Fill(FillOp),

    /// Look up texels from the cache.
    Lookup(LookupOp),
}

// ── Texel helpers ───────────────────────────────────────────────────────────

/// Pack a `TexelUq18` into 36-bit RTL wire format: `{R[35:27], G[26:18], B[17:9], A[8:0]}`.
fn pack_texel(t: &TexelUq18) -> u64 {
    let r = t.r.to_bits() & 0x1FF;
    let g = t.g.to_bits() & 0x1FF;
    let b = t.b.to_bits() & 0x1FF;
    let a = t.a.to_bits() & 0x1FF;
    (r << 27) | (g << 18) | (b << 9) | a
}

/// Expand a 5-bit channel to 9-bit UQ1.8 (matching RTL MSB-replication + correction).
fn ch5_to_uq18(ch5: u16) -> u16 {
    ((ch5 << 3) | (ch5 >> 2)) + (ch5 >> 4)
}

/// Expand a 6-bit channel to 9-bit UQ1.8 (matching RTL MSB-replication + correction).
fn ch6_to_uq18(ch6: u16) -> u16 {
    ((ch6 << 2) | (ch6 >> 4)) + (ch6 >> 5)
}

/// Decode an RGB565 word to `TexelUq18`.
fn rgb565_to_texel(raw: u16) -> TexelUq18 {
    let r5 = (raw >> 11) & 0x1F;
    let g6 = (raw >> 5) & 0x3F;
    let b5 = raw & 0x1F;
    TexelUq18 {
        r: UQ::from_bits(u64::from(ch5_to_uq18(r5))),
        g: UQ::from_bits(u64::from(ch6_to_uq18(g6))),
        b: UQ::from_bits(u64::from(ch5_to_uq18(b5))),
        a: UQ::from_bits(0x100),
    }
}

/// Decode a full 4x4 block of RGB565 raw words into `TexelUq18` array.
fn decode_rgb565_block(raw: &[u16; 16]) -> [TexelUq18; 16] {
    let mut block = [TexelUq18::default(); 16];
    for (i, texel) in block.iter_mut().enumerate() {
        *texel = rgb565_to_texel(raw[i]);
    }
    block
}

// ── Stimulus packing ────────────────────────────────────────────────────────

/// Pack an operation header into a 64-bit word.
///
/// Layout: `{op[7:0], tex_width_log2[7:0], 5'b0 fmt[2:0], 6'b0 pixel_y[9:0], 6'b0 pixel_x[9:0], tex_base_addr[23:0]}`
///
/// Bit assignments:
///   - `[23:0]`  = tex_base_addr
///   - `[33:24]` = pixel_x
///   - `[43:34]` = pixel_y
///   - `[46:44]` = tex_format
///   - `[55:48]` = tex_width_log2
///   - `[63:56]` = op_type (0=fill, 1=lookup)
fn pack_header(op_type: u8, base: u32, px: u16, py: u16, fmt: u8, wlog2: u8) -> u64 {
    let mut w: u64 = 0;
    w |= u64::from(base) & 0x00FF_FFFF;
    w |= (u64::from(px) & 0x3FF) << 24;
    w |= (u64::from(py) & 0x3FF) << 34;
    w |= (u64::from(fmt) & 0x7) << 44;
    w |= u64::from(wlog2) << 48;
    w |= u64::from(op_type) << 56;
    w
}

// ── WRAP-mode coordinate helpers ────────────────────────────────────────────

/// Compute the WRAP-mode pixel coordinate for bilinear neighbor offsets.
///
/// # Arguments
///
/// * `pixel` - Current pixel coordinate (0..tex_size-1).
/// * `tex_size` - Texture dimension in pixels (power of 2).
///
/// # Returns
///
/// Wrapped pixel coordinate.
fn wrap_coord(pixel: u16, tex_size: u16) -> u16 {
    pixel % tex_size
}

/// Compute block coordinate from pixel coordinate.
fn block_of(pixel: u16) -> u16 {
    pixel >> 2
}

/// Compute the local index within a 4x4 block from pixel coordinates.
///
/// Row-major: `local = (pixel_y % 4) * 4 + (pixel_x % 4)`.
fn local_index(px: u16, py: u16) -> u32 {
    let lx = u32::from(px & 3);
    let ly = u32::from(py & 3);
    ly * 4 + lx
}

// ── Test vector generation ──────────────────────────────────────────────────

/// Generate a deterministic RGB565 value for a texel at the given global pixel position.
///
/// Uses a simple hash to create visually distinct values per position.
fn pixel_rgb565(global_x: u16, global_y: u16) -> u16 {
    let x = u32::from(global_x);
    let y = u32::from(global_y);
    // Hash: mix coordinates to get distinct per-pixel values
    let hash = (x.wrapping_mul(7) ^ y.wrapping_mul(13))
        .wrapping_add(x)
        .wrapping_add(y);
    let r5 = (hash & 0x1F) as u16;
    let g6 = ((hash >> 5) & 0x3F) as u16;
    let b5 = ((hash >> 11) & 0x1F) as u16;
    (r5 << 11) | (g6 << 5) | b5
}

/// Build a raw RGB565 block for the 4x4 texels starting at (block_x*4, block_y*4).
fn build_block(block_x: u16, block_y: u16, tex_size: u16) -> [u16; 16] {
    let mut raw = [0u16; 16];
    let base_px = block_x * 4;
    let base_py = block_y * 4;
    for ty in 0..4u16 {
        for tx in 0..4u16 {
            let gx = wrap_coord(base_px + tx, tex_size);
            let gy = wrap_coord(base_py + ty, tex_size);
            raw[(ty * 4 + tx) as usize] = pixel_rgb565(gx, gy);
        }
    }
    raw
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() > 1 {
        args[1].clone()
    } else {
        "../rtl/tests/vectors".to_string()
    };
    let out = Path::new(&out_dir);
    fs::create_dir_all(out).expect("create output dir");

    let tex_size: u16 = 64; // 64x64 texture
    let tex_width_log2: u8 = 6; // log2(64) = 6
    let tex_base_addr: u32 = 0x1000; // Arbitrary base address
    let _blocks_per_row = tex_size / 4; // 16 blocks per row

    let mut ops: Vec<Op> = Vec::new();
    let mut cache = TextureBlockCache::new();
    let mut filled_blocks: Vec<(u16, u16)> = Vec::new();

    // Helper: base word address for the cache (the twin uses base_words, which
    // is the 16-bit word address stored in TEXn_BASE).
    let base_words = tex_base_addr;

    // Helper closure: emit a fill op for the given block if not already filled.
    let maybe_fill = |bx: u16,
                      by: u16,
                      filled_blocks: &mut Vec<(u16, u16)>,
                      cache: &mut TextureBlockCache,
                      ops: &mut Vec<Op>| {
        if filled_blocks.contains(&(bx, by)) {
            return;
        }
        let raw = build_block(bx, by, tex_size);
        let decoded = decode_rgb565_block(&raw);
        cache.fill(base_words, u32::from(bx), u32::from(by), decoded);
        ops.push(Op::Fill(FillOp {
            tex_base_addr,
            pixel_x: bx * 4,
            pixel_y: by * 4,
            tex_format: FMT_RGB565,
            tex_width_log2,
            raw_data: raw,
        }));
        filled_blocks.push((bx, by));
    };

    // ── Category 1: Interior samples (no wrapping) ──────────────────────

    // Sample at center of texture: pixel (32,32), (33,33), (34,34), (35,35)
    let interior_coords: [(u16, u16); 4] = [(32, 32), (33, 33), (34, 34), (35, 35)];

    for &(px, py) in &interior_coords {
        let bx = block_of(px);
        let by = block_of(py);
        maybe_fill(bx, by, &mut filled_blocks, &mut cache, &mut ops);
    }

    // Now do lookups at interior coordinates
    for &(px, py) in &interior_coords {
        ops.push(Op::Lookup(LookupOp {
            tex_base_addr,
            pixel_x: px,
            pixel_y: py,
            tex_format: FMT_RGB565,
            tex_width_log2,
        }));
    }

    // ── Category 2: Edge samples (wrapping at boundaries) ───────────────

    // Top edge: y=0, various x
    // Bottom edge: y=63, various x
    // Left edge: x=0, various y
    // Right edge: x=63, various y
    let edge_coords: [(u16, u16); 8] = [
        (16, 0),  // top edge, interior x
        (32, 0),  // top edge, center x
        (16, 63), // bottom edge, interior x
        (32, 63), // bottom edge, center x
        (0, 16),  // left edge, interior y
        (0, 32),  // left edge, center y
        (63, 16), // right edge, interior y
        (63, 32), // right edge, center y
    ];

    // Fill blocks needed for edge samples.
    // For WRAP mode, at boundary pixels the bilinear quad may need blocks
    // from the opposite edge. We fill the block containing each edge pixel.
    for &(px, py) in &edge_coords {
        let bx = block_of(px);
        let by = block_of(py);
        maybe_fill(bx, by, &mut filled_blocks, &mut cache, &mut ops);
    }

    // Lookups for edge coordinates
    for &(px, py) in &edge_coords {
        ops.push(Op::Lookup(LookupOp {
            tex_base_addr,
            pixel_x: px,
            pixel_y: py,
            tex_format: FMT_RGB565,
            tex_width_log2,
        }));
    }

    // ── Category 3: Corner samples ──────────────────────────────────────

    let corner_coords: [(u16, u16); 4] = [
        (0, 0),   // top-left corner
        (63, 0),  // top-right corner
        (0, 63),  // bottom-left corner
        (63, 63), // bottom-right corner
    ];

    for &(px, py) in &corner_coords {
        let bx = block_of(px);
        let by = block_of(py);
        maybe_fill(bx, by, &mut filled_blocks, &mut cache, &mut ops);
    }

    // Lookups for corner coordinates
    for &(px, py) in &corner_coords {
        ops.push(Op::Lookup(LookupOp {
            tex_base_addr,
            pixel_x: px,
            pixel_y: py,
            tex_format: FMT_RGB565,
            tex_width_log2,
        }));
    }

    // ── Category 4: Additional wrap-boundary fill + lookup ──────────────
    //
    // Fill blocks along the right edge (block_x=15) and bottom edge
    // (block_y=15) so that lookups near those boundaries can hit.
    // Also fill block (0,0) separately if not already filled, to support
    // wrap-around lookups that refer back to the origin.

    let extra_blocks: [(u16, u16); 4] = [
        (15, 0),  // right-edge blocks for top row
        (0, 15),  // bottom-edge blocks for left column
        (15, 15), // bottom-right corner block
        (14, 14), // near-corner block
    ];

    for &(bx, by) in &extra_blocks {
        maybe_fill(bx, by, &mut filled_blocks, &mut cache, &mut ops);
    }

    // Lookups at sub-block positions within these extra blocks
    let extra_lookups: [(u16, u16); 4] = [
        (60, 0),  // block (15,0), local (0,0)
        (0, 60),  // block (0,15), local (0,0)
        (61, 61), // block (15,15), local (1,1)
        (57, 57), // block (14,14), local (1,1)
    ];

    for &(px, py) in &extra_lookups {
        ops.push(Op::Lookup(LookupOp {
            tex_base_addr,
            pixel_x: px,
            pixel_y: py,
            tex_format: FMT_RGB565,
            tex_width_log2,
        }));
    }

    // ── Write hex files ─────────────────────────────────────────────────

    let total_ops = ops.len();
    let lookup_count = ops.iter().filter(|o| matches!(o, Op::Lookup(_))).count();

    let mut stim = String::new();
    let mut exp = String::new();

    // First line: operation count for stim, lookup count for exp
    writeln!(stim, "{total_ops:016x}").unwrap();
    writeln!(exp, "{lookup_count:016x}").unwrap();

    for op in &ops {
        match op {
            Op::Fill(f) => {
                // Header word: op=0
                let hdr = pack_header(
                    0x00,
                    f.tex_base_addr,
                    f.pixel_x,
                    f.pixel_y,
                    f.tex_format,
                    f.tex_width_log2,
                );
                writeln!(stim, "{hdr:016x}").unwrap();

                // Pack 16 u16 raw words into 8 × 64-bit words (2 u16 per 32 bits, 4 per 64 bits)
                for chunk_idx in 0..BURST_LEN_RGB565 / 2 {
                    let w0 = u64::from(f.raw_data[chunk_idx * 2]);
                    let w1 = u64::from(f.raw_data[chunk_idx * 2 + 1]);
                    let packed = w0 | (w1 << 16);
                    writeln!(stim, "{packed:016x}").unwrap();
                }
            }
            Op::Lookup(l) => {
                // Header word: op=1
                let hdr = pack_header(
                    0x01,
                    l.tex_base_addr,
                    l.pixel_x,
                    l.pixel_y,
                    l.tex_format,
                    l.tex_width_log2,
                );
                writeln!(stim, "{hdr:016x}").unwrap();

                // Compute expected output from the twin.
                // The RTL returns 4 bank texels based on the pixel's sub-block position.
                // Bank read address selects the quad: pixel_x[1], pixel_y[1] pick which
                // 2x2 quad within the 4x4 block.
                // The 4 texels returned are from the 4 banks at the same sub-address.
                let bx = block_of(l.pixel_x);
                let by = block_of(l.pixel_y);
                let quad_x = (l.pixel_x >> 1) & 1; // pixel_x[1]
                let quad_y = (l.pixel_y >> 1) & 1; // pixel_y[1]

                // The RTL reads one texel per bank at sub-address = {quad_y, quad_x}.
                // Bank 0 (even_x, even_y): texel at local (quad_x*2, quad_y*2)
                // Bank 1 (odd_x, even_y):  texel at local (quad_x*2+1, quad_y*2)
                // Bank 2 (even_x, odd_y):  texel at local (quad_x*2, quad_y*2+1)
                // Bank 3 (odd_x, odd_y):   texel at local (quad_x*2+1, quad_y*2+1)
                let lx_base = quad_x * 2;
                let ly_base = quad_y * 2;

                let local_0 = local_index(lx_base, ly_base);
                let local_1 = local_index(lx_base + 1, ly_base);
                let local_2 = local_index(lx_base, ly_base + 1);
                let local_3 = local_index(lx_base + 1, ly_base + 1);

                let coords = [
                    (base_words, u32::from(bx), u32::from(by), local_0),
                    (base_words, u32::from(bx), u32::from(by), local_1),
                    (base_words, u32::from(bx), u32::from(by), local_2),
                    (base_words, u32::from(bx), u32::from(by), local_3),
                ];

                let texels = cache
                    .gather_bilinear_quad(&coords)
                    .expect("all blocks should be cached for lookup");

                for t in &texels {
                    writeln!(exp, "{:016x}", pack_texel(t)).unwrap();
                }
            }
        }
    }

    fs::write(out.join("l1_cache_wrap_stim.hex"), stim).unwrap();
    fs::write(out.join("l1_cache_wrap_exp.hex"), exp).unwrap();

    eprintln!(
        "L1 cache WRAP vectors written to {}: {} ops ({} fills, {} lookups)",
        out.display(),
        total_ops,
        total_ops - lookup_count,
        lookup_count
    );
}
