//! Color combiner — two-stage `(A-B)*C+D` programmable blending.
//!
//! Each stage evaluates `(A-B)*C+D` independently for RGB and alpha,
//! selecting operands from: texture colors, vertex shade colors,
//! per-draw-call constants, and the COMBINED feedback path.
//!
//! Stage 0's output feeds stage 1 via the COMBINED source, enabling
//! multi-texture blending, fog, and specular-add in a single pass.
//!
//! # RTL Implementation Notes
//!
//! Two-stage pipeline, one pixel per clock.
//! See UNIT-010 (Color Combiner).

use gpu_registers::components::cc_rgb_c_source_e::CcRgbCSourceE;
use gpu_registers::components::cc_source_e::CcSourceE;
use gpu_registers::components::gpu_regs::named_types::cc_mode_reg::CcModeReg;
use qfixed::Q;

use gs_twin_core::fragment::{ColorQ412, ColoredFragment, TexturedFragment};

/// All color sources available to the combiner mux.
///
/// Both stages receive the same set of inputs; only the `combined`
/// value differs (opaque white for stage 0, stage 0's output for stage 1).
pub struct CcInputs {
    /// Sampled texture unit 0 color.
    pub tex0: ColorQ412,

    /// Sampled texture unit 1 color.
    pub tex1: ColorQ412,

    /// Interpolated vertex color 0 (diffuse).
    pub shade0: ColorQ412,

    /// Interpolated vertex color 1 (specular).
    pub shade1: ColorQ412,

    /// Constant color 0 from register file.
    pub const0: ColorQ412,

    /// Constant color 1 from register file (also fog color).
    pub const1: ColorQ412,

    /// Previous combiner stage output (opaque white for stage 0).
    pub combined: ColorQ412,
}

// ── Source mux resolution ────────────────────────────────────────────────────

/// Resolve a standard combiner source to a `ColorQ412`.
///
/// Used for all A, B, D slots and all alpha-channel slots.
/// Reserved values 9–15 trigger a debug assertion and resolve to zero,
/// matching RTL behavior.
fn resolve_source(sel: CcSourceE, inputs: &CcInputs) -> ColorQ412 {
    match sel {
        CcSourceE::CcCombined => inputs.combined,
        CcSourceE::CcTex0 => inputs.tex0,
        CcSourceE::CcTex1 => inputs.tex1,
        CcSourceE::CcShade0 => inputs.shade0,
        CcSourceE::CcConst0 => inputs.const0,
        CcSourceE::CcConst1 => inputs.const1,
        CcSourceE::CcOne => ColorQ412::OPAQUE_WHITE,
        CcSourceE::CcZero => ColorQ412::default(),
        CcSourceE::CcShade1 => inputs.shade1,
        _ => {
            debug_assert!(false, "reserved CC source selector: {sel:?}");
            ColorQ412::default()
        }
    }
}

/// Resolve an extended RGB C source to a `ColorQ412`.
///
/// The RGB C slot supports alpha-broadcast variants where a single
/// alpha channel is replicated across R, G, B (with A passed through).
/// Only the RGB channels of the returned color are used by the caller.
fn resolve_rgb_c_source(sel: CcRgbCSourceE, inputs: &CcInputs) -> ColorQ412 {
    match sel {
        CcRgbCSourceE::CcCCombined => inputs.combined,
        CcRgbCSourceE::CcCTex0 => inputs.tex0,
        CcRgbCSourceE::CcCTex1 => inputs.tex1,
        CcRgbCSourceE::CcCShade0 => inputs.shade0,
        CcRgbCSourceE::CcCConst0 => inputs.const0,
        CcRgbCSourceE::CcCConst1 => inputs.const1,
        CcRgbCSourceE::CcCOne => ColorQ412::OPAQUE_WHITE,
        CcRgbCSourceE::CcCZero => ColorQ412::default(),
        // Alpha-broadcast: replicate source alpha into R, G, B.
        CcRgbCSourceE::CcCTex0Alpha => alpha_broadcast(inputs.tex0),
        CcRgbCSourceE::CcCTex1Alpha => alpha_broadcast(inputs.tex1),
        CcRgbCSourceE::CcCShade0Alpha => alpha_broadcast(inputs.shade0),
        CcRgbCSourceE::CcCConst0Alpha => alpha_broadcast(inputs.const0),
        CcRgbCSourceE::CcCCombinedAlpha => alpha_broadcast(inputs.combined),
        CcRgbCSourceE::CcCShade1 => inputs.shade1,
        CcRgbCSourceE::CcCShade1Alpha => alpha_broadcast(inputs.shade1),
        CcRgbCSourceE::CcCRsvd15 => {
            debug_assert!(false, "reserved CC RGB C source selector");
            ColorQ412::default()
        }
    }
}

