// Spec-ref: unit_011.01_uv_coordinate_processing.md

//! Generate test vector hex files for the DT-verified UV coordinate RTL
//! testbench (UNIT-011.01).
//!
//! Produces `uv_coord_stim.hex` (stimulus) and `uv_coord_exp.hex`
//! (expected outputs) under `rtl/components/texture/detail/uv-coord/tests/vectors/`.
//! The Verilator testbench loads both via `$readmemh` and compares RTL
//! output against the digital twin.
//!
//! Output layout (NEAREST INDEXED8_2X2):
//!
//! Stimulus (1x 64-bit word):
//!   [63:48] u_q412
//!   [47:32] v_q412
//!   [31:28] width_log2
//!   [27:24] height_log2
//!   [23:22] u_wrap
//!   [21:20] v_wrap
//!   [19:0]  reserved (zero)
//!
//! Expected (1x 64-bit word):
//!   [63:32] reserved (zero)
//!   [31:22] u_idx (10-bit)  -- u_wrapped >> 1
//!   [21:12] v_idx (10-bit)  -- v_wrapped >> 1
//!   [11:10] quadrant (2-bit) -- {v_wrapped[0], u_wrapped[0]}
//!   [9:0]   reserved (zero)
//!
//! Usage: `cargo run --bin gen_uv_coord_vectors [-- <output_dir>]`

#![deny(unsafe_code)]

use gpu_registers::components::wrap_mode_e::WrapModeE;
use gs_tex_uv_coord::{compute_quadrant, UvCoord};
use std::fmt::Write as FmtWrite;
use std::fs;
use std::path::Path;

// ── Test vector type ────────────────────────────────────────────────────────

/// All inputs needed for one UV coordinate test vector.
struct TestVector {
    /// U coordinate as raw Q4.12 bits.
    u_q412: u16,

    /// V coordinate as raw Q4.12 bits.
    v_q412: u16,

    /// Log2 of apparent texture width.
    width_log2: u8,

    /// Log2 of apparent texture height.
    height_log2: u8,

    /// U-axis wrap mode.
    u_wrap: WrapModeE,

    /// V-axis wrap mode.
    v_wrap: WrapModeE,
}

// ── Simple deterministic PRNG (xorshift32) ──────────────────────────────────

struct Xorshift32(u32);

impl Xorshift32 {
    /// Advance the PRNG and return the next 32-bit value.
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    /// Return a random 16-bit value (Q4.12 range).
    fn next_u16(&mut self) -> u16 {
        self.next() as u16
    }

    /// Return a random 4-bit value (dimension log2 range 1..=10).
    /// `INT-014` requires `size_log2 >= 1`.
    fn next_dim_log2(&mut self) -> u8 {
        ((self.next() % 10) + 1) as u8
    }

    /// Return a random wrap mode (0..3).
    fn next_wrap(&mut self) -> WrapModeE {
        WrapModeE::from_bits((self.next() & 3) as u8).expect("valid wrap mode")
    }
}

// ── Hex packing helpers ─────────────────────────────────────────────────────

/// Pack a stimulus vector into a single 64-bit word.
fn pack_stim(v: &TestVector) -> u64 {
    let u = u64::from(v.u_q412);
    let vi = u64::from(v.v_q412);
    let wl = u64::from(v.width_log2);
    let hl = u64::from(v.height_log2);
    let uw = u64::from(v.u_wrap.bits());
    let vw = u64::from(v.v_wrap.bits());

    (u << 48) | (vi << 32) | (wl << 28) | (hl << 24) | (uw << 22) | (vw << 20)
}

/// Expected output for one vector: 1x 64-bit word.
struct ExpectedOutput {
    /// Half-resolution U index (10-bit).
    u_idx: u16,

    /// Half-resolution V index (10-bit).
    v_idx: u16,

    /// Quadrant selector `{v_wrapped[0], u_wrapped[0]}`.
    quadrant: u8,
}

impl ExpectedOutput {
    /// Pack into the single expected-output word.
    fn word(&self) -> u64 {
        let u = u64::from(self.u_idx & 0x3FF);
        let v = u64::from(self.v_idx & 0x3FF);
        let q = u64::from(self.quadrant & 0x3);

        (u << 22) | (v << 12) | (q << 10)
    }
}

// ── Twin evaluation ─────────────────────────────────────────────────────────

/// Evaluate the digital twin for a single test vector and produce expected
/// output.
fn evaluate(v: &TestVector) -> ExpectedOutput {
    let (u_idx, u_low) = UvCoord::process(v.u_q412 as i16, v.u_wrap, v.width_log2);
    let (v_idx, v_low) = UvCoord::process(v.v_q412 as i16, v.v_wrap, v.height_log2);
    let quadrant = compute_quadrant(u_low, v_low);

    ExpectedOutput {
        u_idx,
        v_idx,
        quadrant,
    }
}

