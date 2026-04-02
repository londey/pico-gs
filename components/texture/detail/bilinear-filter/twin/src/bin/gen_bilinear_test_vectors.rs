//! Generate test vector hex files for DT-verified bilinear filter RTL testbench.
//!
//! Produces `bilinear_stim.hex` (stimulus) and `bilinear_exp.hex` (expected output).
//! The SV testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! Usage: cargo run --bin gen_bilinear_test_vectors -- <output_dir>

use gs_tex_bilinear_filter::bilinear_blend;
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

    gen_bilinear(out);

    eprintln!("Bilinear test vectors written to {}", out.display());
}

// ── Texel packing ───────────────────────────────────────────────────────────

/// Pack a `TexelUq18` into 36-bit RTL wire format: `{A[35:27], B[26:18], G[17:9], R[8:0]}`.
fn pack_texel(t: &TexelUq18) -> u64 {
    let r = t.r.to_bits() & 0x1FF;
    let g = t.g.to_bits() & 0x1FF;
    let b = t.b.to_bits() & 0x1FF;
    let a = t.a.to_bits() & 0x1FF;
    (a << 27) | (b << 18) | (g << 9) | r
}

/// Create a `TexelUq18` from raw 9-bit channel values.
fn texel(r: u16, g: u16, b: u16, a: u16) -> TexelUq18 {
    TexelUq18 {
        r: UQ::from_bits(u64::from(r)),
        g: UQ::from_bits(u64::from(g)),
        b: UQ::from_bits(u64::from(b)),
        a: UQ::from_bits(u64::from(a)),
    }
}

// ── Weight computation (matching RTL and DT) ────────────────────────────────

/// Compute bilinear weights from frac_u/frac_v, matching `compute_bilinear_taps()`
/// in `lib.rs` lines 195-208 and the RTL weight logic.
fn compute_weights(frac_u: u8, frac_v: u8) -> [UQ<1, 8>; 4] {
    let fu = frac_u as u32;
    let fv = frac_v as u32;
    let ifu = 0x100 - fu;
    let ifv = 0x100 - fv;
    [
        UQ::from_bits(((ifu * ifv) >> 8) as u64),
        UQ::from_bits(((fu * ifv) >> 8) as u64),
        UQ::from_bits(((ifu * fv) >> 8) as u64),
        UQ::from_bits(((fu * fv) >> 8) as u64),
    ]
}

// ── Test vector types ───────────────────────────────────────────────────────

struct TestVector {
    frac_u: u8,
    frac_v: u8,
    is_bilinear: bool,
    texels: [TexelUq18; 4],
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

    fn next_u9(&mut self) -> u16 {
        (self.next() & 0x1FF) as u16
    }

    fn next_u8(&mut self) -> u8 {
        self.next() as u8
    }

    fn rand_texel(&mut self) -> TexelUq18 {
        texel(
            self.next_u9(),
            self.next_u9(),
            self.next_u9(),
            self.next_u9(),
        )
    }
}

// ── Vector generation ───────────────────────────────────────────────────────

