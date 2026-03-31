//! Generate test vector hex files for DT-verified rasterizer RTL testbenches.
//!
//! Each module gets a stimulus hex and an expected-output hex file.
//! The testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! Usage: cargo run --bin gen_raster_test_vectors -- <output_dir>

use gs_rasterizer::attr_accum::{self, AttrAccum};
use gs_rasterizer::deriv::{self, NUM_ATTRS};
use gs_rasterizer::dsp_mul;
use gs_rasterizer::recip;
use gs_rasterizer::setup::{self, EdgeCoeffs};
use gs_twin_core::triangle::{RasterTriangle, RasterVertex, Rgba8888};
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

    gen_recip_area(out);
    gen_recip_q(out);
    gen_dsp_mul(out);
    gen_shift_mul(out);
    gen_deriv(out);
    gen_attr_accum(out);

    eprintln!("Test vectors written to {}", out.display());
}

// ── recip_area ────────────────────────────────────────────────────────────

fn gen_recip_area(out: &Path) {
    let mut stim = String::new();
    let mut exp = String::new();

    // 22-bit signed range: [-2^21, 2^21 - 1] = [-2097152, 2097151]
    let min22: i32 = -(1 << 21);
    let max22: i32 = (1 << 21) - 1;
    let clamp = |v: i32| v.clamp(min22, max22);

    let mut areas: Vec<i32> = vec![0, 1, -1, 2, -2];

    // Powers of 2 (within 22-bit range)
    for shift in 0..21 {
        areas.push(1 << shift);
        areas.push(-(1 << shift));
    }
    areas.push(min22); // -2^21 (min 22-bit signed)

    // CLZ boundary values (just above and below each power of 2)
    for shift in 1..22 {
        let v = 1i32 << shift;
        areas.push(clamp(v - 1));
        areas.push(clamp(v + 1));
        areas.push(clamp(-(v - 1)));
        areas.push(clamp(-(v + 1)));
    }

    // Small values
    for v in 3..=20 {
        areas.push(v);
        areas.push(-v);
    }

    // Large values near 22-bit max
    areas.push(max22);
    areas.push(-max22);
    areas.push(max22 - 1);
    areas.push(max22 / 2);

    // Typical rasterizer area values
    for v in [
        64, 100, 128, 200, 255, 256, 500, 1000, 4096, 8192, 16384, 32768, 65536,
    ] {
        areas.push(v);
        areas.push(-v);
    }

    // Sweep: every 8th value in 0..512 range
    for v in (0..512).step_by(8) {
        areas.push(v);
    }

    // Dedup
    areas.sort();
    areas.dedup();

    // First line: vector count
    writeln!(stim, "{:08x}", areas.len()).unwrap();
    writeln!(exp, "{:08x}", areas.len()).unwrap();

    for &area in &areas {
        // Stimulus: 32-bit hex (sign-extended from 22-bit)
        let area_bits = area as u32;
        writeln!(stim, "{:08x}", area_bits).unwrap();

        // Expected: pack {degenerate, area_shift[4:0], recip_out[17:0]}
        match recip::recip_area(area) {
            Some(r) => {
                let packed = ((r.area_shift as u32) << 18) | (r.mantissa & 0x3_FFFF);
                writeln!(exp, "{:08x}", packed).unwrap();
            }
            None => {
                // Degenerate: degenerate=1, rest=0
                let packed = 1u32 << 24;
                writeln!(exp, "{:08x}", packed).unwrap();
            }
        }
    }

    fs::write(out.join("recip_area_stim.hex"), stim).unwrap();
    fs::write(out.join("recip_area_exp.hex"), exp).unwrap();
    eprintln!("  recip_area: {} vectors", areas.len());
}

// ── recip_q ───────────────────────────────────────────────────────────────