/// Broadcast a color's alpha channel to R, G, B.
fn alpha_broadcast(c: ColorQ412) -> ColorQ412 {
    ColorQ412 {
        r: c.a,
        g: c.a,
        b: c.a,
        a: c.a,
    }
}

// ── Core combiner arithmetic ─────────────────────────────────────────────────

/// Per-channel `(A - B) * C + D` using Q4.12 fixed-point arithmetic.
///
/// All intermediate results are kept in Q4.12 with wrapping semantics,
/// matching RTL bit extraction.
#[inline]
fn abcd(a: Q<4, 12>, b: Q<4, 12>, c: Q<4, 12>, d: Q<4, 12>) -> Q<4, 12> {
    a.wrapping_sub(b).wrapping_mul(c).wrapping_add(d)
}

/// Per-stage mux selectors decoded from one half of `CcModeReg`.
struct CcSelectors {
    rgb_a: CcSourceE,
    rgb_b: CcSourceE,
    rgb_c: CcRgbCSourceE,
    rgb_d: CcSourceE,
    alpha_a: CcSourceE,
    alpha_b: CcSourceE,
    alpha_c: CcSourceE,
    alpha_d: CcSourceE,
}

/// Evaluate the `(A-B)*C+D` equation for one combiner stage.
///
/// Processes RGB and alpha channels independently, using the standard
/// source mux for all slots except RGB C (which uses the extended mux
/// with alpha-broadcast sources).
///
/// Returns the unsaturated result; saturation is applied by the caller
/// after the final stage.
fn evaluate_cc(sel: &CcSelectors, inputs: &CcInputs) -> ColorQ412 {
    // Resolve RGB operands.
    let a_rgb = resolve_source(sel.rgb_a, inputs);
    let b_rgb = resolve_source(sel.rgb_b, inputs);
    let c_rgb = resolve_rgb_c_source(sel.rgb_c, inputs);
    let d_rgb = resolve_source(sel.rgb_d, inputs);

    // Resolve alpha operands.
    let a_alpha = resolve_source(sel.alpha_a, inputs);
    let b_alpha = resolve_source(sel.alpha_b, inputs);
    let c_alpha = resolve_source(sel.alpha_c, inputs);
    let d_alpha = resolve_source(sel.alpha_d, inputs);

    ColorQ412 {
        r: abcd(a_rgb.r, b_rgb.r, c_rgb.r, d_rgb.r),
        g: abcd(a_rgb.g, b_rgb.g, c_rgb.g, d_rgb.g),
        b: abcd(a_rgb.b, b_rgb.b, c_rgb.b, d_rgb.b),
        a: abcd(a_alpha.a, b_alpha.a, c_alpha.a, d_alpha.a),
    }
}

// ── Saturation ───────────────────────────────────────────────────────────────

