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

use super::fragment::{ColorQ412, ColoredFragment, TexturedFragment};

/// Color combiner stage 0: `(A-B)*C+D` for RGB and alpha.
///
/// Populates `frag.comb` with the stage 0 output (COMBINED source
/// for stage 1).
///
/// # Arguments
///
/// * `frag` - Textured fragment (tex0, tex1, shade0, shade1 live).
/// * `cc_mode` - Raw CC_MODE register value selecting A, B, C, D operands.
/// * `const0` - CONST0 color from register file.
///
/// # Returns
///
/// The same `TexturedFragment` with `comb` populated.
pub fn color_combine_0(
    mut frag: TexturedFragment,
    _cc_mode: u64,
    _const0: ColorQ412,
) -> TexturedFragment {
    // TODO: implement (A-B)*C+D operand selection and evaluation
    // Stub: pass shade0 through as the combined output
    frag.comb = Some(frag.shade0);
    frag
}

/// Color combiner stage 1: `(A-B)*C+D` using COMBINED from stage 0.
///
/// Produces the final fragment color by consuming the COMBINED output
/// from stage 0 along with remaining shade/texture inputs.
///
/// # Arguments
///
/// * `frag` - Textured fragment with `comb` populated by stage 0.
/// * `cc_mode` - Raw CC_MODE register value for stage 1 operand selection.
/// * `const1` - CONST1 color from register file.
///
/// # Returns
///
/// A `ColoredFragment` with the final color.
pub fn color_combine_1(
    frag: TexturedFragment,
    _cc_mode: u64,
    _const1: ColorQ412,
) -> ColoredFragment {
    // TODO: implement stage 1 (A-B)*C+D evaluation
    // Stub: pass combined output through (identity combiner)
    let color = frag.comb.unwrap_or(frag.shade0);

    ColoredFragment {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        color,
    }
}
