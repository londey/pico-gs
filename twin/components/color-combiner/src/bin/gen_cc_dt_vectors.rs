//! Generate test vector hex files for DT-verified color combiner RTL testbench.
//!
//! Produces `cc_stim.hex` (stimulus) and `cc_exp.hex` (expected output).
//! The SV testbench loads both via `$readmemh` and compares RTL output against
//! the DT expected values.
//!
//! Usage: `cargo run --bin gen_cc_dt_vectors -- [output_dir]`

#![deny(unsafe_code)]

use gpu_registers::components::cc_rgb_c_source_e::CcRgbCSourceE;
use gpu_registers::components::cc_source_e::CcSourceE;
use gpu_registers::components::gpu_regs::named_types::cc_mode_reg::CcModeReg;
use gs_twin_core::fragment::ColorQ412;
use qfixed::Q;
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

    let vectors = gen_all_vectors();
    write_hex_files(out, &vectors);

    eprintln!(
        "Color combiner test vectors written to {} ({} vectors)",
        out.display(),
        vectors.len()
    );
}

// ── Types ───────────────────────────────────────────────────────────────────

/// A single test vector with stimulus inputs and expected output.
struct TestVector {
    /// CC_MODE register value (64-bit, cycle 0 in [31:0], cycle 1 in [63:32]).
    cc_mode: CcModeReg,

    /// Raw RGBA8888 const colors: CONST0 in [31:0], CONST1 in [63:32].
    const_color_raw: u64,

    /// Texture unit 0 color (Q4.12 RGBA).
    tex0: ColorQ412,

    /// Texture unit 1 color (Q4.12 RGBA).
    tex1: ColorQ412,

    /// Shade color 0 (Q4.12 RGBA).
    shade0: ColorQ412,

    /// Shade color 1 (Q4.12 RGBA).
    shade1: ColorQ412,

    /// Fragment position X.
    frag_x: u16,

    /// Fragment position Y.
    frag_y: u16,

    /// Fragment depth Z.
    frag_z: u16,

    /// Expected final output color (saturated Q4.12 RGBA).
    expected: ColorQ412,
}

// ── Packing helpers ─────────────────────────────────────────────────────────

/// Pack a `ColorQ412` into 64-bit RTL format: `{R[63:48], G[47:32], B[31:16], A[15:0]}`.
fn pack_q412_rgba(c: &ColorQ412) -> u64 {
    let r = (c.r.to_bits() as u16) as u64;
    let g = (c.g.to_bits() as u16) as u64;
    let b = (c.b.to_bits() as u16) as u64;
    let a = (c.a.to_bits() as u16) as u64;
    (r << 48) | (g << 32) | (b << 16) | a
}

/// Pack RGBA channels into a 32-bit word matching RTL byte layout.
///
/// RTL extracts: `const_color[7:0]`=R, `[15:8]`=G, `[23:16]`=B, `[31:24]`=A.
fn pack_rgba_to_rtl(r: u8, g: u8, b: u8, a: u8) -> u32 {
    u32::from(a) << 24 | u32::from(b) << 16 | u32::from(g) << 8 | u32::from(r)
}

/// Pack RGBA8888 into 64-bit const_color register format.
/// CONST0 in [31:0], CONST1 in [63:32].
fn pack_const_color(const0_rgba: u32, const1_rgba: u32) -> u64 {
    (u64::from(const1_rgba) << 32) | u64::from(const0_rgba)
}

/// Extract raw u64 from `CcModeReg` (repr-transparent over u64).
/// Reconstruct raw u64 from `CcModeReg` field-by-field.
///
/// `CcModeReg::to_raw()` is `pub(crate)` in the register crate, so we
/// must round-trip through the public getters.
fn cc_mode_to_u64(mode: CcModeReg) -> u64 {
    let mut val: u64 = 0;
    val |= (mode.c0_rgb_a().bits() as u64) << CcModeReg::C0_RGB_A_OFFSET;
    val |= (mode.c0_rgb_b().bits() as u64) << CcModeReg::C0_RGB_B_OFFSET;
    val |= (mode.c0_rgb_c().bits() as u64) << CcModeReg::C0_RGB_C_OFFSET;
    val |= (mode.c0_rgb_d().bits() as u64) << CcModeReg::C0_RGB_D_OFFSET;
    val |= (mode.c0_alpha_a().bits() as u64) << CcModeReg::C0_ALPHA_A_OFFSET;
    val |= (mode.c0_alpha_b().bits() as u64) << CcModeReg::C0_ALPHA_B_OFFSET;
    val |= (mode.c0_alpha_c().bits() as u64) << CcModeReg::C0_ALPHA_C_OFFSET;
    val |= (mode.c0_alpha_d().bits() as u64) << CcModeReg::C0_ALPHA_D_OFFSET;
    val |= (mode.c1_rgb_a().bits() as u64) << CcModeReg::C1_RGB_A_OFFSET;
    val |= (mode.c1_rgb_b().bits() as u64) << CcModeReg::C1_RGB_B_OFFSET;
    val |= (mode.c1_rgb_c().bits() as u64) << CcModeReg::C1_RGB_C_OFFSET;
    val |= (mode.c1_rgb_d().bits() as u64) << CcModeReg::C1_RGB_D_OFFSET;
    val |= (mode.c1_alpha_a().bits() as u64) << CcModeReg::C1_ALPHA_A_OFFSET;
    val |= (mode.c1_alpha_b().bits() as u64) << CcModeReg::C1_ALPHA_B_OFFSET;
    val |= (mode.c1_alpha_c().bits() as u64) << CcModeReg::C1_ALPHA_C_OFFSET;
    val |= (mode.c1_alpha_d().bits() as u64) << CcModeReg::C1_ALPHA_D_OFFSET;
    val
}