/// Clamp each channel to the UNORM range \[0x0000, 0x1000\] (Q4.12 \[0.0, 1.0\]).
fn saturate_unorm(color: ColorQ412) -> ColorQ412 {
    ColorQ412 {
        r: color.r.clamp(Q::ZERO, Q::ONE),
        g: color.g.clamp(Q::ZERO, Q::ONE),
        b: color.b.clamp(Q::ZERO, Q::ONE),
        a: color.a.clamp(Q::ZERO, Q::ONE),
    }
}

// ── Public stage wrappers ────────────────────────────────────────────────────

/// Color combiner stage 0: `(A-B)*C+D` for RGB and alpha.
///
/// Populates `frag.comb` with the stage 0 output (COMBINED source
/// for stage 1).  The COMBINED input defaults to opaque white for
/// this first stage.
///
/// # Arguments
///
/// * `frag` - Textured fragment (tex0, tex1, shade0, shade1 live).
/// * `cc_mode` - Typed CC_MODE register selecting A, B, C, D operands.
/// * `const0` - CONST0 color from register file (Q4.12).
/// * `const1` - CONST1 color from register file (Q4.12).
///
/// # Returns
///
/// The same `TexturedFragment` with `comb` populated.
pub fn color_combine_0(
    mut frag: TexturedFragment,
    cc_mode: CcModeReg,
    const0: ColorQ412,
    const1: ColorQ412,
) -> TexturedFragment {
    let inputs = CcInputs {
        tex0: frag.tex0,
        tex1: frag.tex1,
        shade0: frag.shade0,
        shade1: frag.shade1,
        const0,
        const1,
        combined: ColorQ412::OPAQUE_WHITE,
    };

    let sel = CcSelectors {
        rgb_a: cc_mode.c0_rgb_a(),
        rgb_b: cc_mode.c0_rgb_b(),
        rgb_c: cc_mode.c0_rgb_c(),
        rgb_d: cc_mode.c0_rgb_d(),
        alpha_a: cc_mode.c0_alpha_a(),
        alpha_b: cc_mode.c0_alpha_b(),
        alpha_c: cc_mode.c0_alpha_c(),
        alpha_d: cc_mode.c0_alpha_d(),
    };

    frag.comb = Some(evaluate_cc(&sel, &inputs));

    frag
}

/// Color combiner stage 1: `(A-B)*C+D` using COMBINED from stage 0.
///
/// Produces the final fragment color by consuming the COMBINED output
/// from stage 0 along with remaining shade/texture inputs.
/// Saturates the result to UNORM \[0.0, 1.0\] range.
///
/// # Arguments
///
/// * `frag` - Textured fragment with `comb` populated by stage 0.
/// * `cc_mode` - Typed CC_MODE register for stage 1 operand selection.
/// * `const0` - CONST0 color from register file (Q4.12).
/// * `const1` - CONST1 color from register file (Q4.12).
///
/// # Returns
///
/// A `ColoredFragment` with the final saturated color.
pub fn color_combine_1(
    frag: TexturedFragment,
    cc_mode: CcModeReg,
    const0: ColorQ412,
    const1: ColorQ412,
) -> ColoredFragment {
    let inputs = CcInputs {
        tex0: frag.tex0,
        tex1: frag.tex1,
        shade0: frag.shade0,
        shade1: frag.shade1,
        const0,
        const1,
        combined: frag.comb.unwrap_or(ColorQ412::OPAQUE_WHITE),
    };

    let sel = CcSelectors {
        rgb_a: cc_mode.c1_rgb_a(),
        rgb_b: cc_mode.c1_rgb_b(),
        rgb_c: cc_mode.c1_rgb_c(),
        rgb_d: cc_mode.c1_rgb_d(),
        alpha_a: cc_mode.c1_alpha_a(),
        alpha_b: cc_mode.c1_alpha_b(),
        alpha_c: cc_mode.c1_alpha_c(),
        alpha_d: cc_mode.c1_alpha_d(),
    };

    let color = evaluate_cc(&sel, &inputs);

    ColoredFragment {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        color: saturate_unorm(color),
    }
}