fn gen_recip_q(out: &Path) {
    let mut stim = String::new();
    let mut exp = String::new();

    let mut operands: Vec<u32> = vec![
        0, 1, 0x8000, // 1.0 in UQ1.15
        0x4000, // 0.5
        0xFFFF, // max UQ1.15
    ];

    // Powers of 2
    for shift in 0..16 {
        operands.push(1 << shift);
    }

    // Typical Q values (UQ1.15 range)
    for v in [
        0x0001, 0x0002, 0x0010, 0x0100, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000, 0x3000, 0x4000,
        0x5000, 0x6000, 0x7000, 0x7FFF, 0x8000, 0x9000, 0xA000, 0xB000, 0xC000, 0xD000, 0xE000,
        0xF000, 0xFFFF,
    ] {
        operands.push(v);
    }

    // Sweep: every 256th value in full UQ1.15 range
    for v in (0u32..=0xFFFF).step_by(256) {
        operands.push(v);
    }

    // CLZ boundary values
    for shift in 1..16 {
        let v = 1u32 << shift;
        operands.push(v - 1);
        operands.push(v);
        operands.push(v + 1);
    }

    operands.sort();
    operands.dedup();

    // First line: vector count
    writeln!(stim, "{:08x}", operands.len()).unwrap();
    writeln!(exp, "{:08x}", operands.len()).unwrap();

    for &op in &operands {
        writeln!(stim, "{:08x}", op).unwrap();

        let r = recip::recip_q(op);
        // Pack: {clz_out[4:0], recip_out[17:0]}
        let packed = ((r.clz as u32 & 0x1F) << 18) | (r.recip & 0x3_FFFF);
        writeln!(exp, "{:08x}", packed).unwrap();
    }

    fs::write(out.join("recip_q_stim.hex"), stim).unwrap();
    fs::write(out.join("recip_q_exp.hex"), exp).unwrap();
    eprintln!("  recip_q: {} vectors", operands.len());
}

// ── dsp_mul ───────────────────────────────────────────────────────────────

fn gen_dsp_mul(out: &Path) {
    let mut stim = String::new();
    let mut exp = String::new();
    let mut count = 0u32;

    let a_vals: Vec<i32> = vec![
        0,
        1,
        -1,
        2,
        -2,
        127,
        -128,
        255,
        -256,
        1000,
        -1000,
        0xFFFF,   // 17-bit max positive
        -0x10000, // 17-bit min negative
        0x0FFFF,
        -0x0FFFF,
        42,
        -42,
        0x1_0000 - 1, // 65535
    ];

    let b_vals: Vec<u32> = vec![
        0, 1, 2, 0x3FFFF, // 18-bit max
        0x20000, // UQ1.17 = 1.0
        0x10000, 0x08000, 0x04000, 0x00001, 100, 1000, 50000, 131072,
    ];

    // First line: vector count
    let count_total = a_vals.len() * b_vals.len();
    writeln!(stim, "{:016x}", count_total as u64).unwrap();
    writeln!(exp, "{:016x}", count_total as u64).unwrap();

    for &a in &a_vals {
        for &b in &b_vals {
            // Pack: a[16:0] in bits [49:32], b[17:0] in bits [17:0]
            let a_bits = a as u32;
            let b_bits = b & 0x3_FFFF;
            let packed = ((a_bits as u64) << 32) | (b_bits as u64);
            writeln!(stim, "{:016x}", packed).unwrap();

            let product = dsp_mul::dsp_mul(a, b);
            // Product as 64-bit hex (sign-extended)
            writeln!(exp, "{:016x}", product as u64).unwrap();
            count += 1;
        }
    }

    fs::write(out.join("dsp_mul_stim.hex"), stim).unwrap();
    fs::write(out.join("dsp_mul_exp.hex"), exp).unwrap();
    eprintln!("  dsp_mul: {} vectors", count);
}

// ── shift_mul_32x11 ──────────────────────────────────────────────────────