// ── CC_MODE builder helpers ─────────────────────────────────────────────────

/// Passthrough mode for cycle 1: A=COMBINED, B=ZERO, C=ONE, D=ZERO.
fn set_passthrough_c1(mode: &mut CcModeReg) {
    mode.set_c1_rgb_a(CcSourceE::CcCombined);
    mode.set_c1_rgb_b(CcSourceE::CcZero);
    mode.set_c1_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c1_rgb_d(CcSourceE::CcZero);
    mode.set_c1_alpha_a(CcSourceE::CcCombined);
    mode.set_c1_alpha_b(CcSourceE::CcZero);
    mode.set_c1_alpha_c(CcSourceE::CcOne);
    mode.set_c1_alpha_d(CcSourceE::CcZero);
}

// ── RTL-matching evaluation ─────────────────────────────────────────────────
//
// The twin's `abcd` uses wrapping Q4.12 addition, but the RTL uses
// 17-bit sign-extended addition with signed saturation before UNORM clamping.
// For overflow cases these diverge.  The generator implements the RTL's
// exact arithmetic so expected values match the RTL.

/// Per-channel `(A - B) * C + D` matching the RTL's exact arithmetic:
/// 1. 17-bit sign-extended subtraction
/// 2. 17×16 → 33-bit signed multiply, extract bits [27:12]
/// 3. 17-bit sign-extended addition with signed saturation to 16-bit
/// 4. UNORM clamp to [0x0000, 0x1000]
fn abcd_rtl(a: i16, b: i16, c: i16, d: i16) -> i16 {
    // Step 1: 17-bit sign-extended subtraction
    let diff: i32 = i32::from(a) - i32::from(b);

    // Step 2: 17×16 multiply, extract [27:12]
    let prod: i64 = i64::from(diff) * i64::from(c);
    let shifted: i32 = ((prod >> 12) & 0xFFFF) as i16 as i32; // sign-extend from bit 15

    // Step 3: 17-bit addition with signed saturation
    let sum: i32 = shifted + i32::from(d);
    #[allow(clippy::cast_possible_truncation)]
    let sat: i16 = if sum > 0x7FFF {
        0x7FFF
    } else if sum < -0x8000 {
        -0x8000_i16
    } else {
        sum as i16
    };

    // Step 4: UNORM clamp [0x0000, 0x1000]
    sat.clamp(0, 0x1000)
}

/// Resolve a CC source selector to a per-channel i16 value.
fn resolve_source_ch(sel: u8, ch: usize, inputs: &SourceInputs) -> i16 {
    let color = match sel {
        0 => inputs.combined,
        1 => inputs.tex0,
        2 => inputs.tex1,
        3 => inputs.shade0,
        4 => inputs.const0,
        5 => inputs.const1,
        6 => [0x1000_i16, 0x1000, 0x1000, 0x1000], // ONE
        7 => [0_i16, 0, 0, 0],                     // ZERO
        8 => inputs.shade1,
        _ => [0_i16, 0, 0, 0], // reserved → zero
    };
    color[ch]
}

/// Resolve an extended RGB C source selector.  Alpha-broadcast sources
/// replicate the alpha channel (index 3) to all RGB channels.
fn resolve_rgb_c_ch(sel: u8, ch: usize, inputs: &SourceInputs) -> i16 {
    match sel {
        0..=7 => resolve_source_ch(sel, ch, inputs),
        8 => inputs.tex0[3],      // TEX0_ALPHA
        9 => inputs.tex1[3],      // TEX1_ALPHA
        10 => inputs.shade0[3],   // SHADE0_ALPHA
        11 => inputs.const0[3],   // CONST0_ALPHA
        12 => inputs.combined[3], // COMBINED_ALPHA
        13 => inputs.shade1[ch],  // SHADE1 (normal)
        14 => inputs.shade1[3],   // SHADE1_ALPHA
        _ => 0,
    }
}

/// Per-channel i16 arrays: [R, G, B, A].
struct SourceInputs {
    combined: [i16; 4],
    tex0: [i16; 4],
    tex1: [i16; 4],
    shade0: [i16; 4],
    shade1: [i16; 4],
    const0: [i16; 4],
    const1: [i16; 4],
}

fn color_to_channels(c: &ColorQ412) -> [i16; 4] {
    [
        c.r.to_bits() as i16,
        c.g.to_bits() as i16,
        c.b.to_bits() as i16,
        c.a.to_bits() as i16,
    ]
}

fn channels_to_color(ch: [i16; 4]) -> ColorQ412 {
    ColorQ412 {
        r: Q::from_bits(i64::from(ch[0])),
        g: Q::from_bits(i64::from(ch[1])),
        b: Q::from_bits(i64::from(ch[2])),
        a: Q::from_bits(i64::from(ch[3])),
    }
}

/// Extract field selectors from a 32-bit cycle half of cc_mode.
struct CycleSelectors {
    rgb_a: u8,
    rgb_b: u8,
    rgb_c: u8, // cc_rgb_c_source_e
    rgb_d: u8,
    alpha_a: u8,
    alpha_b: u8,
    alpha_c: u8, // cc_source_e for alpha C
    alpha_d: u8,
}

fn extract_cycle(half: u32) -> CycleSelectors {
    CycleSelectors {
        rgb_a: (half & 0xF) as u8,
        rgb_b: ((half >> 4) & 0xF) as u8,
        rgb_c: ((half >> 8) & 0xF) as u8,
        rgb_d: ((half >> 12) & 0xF) as u8,
        alpha_a: ((half >> 16) & 0xF) as u8,
        alpha_b: ((half >> 20) & 0xF) as u8,
        alpha_c: ((half >> 24) & 0xF) as u8,
        alpha_d: ((half >> 28) & 0xF) as u8,
    }
}

