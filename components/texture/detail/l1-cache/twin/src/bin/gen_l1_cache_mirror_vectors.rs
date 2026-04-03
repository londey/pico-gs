//! Generate MIRROR-mode test vectors for DT-verified L1 texture cache testbench.
//!
//! Produces `l1_cache_mirror_stim.hex` (stimulus) and `l1_cache_mirror_exp.hex`
//! (expected output).
//! The SV testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! # Hex Format
//!
//! ## Stimulus (`l1_cache_mirror_stim.hex`)
//!
//! First line: vector count (64-bit hex).
//!
//! Each vector is a sequence of 64-bit hex words:
//!
//! **Word 0 — command header:**
//!   `{cmd[63:62], reserved[61:56], tex_width_log2[55:48],
//!     tex_format[47:45], tex_base_addr[44:21],
//!     pixel_y[20:11], pixel_x[10:1], burst_len[0] }`
//!
//! Simplified packing (avoids straddled fields):
//!   - `[63:62]` = cmd: 0=FILL, 1=LOOKUP
//!   - `[55:48]` = tex_width_log2
//!   - `[47:45]` = tex_format
//!   - `[44:21]` = tex_base_addr
//!   - `[20:11]` = pixel_y
//!   - `[10:1]`  = pixel_x
//!   - `[0]`     = reserved (0)
//!
//! For FILL commands, additional words follow:
//!   - Word 1: `{48'b0, burst_len[15:0]}`
//!   - Words 2..2+burst_len-1: `{48'b0, sram_data[15:0]}` (one per burst word)
//!
//! For LOOKUP commands, no additional words.
//!
//! ## Expected (`l1_cache_mirror_exp.hex`)
//!
//! First line: number of expected results (64-bit hex).
//!
//! Each expected result is 3 x 64-bit words (one per LOOKUP):
//!   - Word 0: `{28'b0, texel_out_0[35:0]}`
//!   - Word 1: `{28'b0, texel_out_1[35:0]}`
//!   - Word 2: `{remaining: texel_out_2[35:0] in [35:0], texel_out_3[35:0] in high}`
//!
//! Actually, for simpler parsing, each expected result is 4 x 64-bit words:
//!   - Word 0: `{28'b0, texel_out_0[35:0]}`
//!   - Word 1: `{28'b0, texel_out_1[35:0]}`
//!   - Word 2: `{28'b0, texel_out_2[35:0]}`
//!   - Word 3: `{28'b0, texel_out_3[35:0]}`
//!
//! Usage: `cargo run --bin gen_l1_cache_mirror_vectors -- <output_dir>`

use gs_tex_l1_cache::{DecodedBlockProvider, TextureBlockCache};
use gs_twin_core::texel::TexelUq18;
use qfixed::UQ;
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

    gen_mirror_vectors(out);

    eprintln!("L1 cache MIRROR test vectors written to {}", out.display());
}

// ── RGB565 decode (inlined to avoid circular dependency) ────────────────────

/// Expand a 5-bit channel to 9-bit UQ1.8 via MSB-replication + correction.
///
/// Matches RTL `fp_types_pkg::ch5_to_uq18`.
fn ch5_to_uq18(ch5: u16) -> u16 {
    ((ch5 << 3) | (ch5 >> 2)) + (ch5 >> 4)
}

/// Expand a 6-bit channel to 9-bit UQ1.8 via MSB-replication + correction.
///
/// Matches RTL `fp_types_pkg::ch6_to_uq18`.
fn ch6_to_uq18(ch6: u16) -> u16 {
    ((ch6 << 2) | (ch6 >> 4)) + (ch6 >> 5)
}