// ── Q4.12 helper ────────────────────────────────────────────────────────────

/// Encode a floating-point value to Q4.12 raw bits (16-bit unsigned
/// representation).
fn q412(val: f64) -> u16 {
    let scaled = (val * 4096.0).round() as i16;
    scaled as u16
}

// ── Vector generation ───────────────────────────────────────────────────────

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let out_dir = if args.len() > 1 {
        args[1].clone()
    } else {
        "../rtl/tests/vectors".to_string()
    };
    let out = Path::new(&out_dir);
    fs::create_dir_all(out).expect("create output dir");

    let vectors = generate_vectors();
    write_hex_files(out, &vectors);

    eprintln!(
        "UV coordinate test vectors written to {} ({} vectors)",
        out.display(),
        vectors.len()
    );
}

/// Build the complete list of test vectors across all categories.
fn generate_vectors() -> Vec<TestVector> {
    let mut vectors: Vec<TestVector> = Vec::new();

    generate_repeat(&mut vectors);
    generate_clamp(&mut vectors);
    generate_mirror(&mut vectors);
    generate_various_sizes(&mut vectors);
    generate_non_square(&mut vectors);
    generate_quadrant_walk(&mut vectors);
    generate_edge_cases(&mut vectors);
    generate_random(&mut vectors);

    vectors
}

/// Category 1: REPEAT wrap -- includes negative, in-range, and beyond-edge UVs.
fn generate_repeat(vectors: &mut Vec<TestVector>) {
    let wrap = WrapModeE::Repeat;
    let uv_values: &[u16] = &[
        q412(0.0),
        q412(0.5),
        q412(0.999),
        q412(1.0),
        q412(1.5),
        q412(3.75),
        q412(-0.25),
        q412(-1.0),
        q412(-0.001),
        q412(7.9),
    ];

    for dim_log2 in [3u8, 5, 7] {
        for &u_val in uv_values {
            for &v_val in &[q412(0.0), q412(0.5), q412(-0.25)] {
                vectors.push(TestVector {
                    u_q412: u_val,
                    v_q412: v_val,
                    width_log2: dim_log2,
                    height_log2: dim_log2,
                    u_wrap: wrap,
                    v_wrap: wrap,
                });
            }
        }
    }
}

/// Category 2: CLAMP-TO-EDGE -- negative UVs clamp to 0, large UVs clamp
/// to size-1.
fn generate_clamp(vectors: &mut Vec<TestVector>) {
    let wrap = WrapModeE::ClampToEdge;
    let uv_values: &[u16] = &[
        q412(0.0),
        q412(0.5),
        q412(0.999),
        q412(1.0),
        q412(2.0),
        q412(-0.5),
        q412(-1.0),
        q412(-3.0),
        q412(7.9),
    ];

    for dim_log2 in [3u8, 5, 8] {
        for &u_val in uv_values {
            vectors.push(TestVector {
                u_q412: u_val,
                v_q412: q412(0.5),
                width_log2: dim_log2,
                height_log2: dim_log2,
                u_wrap: wrap,
                v_wrap: wrap,
            });
        }
    }
}

/// Category 3: MIRROR -- verify reflection at boundaries and quadrant swap.
fn generate_mirror(vectors: &mut Vec<TestVector>) {
    let wrap = WrapModeE::Mirror;
    let uv_values: &[u16] = &[
        q412(0.0),
        q412(0.25),
        q412(0.5),
        q412(0.75),
        q412(0.999),
        q412(1.0),
        q412(1.25),
        q412(1.5),
        q412(1.75),
        q412(1.999),
        q412(-0.25),
        q412(-0.5),
        q412(-1.0),
    ];

    for dim_log2 in [3u8, 5] {
        for &u_val in uv_values {
            vectors.push(TestVector {
                u_q412: u_val,
                v_q412: q412(0.5),
                width_log2: dim_log2,
                height_log2: dim_log2,
                u_wrap: wrap,
                v_wrap: wrap,
            });
        }
    }
}

/// Category 4: Various texture sizes -- size_log2 from 1 to 10.
/// `INT-014` requires `size_log2 >= 1` so the half-resolution index is at
/// least one bit wide.
fn generate_various_sizes(vectors: &mut Vec<TestVector>) {
    for dim_log2 in 1u8..=10 {
        for &u_val in &[q412(0.0), q412(0.5), q412(0.999)] {
            vectors.push(TestVector {
                u_q412: u_val,
                v_q412: q412(0.5),
                width_log2: dim_log2,
                height_log2: dim_log2,
                u_wrap: WrapModeE::Repeat,
                v_wrap: WrapModeE::Repeat,
            });
        }
    }
}