/// Evaluate one combiner cycle using RTL-matching arithmetic.
fn eval_cycle(sel: &CycleSelectors, inputs: &SourceInputs) -> [i16; 4] {
    let mut out = [0_i16; 4];
    // RGB channels (0=R, 1=G, 2=B)
    for (ch, out_ch) in out.iter_mut().enumerate().take(3) {
        let a = resolve_source_ch(sel.rgb_a, ch, inputs);
        let b = resolve_source_ch(sel.rgb_b, ch, inputs);
        let c = resolve_rgb_c_ch(sel.rgb_c, ch, inputs);
        let d = resolve_source_ch(sel.rgb_d, ch, inputs);
        *out_ch = abcd_rtl(a, b, c, d);
    }
    // Alpha channel (index 3)
    let a = resolve_source_ch(sel.alpha_a, 3, inputs);
    let b = resolve_source_ch(sel.alpha_b, 3, inputs);
    let c = resolve_source_ch(sel.alpha_c, 3, inputs);
    let d = resolve_source_ch(sel.alpha_d, 3, inputs);
    out[3] = abcd_rtl(a, b, c, d);
    out
}

/// Run both color combiner cycles using RTL-matching arithmetic.
fn evaluate_twin(
    cc_mode: CcModeReg,
    tex0: ColorQ412,
    tex1: ColorQ412,
    shade0: ColorQ412,
    shade1: ColorQ412,
    const0: ColorQ412,
    const1: ColorQ412,
) -> ColorQ412 {
    let cc_raw = cc_mode_to_u64(cc_mode);

    let inputs0 = SourceInputs {
        combined: [0; 4], // Cycle 0 COMBINED = ZERO
        tex0: color_to_channels(&tex0),
        tex1: color_to_channels(&tex1),
        shade0: color_to_channels(&shade0),
        shade1: color_to_channels(&shade1),
        const0: color_to_channels(&const0),
        const1: color_to_channels(&const1),
    };

    let c0_sel = extract_cycle(cc_raw as u32);
    let cycle0_out = eval_cycle(&c0_sel, &inputs0);

    // Cycle 1: COMBINED = cycle 0 output (already UNORM-clamped by abcd_rtl)
    let inputs1 = SourceInputs {
        combined: cycle0_out,
        tex0: inputs0.tex0,
        tex1: inputs0.tex1,
        shade0: inputs0.shade0,
        shade1: inputs0.shade1,
        const0: inputs0.const0,
        const1: inputs0.const1,
    };

    let c1_sel = extract_cycle((cc_raw >> 32) as u32);
    let cycle1_out = eval_cycle(&c1_sel, &inputs1);

    channels_to_color(cycle1_out)
}

// ── PRNG ────────────────────────────────────────────────────────────────────

/// Simple deterministic xorshift32 PRNG.
struct Xorshift32(u32);

impl Xorshift32 {
    /// Advance state and return next pseudo-random value.
    fn next(&mut self) -> u32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        self.0
    }

    /// Return a random Q4.12 value in UNORM range [0, 0x1000].
    fn next_unorm_q412(&mut self) -> Q<4, 12> {
        let raw = (self.next() & 0x0FFF) as i16;
        Q::from_bits(i64::from(raw))
    }

    /// Return a random `ColorQ412` with channels in UNORM range.
    fn rand_color_unorm(&mut self) -> ColorQ412 {
        ColorQ412 {
            r: self.next_unorm_q412(),
            g: self.next_unorm_q412(),
            b: self.next_unorm_q412(),
            a: self.next_unorm_q412(),
        }
    }

    /// Return a random byte.
    fn next_u8(&mut self) -> u8 {
        self.next() as u8
    }

    /// Return a random u16.
    fn next_u16(&mut self) -> u16 {
        self.next() as u16
    }

    /// Return a random valid `CcSourceE` value (0..=8).
    fn rand_cc_source(&mut self) -> u8 {
        let val = self.next() % 9;
        val as u8
    }

    /// Return a random valid `CcRgbCSourceE` value (0..=14).
    fn rand_cc_rgb_c_source(&mut self) -> u8 {
        let val = self.next() % 15;
        val as u8
    }
}

// ── Color helpers ───────────────────────────────────────────────────────────

/// Create a `ColorQ412` from raw Q4.12 bit values.
fn color_from_bits(r: i16, g: i16, b: i16, a: i16) -> ColorQ412 {
    ColorQ412 {
        r: Q::from_bits(i64::from(r)),
        g: Q::from_bits(i64::from(g)),
        b: Q::from_bits(i64::from(b)),
        a: Q::from_bits(i64::from(a)),
    }
}

// ── Vector generation ───────────────────────────────────────────────────────

/// Generate all test vectors across all scenarios.
fn gen_all_vectors() -> Vec<TestVector> {
    let mut vectors: Vec<TestVector> = Vec::new();

    gen_modulate(&mut vectors);
    gen_decal(&mut vectors);
    gen_lightmap(&mut vectors);
    gen_two_stage_specular(&mut vectors);
    gen_fog(&mut vectors);
    gen_const_promotion(&mut vectors);
    gen_alpha_broadcast_rgb_c(&mut vectors);
    gen_saturation_overflow(&mut vectors);
    gen_saturation_underflow(&mut vectors);
    gen_per_component_independence(&mut vectors);
    gen_source_mux_sweep(&mut vectors);
    gen_random(&mut vectors);

    vectors
}