fn gen_shift_mul(out: &Path) {
    let mut stim = String::new();
    let mut exp = String::new();
    let mut count = 0u32;

    let a_vals: Vec<i32> = vec![
        0,
        1,
        -1,
        0x7FFF_FFFF,
        -0x7FFF_FFFF,
        0x0010_0000,
        -0x0010_0000,
        42,
        -42,
        1000,
        -1000,
        0x00FF_0000, // typical derivative
        -0x00FF_0000,
        0x0000_FFFF,
        0x1234_5678,
    ];

    let b_vals: Vec<i32> = vec![
        0, 1, -1, 0x3FF,  // 11-bit max positive
        -0x400, // 11-bit min negative
        2, -2, 5, -5, 100, -100, 0x200, -0x200,
    ];

    // First line: vector count
    let count_total = a_vals.len() * b_vals.len();
    writeln!(stim, "{:016x}", count_total as u64).unwrap();
    writeln!(exp, "{:08x}", count_total as u32).unwrap();

    for &a in &a_vals {
        for &b in &b_vals {
            let a_bits = a as u32;
            let b_bits = (b as u32) & 0x7FF; // 11-bit mask
                                             // Pack: a[31:0] in bits [42:11], b[10:0] in bits [10:0]
            let packed = ((a_bits as u64) << 11) | (b_bits as u64);
            writeln!(stim, "{:016x}", packed).unwrap();

            let product = dsp_mul::shift_mul_32x11(a, b);
            writeln!(exp, "{:08x}", product as u32).unwrap();
            count += 1;
        }
    }

    fs::write(out.join("shift_mul_stim.hex"), stim).unwrap();
    fs::write(out.join("shift_mul_exp.hex"), exp).unwrap();
    eprintln!("  shift_mul: {} vectors", count);
}

// ── deriv ─────────────────────────────────────────────────────────────────

/// A test triangle with all inputs needed for raster_deriv.
struct DerivTestCase {
    tri: RasterTriangle,
    name: &'static str,
}