/// Category 5: Non-square textures -- different width_log2 and height_log2.
fn generate_non_square(vectors: &mut Vec<TestVector>) {
    let dim_pairs: &[(u8, u8)] = &[
        (3, 5),
        (5, 3),
        (4, 8),
        (8, 4),
        (1, 10),
        (10, 1),
        (6, 7),
        (7, 6),
    ];

    for &(wl, hl) in dim_pairs {
        for &u_val in &[q412(0.0), q412(0.5), q412(0.999), q412(-0.25)] {
            vectors.push(TestVector {
                u_q412: u_val,
                v_q412: q412(0.5),
                width_log2: wl,
                height_log2: hl,
                u_wrap: WrapModeE::Repeat,
                v_wrap: WrapModeE::Repeat,
            });
        }
    }
}

/// Category 6: Quadrant walk -- step through (apparent_u, apparent_v) in
/// {0,1,2,3} x {0,1,2,3} so every NW/NE/SW/SE combination is exercised at
/// every half-res index.
fn generate_quadrant_walk(vectors: &mut Vec<TestVector>) {
    // size = 4, size_log2 = 2 -> uv step of 0.25 yields apparent 0..3.
    let steps: [u16; 4] = [q412(0.0), q412(0.25), q412(0.5), q412(0.75)];

    for &u_val in &steps {
        for &v_val in &steps {
            vectors.push(TestVector {
                u_q412: u_val,
                v_q412: v_val,
                width_log2: 2,
                height_log2: 2,
                u_wrap: WrapModeE::Repeat,
                v_wrap: WrapModeE::Repeat,
            });
        }
    }
}

/// Category 7: Edge cases -- UV = 0, UV = max positive Q4.12, UV = max
/// negative Q4.12, etc.
fn generate_edge_cases(vectors: &mut Vec<TestVector>) {
    let special_uvs: &[u16] = &[
        0x0000, // zero
        0x7FFF, // max positive Q4.12 (~+7.9998)
        0x8000, // max negative Q4.12 (-8.0)
        0xFFFF, // -1 LSB (~-0.00024)
        0x0001, // +1 LSB (~+0.00024)
        0x1000, // exactly +1.0
        0xF000, // exactly -1.0
    ];

    let wraps = [
        WrapModeE::Repeat,
        WrapModeE::ClampToEdge,
        WrapModeE::Mirror,
        WrapModeE::Octahedral,
    ];

    let v_vals: &[u16] = &[0x0000, 0x7FFF, 0x8000];

    for &wrap in &wraps {
        for &u_val in special_uvs {
            push_v_variants(vectors, u_val, v_vals, 5, 5, wrap, wrap);
        }
    }
}

/// Push a vector for each V value in `v_vals`, sharing all other fields.
fn push_v_variants(
    vectors: &mut Vec<TestVector>,
    u_q412: u16,
    v_vals: &[u16],
    width_log2: u8,
    height_log2: u8,
    u_wrap: WrapModeE,
    v_wrap: WrapModeE,
) {
    for &v_q412 in v_vals {
        vectors.push(TestVector {
            u_q412,
            v_q412,
            width_log2,
            height_log2,
            u_wrap,
            v_wrap,
        });
    }
}

/// Category 8: Random vectors -- seeded PRNG sweep for broad coverage.
fn generate_random(vectors: &mut Vec<TestVector>) {
    let mut rng = Xorshift32(0xCAFE_BABE);

    for _ in 0..300 {
        vectors.push(TestVector {
            u_q412: rng.next_u16(),
            v_q412: rng.next_u16(),
            width_log2: rng.next_dim_log2(),
            height_log2: rng.next_dim_log2(),
            u_wrap: rng.next_wrap(),
            v_wrap: rng.next_wrap(),
        });
    }
}

/// Write stimulus and expected hex files to the output directory.
///
/// # Arguments
///
/// * `out` -- Output directory path.
/// * `vectors` -- Slice of test vectors to serialize.
fn write_hex_files(out: &Path, vectors: &[TestVector]) {
    let num = vectors.len();
    let mut stim = String::new();
    let mut exp = String::new();

    // First line: vector count.
    writeln!(stim, "{num:016x}").unwrap();
    writeln!(exp, "{num:016x}").unwrap();

    for v in vectors {
        writeln!(stim, "{:016x}", pack_stim(v)).unwrap();

        let expected = evaluate(v);
        writeln!(exp, "{:016x}", expected.word()).unwrap();
    }

    fs::write(out.join("uv_coord_stim.hex"), stim).unwrap();
    fs::write(out.join("uv_coord_exp.hex"), exp).unwrap();

    eprintln!("  uv_coord: {num} vectors");
}