/// Helper to build a test vector, running the twin to compute expected output.
#[allow(clippy::too_many_arguments)]
fn make_vector(
    cc_mode: CcModeReg,
    const_color_raw: u64,
    const0: ColorQ412,
    const1: ColorQ412,
    tex0: ColorQ412,
    tex1: ColorQ412,
    shade0: ColorQ412,
    shade1: ColorQ412,
    frag_x: u16,
    frag_y: u16,
    frag_z: u16,
) -> TestVector {
    let expected = evaluate_twin(cc_mode, tex0, tex1, shade0, shade1, const0, const1);

    TestVector {
        cc_mode,
        const_color_raw,
        tex0,
        tex1,
        shade0,
        shade1,
        frag_x,
        frag_y,
        frag_z,
        expected,
    }
}

/// Helper for vectors that use no CONST colors.
fn make_vector_no_const(
    cc_mode: CcModeReg,
    tex0: ColorQ412,
    tex1: ColorQ412,
    shade0: ColorQ412,
    shade1: ColorQ412,
) -> TestVector {
    make_vector(
        cc_mode,
        0,
        ColorQ412::default(),
        ColorQ412::default(),
        tex0,
        tex1,
        shade0,
        shade1,
        10,
        20,
        0x8000,
    )
}

// ── Scenario 1: Modulate ────────────────────────────────────────────────────

/// Modulate: TEX0 * SHADE0.
/// Cycle 0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO (RGB and Alpha).
/// Cycle 1: passthrough.
fn gen_modulate(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    // Cycle 0: (TEX0 - ZERO) * SHADE0 + ZERO = TEX0 * SHADE0
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCShade0);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcShade0);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    // Several color pairs
    let pairs: &[(ColorQ412, ColorQ412)] = &[
        // White * White = White
        (ColorQ412::OPAQUE_WHITE, ColorQ412::OPAQUE_WHITE),
        // White * Black = Black
        (ColorQ412::OPAQUE_WHITE, ColorQ412::default()),
        // Half * Half ≈ Quarter
        (
            color_from_bits(0x0800, 0x0800, 0x0800, 0x0800),
            color_from_bits(0x0800, 0x0800, 0x0800, 0x0800),
        ),
        // Full red * Full green shade
        (
            color_from_bits(0x1000, 0, 0, 0x1000),
            color_from_bits(0, 0x1000, 0, 0x1000),
        ),
        // Three-quarter intensity
        (
            color_from_bits(0x0C00, 0x0C00, 0x0C00, 0x1000),
            color_from_bits(0x0800, 0x0400, 0x0C00, 0x1000),
        ),
    ];

    for (tex0, shade0) in pairs {
        vectors.push(make_vector_no_const(
            mode,
            *tex0,
            ColorQ412::default(),
            *shade0,
            ColorQ412::default(),
        ));
    }
}

// ── Scenario 2: Decal ───────────────────────────────────────────────────────

/// Decal: TEX0 passthrough.
/// Cycle 0: A=TEX0, B=ZERO, C=ONE, D=ZERO.
/// Cycle 1: passthrough.
fn gen_decal(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcOne);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    let colors = &[
        ColorQ412::OPAQUE_WHITE,
        ColorQ412::default(),
        color_from_bits(0x0800, 0x0400, 0x0C00, 0x1000),
        color_from_bits(0x0123, 0x0456, 0x0789, 0x0ABC),
    ];

    for tex0 in colors {
        vectors.push(make_vector_no_const(
            mode,
            *tex0,
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
        ));
    }
}

// ── Scenario 3: Lightmap ────────────────────────────────────────────────────

/// Lightmap: TEX0 * TEX1.
/// Cycle 0: A=TEX0, B=ZERO, C=TEX1 (RGB_C=2), D=ZERO.
/// Cycle 1: passthrough.
fn gen_lightmap(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCTex1);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcTex1);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    let pairs: &[(ColorQ412, ColorQ412)] = &[
        (ColorQ412::OPAQUE_WHITE, ColorQ412::OPAQUE_WHITE),
        (
            color_from_bits(0x1000, 0x0800, 0x0400, 0x1000),
            color_from_bits(0x0800, 0x1000, 0x0800, 0x1000),
        ),
        (
            color_from_bits(0x0C00, 0x0C00, 0x0C00, 0x0C00),
            color_from_bits(0x0800, 0x0800, 0x0800, 0x0800),
        ),
    ];

    for (tex0, tex1) in pairs {
        vectors.push(make_vector_no_const(
            mode,
            *tex0,
            *tex1,
            ColorQ412::default(),
            ColorQ412::default(),
        ));
    }
}

// ── Scenario 4: Two-stage specular ──────────────────────────────────────────

/// Two-stage specular: Cycle 0 = TEX0*SHADE0, Cycle 1 = COMBINED + SHADE1.
/// Cycle 0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO.
/// Cycle 1: A=COMBINED, B=ZERO, C=ONE, D=SHADE1.
fn gen_two_stage_specular(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    // Cycle 0: TEX0 * SHADE0
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCShade0);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcShade0);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    // Cycle 1: COMBINED * ONE + SHADE1 = COMBINED + SHADE1
    mode.set_c1_rgb_a(CcSourceE::CcCombined);
    mode.set_c1_rgb_b(CcSourceE::CcZero);
    mode.set_c1_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c1_rgb_d(CcSourceE::CcShade1);
    mode.set_c1_alpha_a(CcSourceE::CcCombined);
    mode.set_c1_alpha_b(CcSourceE::CcZero);
    mode.set_c1_alpha_c(CcSourceE::CcOne);
    mode.set_c1_alpha_d(CcSourceE::CcShade1);

    let cases: &[(ColorQ412, ColorQ412, ColorQ412)] = &[
        // Diffuse texture with moderate specular highlight
        (
            color_from_bits(0x0800, 0x0800, 0x0800, 0x1000),
            color_from_bits(0x1000, 0x1000, 0x1000, 0x1000),
            color_from_bits(0x0200, 0x0200, 0x0200, 0),
        ),
        // Dark surface + bright specular
        (
            color_from_bits(0x0400, 0x0400, 0x0400, 0x1000),
            color_from_bits(0x0800, 0x0800, 0x0800, 0x1000),
            color_from_bits(0x0600, 0x0600, 0x0600, 0),
        ),
    ];

    for (tex0, shade0, shade1) in cases {
        vectors.push(make_vector_no_const(
            mode,
            *tex0,
            ColorQ412::default(),
            *shade0,
            *shade1,
        ));
    }
}

