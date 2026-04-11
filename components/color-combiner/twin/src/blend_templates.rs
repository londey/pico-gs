//! Blend-mode templates for CC pass 2.
//!
//! Each function returns a `CcMode2Reg` pre-configured to implement a
//! common alpha blend mode using the `(A-B)*C+D` equation.
//! Tests and drivers can use these helpers to program `CC_MODE_2`
//! without hand-encoding the selector bits.
//!
//! All templates configure the alpha channel as pass-through
//! (A=COMBINED, B=ZERO, C=ONE, D=ZERO) to preserve the fragment's
//! original alpha value.

use gpu_registers::components::cc_rgb_c_source_e::CcRgbCSourceE;
use gpu_registers::components::cc_source_e::CcSourceE;
use gpu_registers::components::gpu_regs::named_types::cc_mode_2_reg::CcMode2Reg;

/// Configure pass 2 as alpha pass-through (no blending).
///
/// RGB: `(COMBINED - ZERO) * ONE + ZERO` = COMBINED
/// Alpha: `(COMBINED - ZERO) * ONE + ZERO` = COMBINED
pub fn cc2_disabled() -> CcMode2Reg {
    let mut reg = CcMode2Reg::default();
    // RGB: A=COMBINED, B=ZERO, C=ONE, D=ZERO
    reg.set_c2_rgb_a(CcSourceE::CcCombined);
    reg.set_c2_rgb_b(CcSourceE::CcZero);
    reg.set_c2_rgb_c(CcRgbCSourceE::CcCOne);
    reg.set_c2_rgb_d(CcSourceE::CcZero);
    // Alpha: pass-through
    reg.set_c2_alpha_a(CcSourceE::CcCombined);
    reg.set_c2_alpha_b(CcSourceE::CcZero);
    reg.set_c2_alpha_c(CcSourceE::CcOne);
    reg.set_c2_alpha_d(CcSourceE::CcZero);
    reg
}

/// Configure pass 2 for additive blending.
///
/// RGB: `(COMBINED - ZERO) * COMBINED_ALPHA + DST_COLOR`
///     = `src * alpha + dst`
/// Alpha: pass-through
pub fn cc2_add() -> CcMode2Reg {
    let mut reg = CcMode2Reg::default();
    // RGB: A=COMBINED, B=ZERO, C=COMBINED_ALPHA (broadcast), D=DST_COLOR
    reg.set_c2_rgb_a(CcSourceE::CcCombined);
    reg.set_c2_rgb_b(CcSourceE::CcZero);
    reg.set_c2_rgb_c(CcRgbCSourceE::CcCCombinedAlpha);
    reg.set_c2_rgb_d(CcSourceE::CcDstColor);
    // Alpha: pass-through
    reg.set_c2_alpha_a(CcSourceE::CcCombined);
    reg.set_c2_alpha_b(CcSourceE::CcZero);
    reg.set_c2_alpha_c(CcSourceE::CcOne);
    reg.set_c2_alpha_d(CcSourceE::CcZero);
    reg
}

/// Configure pass 2 for subtractive blending.
///
/// RGB: `(ZERO - COMBINED) * COMBINED_ALPHA + DST_COLOR`
///     = `dst - src * alpha`
/// Alpha: pass-through
pub fn cc2_subtract() -> CcMode2Reg {
    let mut reg = CcMode2Reg::default();
    // RGB: A=ZERO, B=COMBINED, C=COMBINED_ALPHA (broadcast), D=DST_COLOR
    reg.set_c2_rgb_a(CcSourceE::CcZero);
    reg.set_c2_rgb_b(CcSourceE::CcCombined);
    reg.set_c2_rgb_c(CcRgbCSourceE::CcCCombinedAlpha);
    reg.set_c2_rgb_d(CcSourceE::CcDstColor);
    // Alpha: pass-through
    reg.set_c2_alpha_a(CcSourceE::CcCombined);
    reg.set_c2_alpha_b(CcSourceE::CcZero);
    reg.set_c2_alpha_c(CcSourceE::CcOne);
    reg.set_c2_alpha_d(CcSourceE::CcZero);
    reg
}