fn make_deriv_test_cases() -> Vec<DerivTestCase> {
    vec![
        // Case 0: Simple Gouraud triangle, CCW, origin-based
        DerivTestCase {
            name: "simple_gouraud_ccw",
            tri: RasterTriangle {
                verts: [
                    RasterVertex {
                        px: 10,
                        py: 10,
                        z: 0x8000,
                        q: 0x4000,
                        color0: Rgba8888(0xFF000000),
                        color1: Rgba8888(0x00FF0000),
                        s0: 0,
                        t0: 0,
                        s1: 0,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 100,
                        py: 10,
                        z: 0x4000,
                        q: 0x4000,
                        color0: Rgba8888(0x00FF0000),
                        color1: Rgba8888(0x0000FF00),
                        s0: 0x1000,
                        t0: 0,
                        s1: 0x1000,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 10,
                        py: 100,
                        z: 0x2000,
                        q: 0x8000,
                        color0: Rgba8888(0x0000FF00),
                        color1: Rgba8888(0x000000FF),
                        s0: 0,
                        t0: 0x1000,
                        s1: 0,
                        t1: 0x1000,
                    },
                ],
                bbox_min_x: 10,
                bbox_max_x: 100,
                bbox_min_y: 10,
                bbox_max_y: 100,
                gouraud_en: true,
            },
        },
        // Case 1: Flat-shaded (gouraud disabled), all same colors
        DerivTestCase {
            name: "flat_shaded",
            tri: RasterTriangle {
                verts: [
                    RasterVertex {
                        px: 0,
                        py: 0,
                        z: 0xFFFF,
                        q: 0x8000,
                        color0: Rgba8888(0x80808080),
                        color1: Rgba8888(0),
                        s0: 0,
                        t0: 0,
                        s1: 0,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 50,
                        py: 0,
                        z: 0xFFFF,
                        q: 0x8000,
                        color0: Rgba8888(0x80808080),
                        color1: Rgba8888(0),
                        s0: 0x0800,
                        t0: 0,
                        s1: 0,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 0,
                        py: 50,
                        z: 0xFFFF,
                        q: 0x8000,
                        color0: Rgba8888(0x80808080),
                        color1: Rgba8888(0),
                        s0: 0,
                        t0: 0x0800,
                        s1: 0,
                        t1: 0,
                    },
                ],
                bbox_min_x: 0,
                bbox_max_x: 50,
                bbox_min_y: 0,
                bbox_max_y: 50,
                gouraud_en: false,
            },
        },
        // Case 2: CW winding (v0 and v1 swapped from case 0)
        DerivTestCase {
            name: "cw_winding",
            tri: RasterTriangle {
                verts: [
                    RasterVertex {
                        px: 100,
                        py: 10,
                        z: 0x4000,
                        q: 0x4000,
                        color0: Rgba8888(0x00FF0000),
                        color1: Rgba8888(0),
                        s0: 0x1000,
                        t0: 0,
                        s1: 0,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 10,
                        py: 10,
                        z: 0x8000,
                        q: 0x4000,
                        color0: Rgba8888(0xFF000000),
                        color1: Rgba8888(0),
                        s0: 0,
                        t0: 0,
                        s1: 0,
                        t1: 0,
                    },
                    RasterVertex {
                        px: 10,
                        py: 100,
                        z: 0x2000,
                        q: 0x8000,
                        color0: Rgba8888(0x0000FF00),
                        color1: Rgba8888(0),
                        s0: 0,
                        t0: 0x1000,
                        s1: 0,
                        t1: 0,
                    },
                ],
                bbox_min_x: 10,
                bbox_max_x: 100,
                bbox_min_y: 10,
                bbox_max_y: 100,
                gouraud_en: true,
            },
        },
        // Case 3: Large triangle with offset bbox
        DerivTestCase {
            name: "large_offset_bbox",
            tri: RasterTriangle {
                verts: [
                    RasterVertex {
                        px: 200,
                        py: 200,
                        z: 0x1000,
                        q: 0x2000,
                        color0: Rgba8888(0xFFFF0000),
                        color1: Rgba8888(0x00FFFF00),
                        s0: 0xF000u16,
                        t0: 0xF000u16,
                        s1: 0x0100,
                        t1: 0x0100,
                    },
                    RasterVertex {
                        px: 400,
                        py: 200,
                        z: 0xC000,
                        q: 0x6000,
                        color0: Rgba8888(0x00FF00FF),
                        color1: Rgba8888(0xFF00FF00),
                        s0: 0x1000,
                        t0: 0xF000u16,
                        s1: 0x0200,
                        t1: 0x0100,
                    },
                    RasterVertex {
                        px: 200,
                        py: 400,
                        z: 0x8000,
                        q: 0x4000,
                        color0: Rgba8888(0x0000FFFF),
                        color1: Rgba8888(0xFFFF00FF),
                        s0: 0xF000u16,
                        t0: 0x1000,
                        s1: 0x0100,
                        t1: 0x0200,
                    },
                ],
                bbox_min_x: 200,
                bbox_max_x: 400,
                bbox_min_y: 200,
                bbox_max_y: 400,
                gouraud_en: true,
            },
        },
        // Case 4: Small triangle near origin with varied Q
        DerivTestCase {
            name: "small_varied_q",
            tri: RasterTriangle {
                verts: [
                    RasterVertex {
                        px: 0,
                        py: 0,
                        z: 0x0100,
                        q: 0x8000,
                        color0: Rgba8888(0xFF804020),
                        color1: Rgba8888(0x20408080),
                        s0: 0x0000,
                        t0: 0x0000,
                        s1: 0x0800,
                        t1: 0x0800,
                    },
                    RasterVertex {
                        px: 8,
                        py: 0,
                        z: 0x0200,
                        q: 0x4000,
                        color0: Rgba8888(0x20FF8040),
                        color1: Rgba8888(0x40802020),
                        s0: 0x1000,
                        t0: 0x0000,
                        s1: 0x1000,
                        t1: 0x0800,
                    },
                    RasterVertex {
                        px: 0,
                        py: 8,
                        z: 0x0300,
                        q: 0x2000,
                        color0: Rgba8888(0x408020FF),
                        color1: Rgba8888(0x80204040),
                        s0: 0x0000,
                        t0: 0x1000,
                        s1: 0x0800,
                        t1: 0x1000,
                    },
                ],
                bbox_min_x: 0,
                bbox_max_x: 8,
                bbox_min_y: 0,
                bbox_max_y: 8,
                gouraud_en: true,
            },
        },
    ]
}