// ── Scenario 5: Fog ─────────────────────────────────────────────────────────

/// Fog: lerp from scene color toward fog color using shade0 alpha.
/// Cycle 0: TEX0*SHADE0.
/// Cycle 1: (COMBINED - CONST1) * SHADE0_ALPHA + CONST1.
fn gen_fog(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    // Cycle 0: TEX0 * SHADE0
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCShade0);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcShade0);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    // Cycle 1: (COMBINED - CONST1) * SHADE0_ALPHA + CONST1
    mode.set_c1_rgb_a(CcSourceE::CcCombined);
    mode.set_c1_rgb_b(CcSourceE::CcConst1);
    mode.set_c1_rgb_c(CcRgbCSourceE::CcCShade0Alpha);
    mode.set_c1_rgb_d(CcSourceE::CcConst1);
    // Alpha: passthrough COMBINED alpha
    mode.set_c1_alpha_a(CcSourceE::CcCombined);
    mode.set_c1_alpha_b(CcSourceE::CcZero);
    mode.set_c1_alpha_c(CcSourceE::CcOne);
    mode.set_c1_alpha_d(CcSourceE::CcZero);

    // Fog color = grey (CONST1), scene color = bright, varying fog factor (shade0.a)
    let fog_rgba: u32 = 0x80808080;
    let const1 = ColorQ412::from_unorm8(0x80, 0x80, 0x80, 0x80);
    let const_color_raw = pack_const_color(0, fog_rgba);

    let cases: &[(ColorQ412, ColorQ412, &str)] = &[
        // No fog (shade0.a = 1.0): output = scene color
        (
            ColorQ412::OPAQUE_WHITE,
            color_from_bits(0x1000, 0x1000, 0x1000, 0x1000),
            "no fog",
        ),
        // Full fog (shade0.a = 0.0): output = fog color
        (
            color_from_bits(0x0C00, 0x0400, 0x0800, 0x1000),
            color_from_bits(0x0C00, 0x0400, 0x0800, 0),
            "full fog",
        ),
        // Half fog (shade0.a = 0.5): output = lerp(scene, fog, 0.5)
        (
            color_from_bits(0x1000, 0x0000, 0x0000, 0x1000),
            color_from_bits(0x1000, 0x0000, 0x0000, 0x0800),
            "half fog",
        ),
    ];

    for (tex0, shade0, _label) in cases {
        vectors.push(make_vector(
            mode,
            const_color_raw,
            ColorQ412::default(),
            const1,
            *tex0,
            ColorQ412::default(),
            *shade0,
            ColorQ412::default(),
            15,
            25,
            0x4000,
        ));
    }
}

// ── Scenario 6: CONST color promotion ───────────────────────────────────────

/// Test CONST color promotion from RGBA8888 to Q4.12.
/// Uses decal mode with A=CONST0 to verify promotion values.
fn gen_const_promotion(vectors: &mut Vec<TestVector>) {
    let mut mode = CcModeReg::default();
    // Cycle 0: A=CONST0, B=ZERO, C=ONE, D=ZERO → output = CONST0
    mode.set_c0_rgb_a(CcSourceE::CcConst0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcConst0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcOne);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    let rgba_values: &[(u8, u8, u8, u8)] = &[
        (0x00, 0x00, 0x00, 0x00),
        (0xFF, 0xFF, 0xFF, 0xFF),
        (0x80, 0x80, 0x80, 0x80),
        (0x01, 0x01, 0x01, 0x01),
        (0xFF, 0x00, 0x80, 0x40),
        (0x10, 0x20, 0x40, 0x80),
        (0xAB, 0xCD, 0xEF, 0x12),
    ];

    for &(r, g, b, a) in rgba_values {
        let const0_raw = pack_rgba_to_rtl(r, g, b, a);
        let const_color_raw = pack_const_color(const0_raw, 0);
        let const0 = ColorQ412::from_unorm8(r, g, b, a);

        vectors.push(make_vector(
            mode,
            const_color_raw,
            const0,
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
            5,
            5,
            0x1000,
        ));
    }

    // Also test CONST1 path
    let mut mode1 = CcModeReg::default();
    mode1.set_c0_rgb_a(CcSourceE::CcConst1);
    mode1.set_c0_rgb_b(CcSourceE::CcZero);
    mode1.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode1.set_c0_rgb_d(CcSourceE::CcZero);
    mode1.set_c0_alpha_a(CcSourceE::CcConst1);
    mode1.set_c0_alpha_b(CcSourceE::CcZero);
    mode1.set_c0_alpha_c(CcSourceE::CcOne);
    mode1.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode1);

    let const1_raw = pack_rgba_to_rtl(0xAA, 0xBB, 0xCC, 0xDD);
    let const_color_raw = pack_const_color(0, const1_raw);
    let const1 = ColorQ412::from_unorm8(0xAA, 0xBB, 0xCC, 0xDD);

    vectors.push(make_vector(
        mode1,
        const_color_raw,
        ColorQ412::default(),
        const1,
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
        6,
        6,
        0x2000,
    ));
}

// ── Scenario 7: Alpha-broadcast RGB C ───────────────────────────────────────