/// Convert an RGB565 word to [`TexelUq18`] (fully opaque).
fn rgb565_to_uq18(raw: u16) -> TexelUq18 {
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

/// Decode a full 4x4 RGB565 block from raw 16-bit words.
///
/// # Arguments
///
/// * `raw` - 16 u16 words in row-major order.
///
/// # Returns
///
/// 16 decoded texels in row-major order.
fn decode_rgb565_block(raw: &[u16; 16]) -> [TexelUq18; 16] {
    let mut block = [TexelUq18::default(); 16];
    for (i, texel) in block.iter_mut().enumerate() {
        *texel = rgb565_to_uq18(raw[i]);
    }
    block
}

// ── Texel packing ───────────────────────────────────────────────────────────

/// Pack a `TexelUq18` into 36-bit RTL wire format: `{R[35:27], G[26:18], B[17:9], A[8:0]}`.
fn pack_texel(t: &TexelUq18) -> u64 {
    let r = t.r.to_bits() & 0x1FF;
    let g = t.g.to_bits() & 0x1FF;
    let b = t.b.to_bits() & 0x1FF;
    let a = t.a.to_bits() & 0x1FF;
    (r << 27) | (g << 18) | (b << 9) | a
}

// ── Simple deterministic PRNG (xorshift32) ──────────────────────────────────

struct Xorshift32(u32);

impl Xorshift32 {
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    /// Generate a random RGB565 pixel.
    fn next_rgb565(&mut self) -> u16 {
        self.next() as u16
    }
}

// ── MIRROR address computation ──────────────────────────────────────────────

/// Apply MIRROR-mode addressing to a pixel coordinate.
///
/// For a texture of `tex_size` pixels (power of 2), MIRROR reflects at edges:
/// coordinates outside `[0, tex_size-1]` fold back symmetrically.
///
/// # Arguments
///
/// * `coord` - The raw pixel coordinate (may be negative or beyond size).
/// * `tex_size` - Texture dimension in pixels (must be power of 2).
///
/// # Returns
///
/// The mirrored coordinate in `[0, tex_size-1]`.
fn mirror_coord(coord: i32, tex_size: i32) -> u32 {
    // Normalize to [0, 2*tex_size) period
    let period = tex_size * 2;
    let mut c = coord % period;
    if c < 0 {
        c += period;
    }
    // If in [tex_size, 2*tex_size), mirror back
    if c >= tex_size {
        (period - 1 - c) as u32
    } else {
        c as u32
    }
}

// ── Test vector types ───────────────────────────────────────────────────────

/// Command type for the testbench.
enum Command {
    /// Fill the cache: provide burst data for a specific block.
    Fill {
        pixel_x: u32,
        pixel_y: u32,
        tex_base_addr: u32,
        tex_format: u32,
        tex_width_log2: u32,
        raw_data: Vec<u16>,
    },
    /// Lookup: request texels for a pixel coordinate.
    Lookup {
        pixel_x: u32,
        pixel_y: u32,
        tex_base_addr: u32,
        tex_format: u32,
        tex_width_log2: u32,
    },
}

/// Expected result for a LOOKUP command (4 bank texels).
struct ExpectedResult {
    texel_out: [u64; 4],
}

// ── SRAM model ──────────────────────────────────────────────────────────────

/// Simple SRAM model storing 16-bit words, keyed by word address.
struct SramModel {
    data: Vec<u16>,
}

impl SramModel {
    fn new(size: usize) -> Self {
        Self {
            data: vec![0u16; size],
        }
    }

    /// Write a 4x4 RGB565 block at the appropriate SRAM address.
    ///
    /// # Arguments
    ///
    /// * `base_addr` - Texture base address (16-bit word address).
    /// * `block_x` - Block X coordinate.
    /// * `block_y` - Block Y coordinate.
    /// * `tex_width_log2` - Log2 of texture width.
    /// * `raw` - 16 u16 words of RGB565 data.
    fn write_rgb565_block(
        &mut self,
        base_addr: u32,
        block_x: u32,
        block_y: u32,
        tex_width_log2: u32,
        raw: &[u16; 16],
    ) {
        let blocks_per_row = 1u32 << (tex_width_log2 - 2);
        let block_index = block_y * blocks_per_row + block_x;
        // RGB565: block_sram_addr = base + block_index * 16 (16 words per block)
        let addr = base_addr + block_index * 16;
        for (i, &word) in raw.iter().enumerate() {
            self.data[(addr as usize) + i] = word;
        }
    }

    /// Read burst data for a block.
    ///
    /// # Arguments
    ///
    /// * `addr` - Start address (16-bit word address).
    /// * `len` - Number of words.
    ///
    /// # Returns
    ///
    /// Vector of 16-bit words.
    fn read_burst(&self, addr: u32, len: u32) -> Vec<u16> {
        (0..len)
            .map(|i| self.data[(addr as usize) + (i as usize)])
            .collect()
    }
}

// ── Vector generation ───────────────────────────────────────────────────────

fn gen_mirror_vectors(out: &Path) {
    let tex_width_log2: u32 = 6; // 64x64 texture
    let tex_size: i32 = 1 << tex_width_log2; // 64
    let tex_base_addr: u32 = 0x1000; // Arbitrary base address
    let tex_format: u32 = 5; // RGB565
    let burst_len: u32 = 16; // RGB565 burst length

    let mut rng = Xorshift32(0xCAFE_BABE);
    let mut sram = SramModel::new(0x10_0000);
    let mut cache = TextureBlockCache::new();

    // Pre-populate SRAM with known texel data for the entire 64x64 texture.
    // Each block is 4x4 pixels, so we have 16x16 blocks.
    let blocks_per_row = tex_size / 4;
    let mut block_raw_data: Vec<[u16; 16]> = Vec::new();
    for by in 0..blocks_per_row {
        for bx in 0..blocks_per_row {
            let mut raw = [0u16; 16];
            for word in &mut raw {
                *word = rng.next_rgb565();
            }
            sram.write_rgb565_block(tex_base_addr, bx as u32, by as u32, tex_width_log2, &raw);
            block_raw_data.push(raw);
        }
    }

    let mut commands: Vec<Command> = Vec::new();
    let mut expected: Vec<ExpectedResult> = Vec::new();

    // Helper: compute SRAM address for a block
    let block_sram_addr = |bx: u32, by: u32| -> u32 {
        let block_index = by * (blocks_per_row as u32) + bx;
        tex_base_addr + block_index * 16
    };

    // Helper: get raw data for a block
    let get_block_raw = |bx: u32, by: u32| -> [u16; 16] {
        let idx = (by as usize) * (blocks_per_row as usize) + (bx as usize);
        block_raw_data[idx]
    };

    // Test coordinates for MIRROR mode.
    // For bilinear sampling, the cache reads a 2x2 quad of texels centered
    // on the sample point. At edges, MIRROR mode reflects the neighbor.
    //
    // The L1 cache itself doesn't do address mirroring — it receives
    // pixel_x/pixel_y that have already been mirror-resolved by the UV
    // coordinate unit upstream. For this testbench, we test that the cache
    // correctly fills and returns data for coordinates near edges, where
    // multiple blocks may be needed for the bilinear quad.
    //
    // Test plan:
    // 1. Fill blocks needed for each sample point
    // 2. Lookup and verify returned texels match twin

    // Define sample coordinates to test
    let sample_coords: Vec<(u32, u32, &str)> = vec![
        // Middle of texture
        (32, 32, "center (32,32)"),
        (33, 33, "center (33,33)"),
        (30, 30, "center (30,30)"),
        (31, 31, "center (31,31)"),
        // Top edge (y=0)
        (32, 0, "top edge (32,0)"),
        // Bottom edge (y=63)
        (32, 63, "bottom edge (32,63)"),
        // Left edge (x=0)
        (0, 32, "left edge (0,32)"),
        // Right edge (x=63)
        (63, 32, "right edge (63,32)"),
        // Corners
        (0, 0, "corner (0,0)"),
        (63, 0, "corner (63,0)"),
        (0, 63, "corner (0,63)"),
        (63, 63, "corner (63,63)"),
        // Near block boundaries (not at texture edge)
        (3, 3, "block boundary (3,3)"),
        (4, 4, "block boundary (4,4)"),
        (7, 7, "block boundary (7,7)"),
        (8, 8, "block boundary (8,8)"),
    ];

    // For each sample, determine the block(s) needed, fill them, then lookup.
    // For MIRROR mode at edges, the mirrored neighbor is within the same texture,
    // so we just need to fill the blocks that contain the mirrored coordinates.
    //
    // The bilinear sample reads a 2x2 quad. For pixel at (px, py):
    //   Quad texels: (px, py), (px+1, py), (px, py+1), (px+1, py+1)
    // With MIRROR, px+1 at the right edge (63) mirrors to px=62.
    // The cache doesn't care about mirroring — it gets the final coordinates.
    // So we compute the mirrored coordinates and fill the relevant blocks.

    let mut filled_blocks: Vec<(u32, u32)> = Vec::new();

    for &(px, py, _label) in &sample_coords {
        // Compute the 4 bilinear neighbor coordinates with MIRROR wrapping
        let coords = [
            (px, py),
            (mirror_coord(px as i32 + 1, tex_size), py),
            (px, mirror_coord(py as i32 + 1, tex_size)),
            (
                mirror_coord(px as i32 + 1, tex_size),
                mirror_coord(py as i32 + 1, tex_size),
            ),
        ];

        // Determine which blocks need filling
        for &(cx, cy) in &coords {
            let bx = cx / 4;
            let by = cy / 4;
            if !filled_blocks.contains(&(bx, by)) {
                let raw = get_block_raw(bx, by);
                let decoded = decode_rgb565_block(&raw);

                // Fill the twin cache
                cache.fill(tex_base_addr, bx, by, decoded);

                // Compute SRAM address for this block
                let addr = block_sram_addr(bx, by);
                let burst_data = sram.read_burst(addr, burst_len);

                // Emit FILL command: use pixel coords that map to this block
                commands.push(Command::Fill {
                    pixel_x: bx * 4,
                    pixel_y: by * 4,
                    tex_base_addr,
                    tex_format,
                    tex_width_log2,
                    raw_data: burst_data,
                });

                filled_blocks.push((bx, by));
            }
        }

        // Now emit a LOOKUP for the primary coordinate.
        // The RTL will read 4 texels (one per bank) at the sub-block address
        // determined by pixel_x[1] and pixel_y[1].
        commands.push(Command::Lookup {
            pixel_x: px,
            pixel_y: py,
            tex_base_addr,
            tex_format,
            tex_width_log2,
        });

        // Compute expected outputs from the twin.
        // The RTL reads 4 texels from a single cache line at the address
        // determined by the lookup. It reads from the block containing (px, py)
        // at the sub-address (pixel_x[1], pixel_y[1]).
        //
        // Bank address = {set_index[4:0], hit_way, pixel_y[1], pixel_x[1]}
        // This reads the 4 interleaved texels at that sub-position.
        let bx = px / 4;
        let by = py / 4;
        let raw = get_block_raw(bx, by);
        let decoded = decode_rgb565_block(&raw);

        // The sub-address selects which 2x2 quad within the 4x4 block.
        // pixel_x[1] and pixel_y[1] select the quad.
        let qx = (px >> 1) & 1; // pixel_x[1]
        let qy = (py >> 1) & 1; // pixel_y[1]

        // Within the 4x4 block, the banks store texels interleaved by parity:
        //   bank0 (even_x, even_y): row-major positions where lx[0]=0, ly[0]=0
        //   bank1 (odd_x,  even_y): lx[0]=1, ly[0]=0
        //   bank2 (even_x, odd_y):  lx[0]=0, ly[0]=1
        //   bank3 (odd_x,  odd_y):  lx[0]=1, ly[0]=1
        //
        // Bank read address includes {quad_y, quad_x} as the slot selector.
        // The read returns one texel per bank at slot = {qy, qx}.
        //
        // For write_count = sub_addr = {qy, qx}:
        //   bank0 texel: t = {qy, 0, qx, 0} = qy*8 + qx*2
        //   bank1 texel: t = {qy, 0, qx, 1} = qy*8 + qx*2 + 1
        //   bank2 texel: t = {qy, 1, qx, 0} = qy*8 + 4 + qx*2
        //   bank3 texel: t = {qy, 1, qx, 1} = qy*8 + 4 + qx*2 + 1
        let t0 = (qy * 8 + qx * 2) as usize;
        let t1 = (qy * 8 + qx * 2 + 1) as usize;
        let t2 = (qy * 8 + 4 + qx * 2) as usize;
        let t3 = (qy * 8 + 4 + qx * 2 + 1) as usize;

        expected.push(ExpectedResult {
            texel_out: [
                pack_texel(&decoded[t0]),
                pack_texel(&decoded[t1]),
                pack_texel(&decoded[t2]),
                pack_texel(&decoded[t3]),
            ],
        });
    }

    // ── Write hex files ─────────────────────────────────────────────────────

    let num_lookups = expected.len();
    let mut stim = String::new();
    let mut exp = String::new();

    // Count total commands
    let num_commands = commands.len();
    writeln!(stim, "{num_commands:016x}").unwrap();
    writeln!(exp, "{num_lookups:016x}").unwrap();

    for cmd in &commands {
        match cmd {
            Command::Fill {
                pixel_x,
                pixel_y,
                tex_base_addr,
                tex_format,
                tex_width_log2,
                raw_data,
            } => {
                // Header word: cmd=0 (FILL), bits [63:62] = 00
                let header: u64 = ((*tex_width_log2 as u64 & 0xFF) << 48)
                    | ((*tex_format as u64 & 0x7) << 45)
                    | ((*tex_base_addr as u64 & 0xFF_FFFF) << 21)
                    | ((*pixel_y as u64 & 0x3FF) << 11)
                    | ((*pixel_x as u64 & 0x3FF) << 1);
                writeln!(stim, "{header:016x}").unwrap();

                // Burst length word
                let bl = raw_data.len() as u64;
                writeln!(stim, "{bl:016x}").unwrap();

                // Burst data words
                for &word in raw_data {
                    writeln!(stim, "{:016x}", word as u64).unwrap();
                }
            }
            Command::Lookup {
                pixel_x,
                pixel_y,
                tex_base_addr,
                tex_format,
                tex_width_log2,
            } => {
                // Header word: cmd=1 (LOOKUP)
                let header: u64 = (1u64 << 62)
                    | ((*tex_width_log2 as u64 & 0xFF) << 48)
                    | ((*tex_format as u64 & 0x7) << 45)
                    | ((*tex_base_addr as u64 & 0xFF_FFFF) << 21)
                    | ((*pixel_y as u64 & 0x3FF) << 11)
                    | ((*pixel_x as u64 & 0x3FF) << 1);
                writeln!(stim, "{header:016x}").unwrap();
            }
        }
    }

    for e in &expected {
        for &texel in &e.texel_out {
            writeln!(exp, "{texel:016x}").unwrap();
        }
    }

    fs::write(out.join("l1_cache_mirror_stim.hex"), stim).unwrap();
    fs::write(out.join("l1_cache_mirror_exp.hex"), exp).unwrap();

    eprintln!(
        "  mirror: {} commands ({} fills, {} lookups)",
        num_commands,
        num_commands - num_lookups,
        num_lookups
    );
}