/// Configure pass 2 for Porter-Duff source-over blending.
///
/// RGB: `(COMBINED - DST_COLOR) * COMBINED_ALPHA + DST_COLOR`
///     = `src * alpha + dst * (1 - alpha)`
/// Alpha: pass-through
pub fn cc2_blend() -> CcMode2Reg {
    let mut reg = CcMode2Reg::default();
    // RGB: A=COMBINED, B=DST_COLOR, C=COMBINED_ALPHA (broadcast), D=DST_COLOR
    reg.set_c2_rgb_a(CcSourceE::CcCombined);
    reg.set_c2_rgb_b(CcSourceE::CcDstColor);
    reg.set_c2_rgb_c(CcRgbCSourceE::CcCCombinedAlpha);
    reg.set_c2_rgb_d(CcSourceE::CcDstColor);
    // Alpha: pass-through
    reg.set_c2_alpha_a(CcSourceE::CcCombined);
    reg.set_c2_alpha_b(CcSourceE::CcZero);
    reg.set_c2_alpha_c(CcSourceE::CcOne);
    reg.set_c2_alpha_d(CcSourceE::CcZero);
    reg
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{color_combine_2, CcInputs};
    use gs_twin_core::fragment::{ColorQ412, ColoredFragment};
    use qfixed::Q;

    /// Helper: create a `ColoredFragment` with given Q4.12 raw values.
    fn make_frag(r: i64, g: i64, b: i64, a: i64) -> ColoredFragment {
        ColoredFragment {
            x: 4,
            y: 4,
            z: 0,
            color: ColorQ412 {
                r: Q::from_bits(r),
                g: Q::from_bits(g),
                b: Q::from_bits(b),
                a: Q::from_bits(a),
            },
        }
    }

    /// Promote an RGB565 framebuffer pixel to Q4.12 per-channel.
    ///
    /// Matches RTL `fb_promote.sv` MSB-replication expansion.
    /// Full 5/6-bit values map to 0x0FFF (≈ 1.0 in Q4.12).
    fn promote_rgb565(pixel: u16) -> ColorQ412 {
        let r5 = (pixel >> 11) & 0x1F;
        let g6 = (pixel >> 5) & 0x3F;
        let b5 = pixel & 0x1F;

        let r_q412 = ((r5 << 7) | (r5 << 2) | (r5 >> 3)) + (r5 >> 4);
        let g_q412 = ((g6 << 6) | g6) + (g6 >> 5);
        let b_q412 = ((b5 << 7) | (b5 << 2) | (b5 >> 3)) + (b5 >> 4);

        ColorQ412 {
            r: Q::from_bits(r_q412 as i64),
            g: Q::from_bits(g_q412 as i64),
            b: Q::from_bits(b_q412 as i64),
            a: Q::from_bits(0x1000), // opaque
        }
    }

    #[test]
    fn disabled_passes_through() {
        let frag = make_frag(0x1000, 0, 0, 0x1000);
        let cc2 = cc2_disabled();
        let result = color_combine_2(
            frag,
            cc2,
            ColorQ412::default(),
            ColorQ412::default(),
            ColorQ412::default(),
        );
        assert_eq!(result.color.r.to_bits(), 0x1000);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn add_full_alpha_black_dst() {
        // src=0.25 alpha=1.0 dst=black -> src*1.0 + 0 = 0.25
        let frag = make_frag(0x0400, 0x0400, 0x0400, 0x1000);
        let dst = promote_rgb565(0x0000);
        let cc2 = cc2_add();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0x0400);
    }

    #[test]
    fn add_zero_alpha() {
        // src=1.0 alpha=0 dst=black -> src*0 + 0 = 0
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0);
        let dst = promote_rgb565(0x0000);
        let cc2 = cc2_add();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn add_half_alpha_black_dst() {
        // src=1.0 alpha=0.5 dst=black -> src*0.5 + 0 = 0.5
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x0800);
        let dst = promote_rgb565(0x0000);
        let cc2 = cc2_add();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0x0800);
    }

    #[test]
    fn subtract_full_alpha_from_white() {
        // src=1.0 alpha=1.0 dst=white(promoted ≈ 1.0)
        // dst - src*alpha = 0x0FFF - 0x1000 = -1, clamped to 0.
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x1000);
        let dst = promote_rgb565(0xFFFF);
        let cc2 = cc2_subtract();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0);
    }

    #[test]
    fn subtract_clamps_negative() {
        // src=1.0 alpha=1.0 dst=black -> 0 - 1.0 clamps to 0
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x1000);
        let dst = promote_rgb565(0x0000);
        let cc2 = cc2_subtract();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn blend_full_alpha() {
        // alpha=1.0 -> result = src
        let frag = make_frag(0x0800, 0x0400, 0x0C00, 0x1000);
        let dst = promote_rgb565(0xFFFF);
        let cc2 = cc2_blend();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0x0800);
        assert_eq!(result.color.g.to_bits(), 0x0400);
        assert_eq!(result.color.b.to_bits(), 0x0C00);
    }

    #[test]
    fn blend_zero_alpha() {
        // alpha=0 -> result = dst
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0);
        let dst = promote_rgb565(0x0000);
        let cc2 = cc2_blend();
        let result = color_combine_2(frag, cc2, ColorQ412::default(), ColorQ412::default(), dst);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }
}