/// Test CC_C_TEX0_ALPHA (8), CC_C_SHADE0_ALPHA (10), CC_C_COMBINED_ALPHA (12).
fn gen_alpha_broadcast_rgb_c(vectors: &mut Vec<TestVector>) {
    // TEX0_ALPHA: cycle 0 C_RGB = TEX0.alpha broadcast.
    // (TEX0 - ZERO) * TEX0_ALPHA + ZERO = TEX0.rgb * TEX0.a
    {
        let mut mode = CcModeReg::default();
        mode.set_c0_rgb_a(CcSourceE::CcTex0);
        mode.set_c0_rgb_b(CcSourceE::CcZero);
        mode.set_c0_rgb_c(CcRgbCSourceE::CcCTex0Alpha);
        mode.set_c0_rgb_d(CcSourceE::CcZero);
        mode.set_c0_alpha_a(CcSourceE::CcTex0);
        mode.set_c0_alpha_b(CcSourceE::CcZero);
        mode.set_c0_alpha_c(CcSourceE::CcOne);
        mode.set_c0_alpha_d(CcSourceE::CcZero);
        set_passthrough_c1(&mut mode);

        let tex0 = color_from_bits(0x1000, 0x0800, 0x0400, 0x0800); // alpha = 0.5
        vectors.push(make_vector_no_const(
            mode,
            tex0,
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
        ));
    }

    // SHADE0_ALPHA: cycle 0 C_RGB = SHADE0.alpha broadcast.
    {
        let mut mode = CcModeReg::default();
        mode.set_c0_rgb_a(CcSourceE::CcTex0);
        mode.set_c0_rgb_b(CcSourceE::CcZero);
        mode.set_c0_rgb_c(CcRgbCSourceE::CcCShade0Alpha);
        mode.set_c0_rgb_d(CcSourceE::CcZero);
        mode.set_c0_alpha_a(CcSourceE::CcTex0);
        mode.set_c0_alpha_b(CcSourceE::CcZero);
        mode.set_c0_alpha_c(CcSourceE::CcOne);
        mode.set_c0_alpha_d(CcSourceE::CcZero);
        set_passthrough_c1(&mut mode);

        let tex0 = color_from_bits(0x1000, 0x0800, 0x0400, 0x1000);
        let shade0 = color_from_bits(0x0400, 0x0400, 0x0400, 0x0C00); // alpha = 0.75
        vectors.push(make_vector_no_const(
            mode,
            tex0,
            ColorQ412::default(),
            shade0,
            ColorQ412::default(),
        ));
    }

    // COMBINED_ALPHA: cycle 1 C_RGB = COMBINED.alpha broadcast.
    // Cycle 0: TEX0 passthrough.
    // Cycle 1: (SHADE0 - ZERO) * COMBINED_ALPHA + ZERO = SHADE0.rgb * stage0.alpha
    {
        let mut mode = CcModeReg::default();
        // Cycle 0: passthrough TEX0
        mode.set_c0_rgb_a(CcSourceE::CcTex0);
        mode.set_c0_rgb_b(CcSourceE::CcZero);
        mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
        mode.set_c0_rgb_d(CcSourceE::CcZero);
        mode.set_c0_alpha_a(CcSourceE::CcTex0);
        mode.set_c0_alpha_b(CcSourceE::CcZero);
        mode.set_c0_alpha_c(CcSourceE::CcOne);
        mode.set_c0_alpha_d(CcSourceE::CcZero);
        // Cycle 1: SHADE0 * COMBINED_ALPHA
        mode.set_c1_rgb_a(CcSourceE::CcShade0);
        mode.set_c1_rgb_b(CcSourceE::CcZero);
        mode.set_c1_rgb_c(CcRgbCSourceE::CcCCombinedAlpha);
        mode.set_c1_rgb_d(CcSourceE::CcZero);
        mode.set_c1_alpha_a(CcSourceE::CcCombined);
        mode.set_c1_alpha_b(CcSourceE::CcZero);
        mode.set_c1_alpha_c(CcSourceE::CcOne);
        mode.set_c1_alpha_d(CcSourceE::CcZero);

        let tex0 = color_from_bits(0x0800, 0x0800, 0x0800, 0x0800); // alpha = 0.5
        let shade0 = color_from_bits(0x1000, 0x0C00, 0x0400, 0x1000);
        vectors.push(make_vector_no_const(
            mode,
            tex0,
            ColorQ412::default(),
            shade0,
            ColorQ412::default(),
        ));
    }
}

// ── Scenario 8: Saturation overflow ─────────────────────────────────────────

/// Values that cause final output > 1.0, should clamp to 1.0.
fn gen_saturation_overflow(vectors: &mut Vec<TestVector>) {
    // (ONE - ZERO) * ONE + ONE = 1.0 + 1.0 = 2.0 → clamps to 1.0
    // Use single-cycle: cycle 0 does the computation, cycle 1 passthrough.
    let mut mode = CcModeReg::default();
    mode.set_c0_rgb_a(CcSourceE::CcOne);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c0_rgb_d(CcSourceE::CcOne);
    mode.set_c0_alpha_a(CcSourceE::CcOne);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcOne);
    mode.set_c0_alpha_d(CcSourceE::CcOne);
    set_passthrough_c1(&mut mode);

    vectors.push(make_vector_no_const(
        mode,
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
    ));

    // TEX0 + SHADE0 where both are bright → overflow
    let mut mode2 = CcModeReg::default();
    mode2.set_c0_rgb_a(CcSourceE::CcTex0);
    mode2.set_c0_rgb_b(CcSourceE::CcZero);
    mode2.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode2.set_c0_rgb_d(CcSourceE::CcShade0);
    mode2.set_c0_alpha_a(CcSourceE::CcTex0);
    mode2.set_c0_alpha_b(CcSourceE::CcZero);
    mode2.set_c0_alpha_c(CcSourceE::CcOne);
    mode2.set_c0_alpha_d(CcSourceE::CcShade0);
    set_passthrough_c1(&mut mode2);

    let tex0 = color_from_bits(0x0C00, 0x0C00, 0x0C00, 0x0C00);
    let shade0 = color_from_bits(0x0C00, 0x0C00, 0x0C00, 0x0C00);
    vectors.push(make_vector_no_const(
        mode2,
        tex0,
        ColorQ412::default(),
        shade0,
        ColorQ412::default(),
    ));
}