fn gen_deriv(out: &Path) {
    let cases = make_deriv_test_cases();
    let mut stim = String::new();
    let mut exp = String::new();
    let mut count = 0u32;

    for tc in &cases {
        let tri = &tc.tri;
        // Run triangle_setup to get edges, area, derivatives
        let setup = match setup::triangle_setup(tri) {
            Some(s) => s,
            None => {
                eprintln!("  deriv: skipping degenerate triangle '{}'", tc.name);
                continue;
            }
        };

        // Stimulus: pack all raster_deriv inputs into hex lines
        // Line 0: vertex colors0 (12 × 8-bit = 96 bits, packed into 128-bit / 2 × 64-bit)
        let [ref v0, ref v1, ref v2] = tri.verts;
        // Pack color0: v0(RGBA) v1(RGBA) v2(RGBA) = 12 bytes
        let c0_word0: u64 = (v0.color0.r() as u64) << 56
            | (v0.color0.g() as u64) << 48
            | (v0.color0.b() as u64) << 40
            | (v0.color0.a() as u64) << 32
            | (v1.color0.r() as u64) << 24
            | (v1.color0.g() as u64) << 16
            | (v1.color0.b() as u64) << 8
            | (v1.color0.a() as u64);
        let c0_word1: u64 = (v2.color0.r() as u64) << 56
            | (v2.color0.g() as u64) << 48
            | (v2.color0.b() as u64) << 40
            | (v2.color0.a() as u64) << 32;

        // Pack color1 similarly
        let c1_word0: u64 = (v0.color1.r() as u64) << 56
            | (v0.color1.g() as u64) << 48
            | (v0.color1.b() as u64) << 40
            | (v0.color1.a() as u64) << 32
            | (v1.color1.r() as u64) << 24
            | (v1.color1.g() as u64) << 16
            | (v1.color1.b() as u64) << 8
            | (v1.color1.a() as u64);
        let c1_word1: u64 = (v2.color1.r() as u64) << 56
            | (v2.color1.g() as u64) << 48
            | (v2.color1.b() as u64) << 40
            | (v2.color1.a() as u64) << 32;

        // Pack Z: z0, z1, z2 (3 × 16-bit = 48 bits)
        let z_word: u64 = (v0.z as u64) << 32 | (v1.z as u64) << 16 | (v2.z as u64);

        // Pack ST0: s0,t0 for 3 verts (6 × 16-bit = 96 bits → 2 words)
        let st0_word0: u64 =
            (v0.s0 as u64) << 48 | (v0.t0 as u64) << 32 | (v1.s0 as u64) << 16 | (v1.t0 as u64);
        let st0_word1: u64 = (v2.s0 as u64) << 48 | (v2.t0 as u64) << 32;

        // Pack ST1
        let st1_word0: u64 =
            (v0.s1 as u64) << 48 | (v0.t1 as u64) << 32 | (v1.s1 as u64) << 16 | (v1.t1 as u64);
        let st1_word1: u64 = (v2.s1 as u64) << 48 | (v2.t1 as u64) << 32;

        // Pack Q: q0, q1, q2
        let q_word: u64 = (v0.q as u64) << 32 | (v1.q as u64) << 16 | (v2.q as u64);

        // Pack edge coefficients + scaling
        let edge1_a = (setup.edges[1].a as u32 as u64) & 0x7FF;
        let edge1_b = (setup.edges[1].b as u32 as u64) & 0x7FF;
        let edge2_a = (setup.edges[2].a as u32 as u64) & 0x7FF;
        let edge2_b = (setup.edges[2].b as u32 as u64) & 0x7FF;
        let inv_area = setup::triangle_setup(tri).unwrap();
        // Re-derive inv_area and area_shift from recip
        let x0 = v0.px as i32;
        let y0 = v0.py as i32;
        let x1 = v1.px as i32;
        let y1 = v1.py as i32;
        let x2 = v2.px as i32;
        let y2 = v2.py as i32;
        let edges_raw = [
            EdgeCoeffs {
                a: y1 - y2,
                b: x2 - x1,
                c: x1 * y2 - x2 * y1,
            },
            EdgeCoeffs {
                a: y2 - y0,
                b: x0 - x2,
                c: x2 * y0 - x0 * y2,
            },
            EdgeCoeffs {
                a: y0 - y1,
                b: x1 - x0,
                c: x0 * y1 - x1 * y0,
            },
        ];
        let area2 = edges_raw[0].a * x0 + edges_raw[0].b * y0 + edges_raw[0].c;
        let ccw = area2 > 0;
        let recip_result = recip::recip_area(area2).unwrap();

        let bbox_min_x = inv_area.bbox_min_x;
        let bbox_min_y = inv_area.bbox_min_y;

        let edge_word: u64 = (edge1_a << 48) | (edge1_b << 37) | (edge2_a << 26) | (edge2_b << 15);

        let scale_word: u64 = ((recip_result.mantissa as u64) << 32)
            | ((recip_result.area_shift as u64) << 24)
            | ((ccw as u64) << 23)
            | ((v0.px as u64) << 13)
            | ((v0.py as u64) << 3)
            | ((tri.gouraud_en as u64) << 2);

        let bbox_word: u64 = ((bbox_min_x as u64) << 16) | (bbox_min_y as u64);

        // Write 14 lines per triangle
        writeln!(stim, "{:016x}", c0_word0).unwrap();
        writeln!(stim, "{:016x}", c0_word1).unwrap();
        writeln!(stim, "{:016x}", c1_word0).unwrap();
        writeln!(stim, "{:016x}", c1_word1).unwrap();
        writeln!(stim, "{:016x}", z_word).unwrap();
        writeln!(stim, "{:016x}", st0_word0).unwrap();
        writeln!(stim, "{:016x}", st0_word1).unwrap();
        writeln!(stim, "{:016x}", st1_word0).unwrap();
        writeln!(stim, "{:016x}", st1_word1).unwrap();
        writeln!(stim, "{:016x}", q_word).unwrap();
        writeln!(stim, "{:016x}", edge_word).unwrap();
        writeln!(stim, "{:016x}", scale_word).unwrap();
        writeln!(stim, "{:016x}", bbox_word).unwrap();

        // Expected: 14 dx + 14 dy + 14 init = 42 words of 32-bit hex
        for i in 0..NUM_ATTRS {
            writeln!(exp, "{:08x}", setup.dx[i] as u32).unwrap();
        }
        for i in 0..NUM_ATTRS {
            writeln!(exp, "{:08x}", setup.dy[i] as u32).unwrap();
        }
        for i in 0..NUM_ATTRS {
            writeln!(exp, "{:08x}", setup.inits[i] as u32).unwrap();
        }

        count += 1;
    }

    fs::write(out.join("deriv_stim.hex"), stim).unwrap();
    fs::write(out.join("deriv_exp.hex"), exp).unwrap();
    eprintln!("  deriv: {} triangles", count);
}