fn gen_bilinear(out: &Path) {
    let mut vectors: Vec<TestVector> = Vec::new();

    // Fixed texel sets for structured tests
    let zero = texel(0, 0, 0, 0);
    let max9 = texel(0x1FF, 0x1FF, 0x1FF, 0x1FF);
    let one = texel(0x100, 0x100, 0x100, 0x100);
    let half = texel(0x80, 0x80, 0x80, 0x80);

    // Category 1: Nearest mode (is_bilinear=0) — output must equal tap0
    let nearest_taps = [
        [zero, max9, one, half],
        [max9, zero, zero, zero],
        [one, zero, max9, half],
        [texel(0x0AB, 0x0CD, 0x0EF, 0x012), zero, zero, zero],
        [texel(0x1FF, 0, 0, 0), zero, zero, zero],
        [texel(0, 0x1FF, 0, 0), zero, zero, zero],
        [texel(0, 0, 0x1FF, 0), zero, zero, zero],
        [texel(0, 0, 0, 0x1FF), zero, zero, zero],
    ];
    for taps in &nearest_taps {
        for &fu in &[0u8, 0x80, 0xFF] {
            vectors.push(TestVector {
                frac_u: fu,
                frac_v: fu,
                is_bilinear: false,
                texels: *taps,
            });
        }
    }

    // Category 2: Boundary fractions with distinct per-tap texels
    let distinct_taps = [
        texel(0x100, 0, 0, 0), // tap0: R=1.0
        texel(0, 0x100, 0, 0), // tap1: G=1.0
        texel(0, 0, 0x100, 0), // tap2: B=1.0
        texel(0, 0, 0, 0x100), // tap3: A=1.0
    ];
    let boundary_fracs: [(u8, u8); 9] = [
        (0x00, 0x00), // all weight on tap0
        (0xFF, 0x00), // weight on tap1
        (0x00, 0xFF), // weight on tap2
        (0xFF, 0xFF), // weight on tap3
        (0x80, 0x00), // half u, no v
        (0x00, 0x80), // no u, half v
        (0x80, 0x80), // half/half
        (0x40, 0xC0), // quarter/three-quarter
        (0xC0, 0x40), // three-quarter/quarter
    ];
    for &(fu, fv) in &boundary_fracs {
        vectors.push(TestVector {
            frac_u: fu,
            frac_v: fv,
            is_bilinear: true,
            texels: distinct_taps,
        });
    }

    // Also with uniform texels (all same → output should equal that texel)
    for &(fu, fv) in &boundary_fracs {
        vectors.push(TestVector {
            frac_u: fu,
            frac_v: fv,
            is_bilinear: true,
            texels: [one, one, one, one],
        });
    }

    // Category 3: Single-axis sweep
    let sweep_steps: [u8; 9] = [0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0, 0xFF];
    // U-axis sweep (fv=0): interpolates between tap0 and tap1
    for &fu in &sweep_steps {
        vectors.push(TestVector {
            frac_u: fu,
            frac_v: 0,
            is_bilinear: true,
            texels: [
                texel(0, 0, 0, 0),
                texel(0x100, 0x100, 0x100, 0x100),
                zero,
                zero,
            ],
        });
    }
    // V-axis sweep (fu=0): interpolates between tap0 and tap2
    for &fv in &sweep_steps {
        vectors.push(TestVector {
            frac_u: 0,
            frac_v: fv,
            is_bilinear: true,
            texels: [
                texel(0, 0, 0, 0),
                zero,
                texel(0x100, 0x100, 0x100, 0x100),
                zero,
            ],
        });
    }

    // Category 4: Texel corner cases
    // All zeros → output zero
    vectors.push(TestVector {
        frac_u: 0x80,
        frac_v: 0x80,
        is_bilinear: true,
        texels: [zero, zero, zero, zero],
    });
    // All max → output near max
    vectors.push(TestVector {
        frac_u: 0x80,
        frac_v: 0x80,
        is_bilinear: true,
        texels: [max9, max9, max9, max9],
    });
    // Single channel non-zero on each tap
    for tap_idx in 0..4 {
        for ch in 0..4 {
            let mut taps = [zero; 4];
            let mut channels = [0u16; 4];
            channels[ch] = 0x100;
            taps[tap_idx] = texel(channels[0], channels[1], channels[2], channels[3]);
            vectors.push(TestVector {
                frac_u: 0x80,
                frac_v: 0x80,
                is_bilinear: true,
                texels: taps,
            });
        }
    }

    // Category 5: Diagonal sweep (fu=fv)
    for step in 0..32 {
        let f = (step * 8).min(255) as u8;
        vectors.push(TestVector {
            frac_u: f,
            frac_v: f,
            is_bilinear: true,
            texels: distinct_taps,
        });
    }

    // Category 6: Seeded PRNG random vectors
    let mut rng = Xorshift32(0xDEAD_BEEF);
    for _ in 0..300 {
        vectors.push(TestVector {
            frac_u: rng.next_u8(),
            frac_v: rng.next_u8(),
            is_bilinear: true,
            texels: [
                rng.rand_texel(),
                rng.rand_texel(),
                rng.rand_texel(),
                rng.rand_texel(),
            ],
        });
    }

    // ── Write hex files ─────────────────────────────────────────────────────

    let num = vectors.len();
    let mut stim = String::new();
    let mut exp = String::new();

    // First line: vector count
    writeln!(stim, "{num:016x}").unwrap();
    writeln!(exp, "{num:016x}").unwrap();

    for v in &vectors {
        // Stimulus: 5 × 64-bit words per vector
        let ctrl: u64 = (u64::from(v.is_bilinear as u8) << 16)
            | (u64::from(v.frac_u) << 8)
            | u64::from(v.frac_v);
        writeln!(stim, "{ctrl:016x}").unwrap();
        for t in &v.texels {
            writeln!(stim, "{:016x}", pack_texel(t)).unwrap();
        }

        // Expected output
        let expected = if v.is_bilinear {
            let weights = compute_weights(v.frac_u, v.frac_v);
            bilinear_blend(&v.texels, &weights)
        } else {
            v.texels[0]
        };
        writeln!(exp, "{:016x}", pack_texel(&expected)).unwrap();
    }

    fs::write(out.join("bilinear_stim.hex"), stim).unwrap();
    fs::write(out.join("bilinear_exp.hex"), exp).unwrap();

    eprintln!("  bilinear: {num} vectors");
}