// ── Scenario 9: Saturation underflow ────────────────────────────────────────

/// Values that cause final output < 0.0, should clamp to 0.0.
fn gen_saturation_underflow(vectors: &mut Vec<TestVector>) {
    // (ZERO - ONE) * ONE + ZERO = -1.0 → clamps to 0.0
    let mut mode = CcModeReg::default();
    mode.set_c0_rgb_a(CcSourceE::CcZero);
    mode.set_c0_rgb_b(CcSourceE::CcOne);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcZero);
    mode.set_c0_alpha_b(CcSourceE::CcOne);
    mode.set_c0_alpha_c(CcSourceE::CcOne);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    vectors.push(make_vector_no_const(
        mode,
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
        ColorQ412::default(),
    ));

    // (SHADE0 - TEX0) * ONE + ZERO where SHADE0 < TEX0
    let mut mode2 = CcModeReg::default();
    mode2.set_c0_rgb_a(CcSourceE::CcShade0);
    mode2.set_c0_rgb_b(CcSourceE::CcTex0);
    mode2.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
    mode2.set_c0_rgb_d(CcSourceE::CcZero);
    mode2.set_c0_alpha_a(CcSourceE::CcShade0);
    mode2.set_c0_alpha_b(CcSourceE::CcTex0);
    mode2.set_c0_alpha_c(CcSourceE::CcOne);
    mode2.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode2);

    let tex0 = color_from_bits(0x0C00, 0x0C00, 0x0C00, 0x0C00);
    let shade0 = color_from_bits(0x0200, 0x0200, 0x0200, 0x0200);
    vectors.push(make_vector_no_const(
        mode2,
        tex0,
        ColorQ412::default(),
        shade0,
        ColorQ412::default(),
    ));
}

// ── Scenario 10: Per-component independence ─────────────────────────────────

/// Each RGBA channel has distinct values to verify no cross-channel mixing.
fn gen_per_component_independence(vectors: &mut Vec<TestVector>) {
    // Modulate mode: TEX0 * SHADE0, with distinct channels.
    let mut mode = CcModeReg::default();
    mode.set_c0_rgb_a(CcSourceE::CcTex0);
    mode.set_c0_rgb_b(CcSourceE::CcZero);
    mode.set_c0_rgb_c(CcRgbCSourceE::CcCShade0);
    mode.set_c0_rgb_d(CcSourceE::CcZero);
    mode.set_c0_alpha_a(CcSourceE::CcTex0);
    mode.set_c0_alpha_b(CcSourceE::CcZero);
    mode.set_c0_alpha_c(CcSourceE::CcShade0);
    mode.set_c0_alpha_d(CcSourceE::CcZero);
    set_passthrough_c1(&mut mode);

    let cases = &[
        (
            color_from_bits(0x1000, 0x0800, 0x0400, 0x0200),
            color_from_bits(0x0200, 0x0400, 0x0800, 0x1000),
        ),
        (
            color_from_bits(0x0100, 0x0300, 0x0500, 0x0700),
            color_from_bits(0x0900, 0x0B00, 0x0D00, 0x0F00),
        ),
        (
            color_from_bits(0x0ABC, 0x0DEF, 0x0123, 0x0456),
            color_from_bits(0x0789, 0x0ABC, 0x0DEF, 0x0123),
        ),
    ];

    for (tex0, shade0) in cases {
        vectors.push(make_vector_no_const(
            mode,
            *tex0,
            ColorQ412::default(),
            *shade0,
            ColorQ412::default(),
        ));
    }
}

// ── Scenario 11: All source mux sweep ───────────────────────────────────────

/// Sweep each cc_source_e value (0..8) as the A source for RGB.
/// Known input values assigned to each source.
fn gen_source_mux_sweep(vectors: &mut Vec<TestVector>) {
    // Set up known values for each input.
    let tex0 = color_from_bits(0x0100, 0x0100, 0x0100, 0x0100);
    let tex1 = color_from_bits(0x0200, 0x0200, 0x0200, 0x0200);
    let shade0 = color_from_bits(0x0300, 0x0300, 0x0300, 0x0300);
    let shade1 = color_from_bits(0x0500, 0x0500, 0x0500, 0x0500);
    let const0_rgba: u32 = 0x40404040; // promotes to ~0x0404
    let const1_rgba: u32 = 0x60606060; // promotes to ~0x0606
    let const0 = ColorQ412::from_unorm8(0x40, 0x40, 0x40, 0x40);
    let const1 = ColorQ412::from_unorm8(0x60, 0x60, 0x60, 0x60);
    let const_color_raw = pack_const_color(const0_rgba, const1_rgba);

    // cc_source_e values: 0=COMBINED, 1=TEX0, 2=TEX1, 3=SHADE0,
    // 4=CONST0, 5=CONST1, 6=ONE, 7=ZERO, 8=SHADE1
    let sources = [
        CcSourceE::CcCombined,
        CcSourceE::CcTex0,
        CcSourceE::CcTex1,
        CcSourceE::CcShade0,
        CcSourceE::CcConst0,
        CcSourceE::CcConst1,
        CcSourceE::CcOne,
        CcSourceE::CcZero,
        CcSourceE::CcShade1,
    ];

    for &src in &sources {
        // Cycle 0: A=<source>, B=ZERO, C=ONE, D=ZERO → output = A
        let mut mode = CcModeReg::default();
        mode.set_c0_rgb_a(src);
        mode.set_c0_rgb_b(CcSourceE::CcZero);
        mode.set_c0_rgb_c(CcRgbCSourceE::CcCOne);
        mode.set_c0_rgb_d(CcSourceE::CcZero);
        mode.set_c0_alpha_a(src);
        mode.set_c0_alpha_b(CcSourceE::CcZero);
        mode.set_c0_alpha_c(CcSourceE::CcOne);
        mode.set_c0_alpha_d(CcSourceE::CcZero);
        set_passthrough_c1(&mut mode);

        vectors.push(make_vector(
            mode,
            const_color_raw,
            const0,
            const1,
            tex0,
            tex1,
            shade0,
            shade1,
            42,
            84,
            0x5555,
        ));
    }
}