// ── attr_accum ────────────────────────────────────────────────────────────

/// Commands for attr_accum test sequences.
#[repr(u8)]
#[derive(Clone, Copy)]
enum AccumCmd {
    Latch = 0,
    StepX = 1,
    StepY = 2,
    TileColStep = 3,
    TileRowStep = 4,
}

fn gen_attr_accum(out: &Path) {
    let cases = make_deriv_test_cases();
    let mut stim = String::new();
    let mut exp = String::new();
    let mut seq_count = 0u32;

    // Use first two non-degenerate triangles
    for tc in cases.iter().take(3) {
        let setup = match setup::triangle_setup(&tc.tri) {
            Some(s) => s,
            None => continue,
        };

        // Command sequence matching RTL edge_walk control flow:
        // Within a tile: latch, step_x×3, step_y, step_x×3
        // Next tile column: tile_col_step (merges tcol += 4*dx + init row/acc)
        // Within new tile: step_x×3, step_y
        // Next tile row: tile_row_step (merges trow += 4*dy + reset tcol + init row/acc)
        // Within new tile: step_x×3
        let commands = [
            AccumCmd::Latch,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::StepY,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::TileColStep,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::StepX,
            AccumCmd::StepY,
            AccumCmd::TileRowStep,
            AccumCmd::StepX,
            AccumCmd::StepX,
        ];

        // Write initial values (14 dx + 14 dy + 14 init = 42 × 32-bit)
        for i in 0..NUM_ATTRS {
            writeln!(stim, "{:08x}", setup.dx[i] as u32).unwrap();
        }
        for i in 0..NUM_ATTRS {
            writeln!(stim, "{:08x}", setup.dy[i] as u32).unwrap();
        }
        for i in 0..NUM_ATTRS {
            writeln!(stim, "{:08x}", setup.inits[i] as u32).unwrap();
        }

        // Write command count
        writeln!(stim, "{:08x}", commands.len() as u32).unwrap();

        // Write commands
        for &cmd in &commands {
            writeln!(stim, "{:08x}", cmd as u32).unwrap();
        }

        // Run the DT accumulator and capture expected output after each command
        let mut accum = AttrAccum::new(setup.inits, setup.dx, setup.dy);

        for &cmd in &commands {
            match cmd {
                AccumCmd::Latch => {
                    accum = AttrAccum::new(setup.inits, setup.dx, setup.dy);
                }
                AccumCmd::StepX => accum.step_x(),
                AccumCmd::StepY => accum.step_y(),
                AccumCmd::TileColStep => {
                    // RTL merges tcol += 4*dx with init_tile_pixels (row=acc=tcol)
                    accum.step_tile_col();
                    accum.init_tile_pixels();
                }
                AccumCmd::TileRowStep => {
                    // RTL merges trow += 4*dy, tcol = trow, with init_tile_pixels
                    accum.step_tile_row();
                    accum.reset_tile_col();
                    accum.init_tile_pixels();
                }
            }

            // Write expected promoted outputs after this command
            let acc = accum.acc();
            // 8 color channels (Q4.12, 16-bit)
            for &idx in &[
                deriv::ATTR_C0R,
                deriv::ATTR_C0G,
                deriv::ATTR_C0B,
                deriv::ATTR_C0A,
                deriv::ATTR_C1R,
                deriv::ATTR_C1G,
                deriv::ATTR_C1B,
                deriv::ATTR_C1A,
            ] {
                let promoted = attr_accum::promote_color_q412(acc[idx]);
                writeln!(exp, "{:04x}", promoted.to_bits() as u16).unwrap();
            }
            // Z (16-bit unsigned)
            let z = attr_accum::extract_z(acc[deriv::ATTR_Z]);
            writeln!(exp, "{:04x}", z).unwrap();
            // Raw ST/Q accumulators (32-bit each, 5 values)
            for &idx in &[
                deriv::ATTR_S0,
                deriv::ATTR_T0,
                deriv::ATTR_S1,
                deriv::ATTR_T1,
                deriv::ATTR_Q,
            ] {
                writeln!(exp, "{:08x}", acc[idx] as u32).unwrap();
            }
        }

        seq_count += 1;
    }

    fs::write(out.join("attr_accum_stim.hex"), stim).unwrap();
    fs::write(out.join("attr_accum_exp.hex"), exp).unwrap();
    eprintln!("  attr_accum: {} sequences", seq_count);
}