// ── Scenario 12: Random vectors ─────────────────────────────────────────────

/// Generate ~200 random vectors with seeded PRNG.
fn gen_random(vectors: &mut Vec<TestVector>) {
    let mut rng = Xorshift32(0xCAFE_BABE);

    for _ in 0..200 {
        // Build a random cc_mode with valid selector values.
        let mut mode = CcModeReg::default();
        mode.set_c0_rgb_a(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_rgb_b(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_rgb_c(CcRgbCSourceE::from_bits(rng.rand_cc_rgb_c_source()).expect("valid"));
        mode.set_c0_rgb_d(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_alpha_a(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_alpha_b(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_alpha_c(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c0_alpha_d(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_rgb_a(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_rgb_b(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_rgb_c(CcRgbCSourceE::from_bits(rng.rand_cc_rgb_c_source()).expect("valid"));
        mode.set_c1_rgb_d(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_alpha_a(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_alpha_b(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_alpha_c(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));
        mode.set_c1_alpha_d(CcSourceE::from_bits(rng.rand_cc_source()).expect("valid"));

        // Random RGBA8888 CONST colors.
        let const0_r = rng.next_u8();
        let const0_g = rng.next_u8();
        let const0_b = rng.next_u8();
        let const0_a = rng.next_u8();
        let const1_r = rng.next_u8();
        let const1_g = rng.next_u8();
        let const1_b = rng.next_u8();
        let const1_a = rng.next_u8();

        let const0_raw = pack_rgba_to_rtl(const0_r, const0_g, const0_b, const0_a);
        let const1_raw = pack_rgba_to_rtl(const1_r, const1_g, const1_b, const1_a);
        let const_color_raw = pack_const_color(const0_raw, const1_raw);
        let const0 = ColorQ412::from_unorm8(const0_r, const0_g, const0_b, const0_a);
        let const1 = ColorQ412::from_unorm8(const1_r, const1_g, const1_b, const1_a);

        // Random Q4.12 UNORM colors for tex/shade inputs.
        let tex0 = rng.rand_color_unorm();
        let tex1 = rng.rand_color_unorm();
        let shade0 = rng.rand_color_unorm();
        let shade1 = rng.rand_color_unorm();

        let frag_x = rng.next_u16() & 0x03FF; // 10-bit X
        let frag_y = rng.next_u16() & 0x03FF; // 10-bit Y
        let frag_z = rng.next_u16();

        vectors.push(make_vector(
            mode,
            const_color_raw,
            const0,
            const1,
            tex0,
            tex1,
            shade0,
            shade1,
            frag_x,
            frag_y,
            frag_z,
        ));
    }
}

// ── Hex file output ─────────────────────────────────────────────────────────

/// Write stimulus and expected output hex files.
fn write_hex_files(out: &Path, vectors: &[TestVector]) {
    let num = vectors.len();
    let mut stim = String::new();
    let mut exp = String::new();

    // First line: vector count.
    writeln!(stim, "{num:016x}").expect("write stim count");
    writeln!(exp, "{num:016x}").expect("write exp count");

    for v in vectors {
        // Stimulus: 7 x 64-bit hex words per vector.
        // 1. cc_mode (64-bit)
        let cc_mode_raw = cc_mode_to_u64(v.cc_mode);
        writeln!(stim, "{cc_mode_raw:016x}").expect("write cc_mode");

        // 2. const_color (64-bit, raw RGBA8888)
        writeln!(stim, "{:016x}", v.const_color_raw).expect("write const_color");

        // 3. tex_color0 (64-bit, packed Q4.12 RGBA)
        writeln!(stim, "{:016x}", pack_q412_rgba(&v.tex0)).expect("write tex0");

        // 4. tex_color1 (64-bit, packed Q4.12 RGBA)
        writeln!(stim, "{:016x}", pack_q412_rgba(&v.tex1)).expect("write tex1");

        // 5. shade0 (64-bit, packed Q4.12 RGBA)
        writeln!(stim, "{:016x}", pack_q412_rgba(&v.shade0)).expect("write shade0");

        // 6. shade1 (64-bit, packed Q4.12 RGBA)
        writeln!(stim, "{:016x}", pack_q412_rgba(&v.shade1)).expect("write shade1");

        // 7. ctrl (64-bit: {16'b0, frag_x[47:32], frag_y[31:16], frag_z[15:0]})
        let ctrl = (u64::from(v.frag_x) << 32) | (u64::from(v.frag_y) << 16) | u64::from(v.frag_z);
        writeln!(stim, "{ctrl:016x}").expect("write ctrl");

        // Expected output: 1 x 64-bit hex word (packed Q4.12 RGBA).
        writeln!(exp, "{:016x}", pack_q412_rgba(&v.expected)).expect("write expected");
    }

    fs::write(out.join("cc_stim.hex"), stim).expect("write cc_stim.hex");
    fs::write(out.join("cc_exp.hex"), exp).expect("write cc_exp.hex");

    eprintln!("  color combiner: {num} vectors");
}
