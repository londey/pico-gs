//! Alpha blending — blend fragment color with framebuffer destination.
//!
//! Reads the destination pixel from the framebuffer, promotes it to
//! Q4.12, blends with the fragment color using the configured blend
//! mode, and writes the result back through the normal dither path.
//!
//! # RTL Implementation Notes
//!
//! Alpha blending promotes the framebuffer's UNORM RGB565 value to
//! Q4.12 before blending; the result follows the normal
//! dither-and-write path.
//! Requires an SDRAM framebuffer read (dst pixel).

use gpu_registers::components::alpha_blend_e::AlphaBlendE;
use gpu_registers::components::gpu_regs::named_types::fb_config_reg::FbConfigReg;
use gs_memory::GpuMemory;
use gs_twin_core::fragment::{ColorQ412, ColoredFragment};
use qfixed::Q;

/// Q4.12 value of 1.0 (0x1000).
const Q412_ONE: i64 = 0x1000;

/// Saturate a 17-bit intermediate Q4.12 value to [0, 0x1000].
///
/// Matches RTL `saturate_q412`: negative → 0, > 1.0 → 0x1000.
fn saturate_q412(val: i32) -> Q<4, 12> {
    if val < 0 {
        Q::from_bits(0)
    } else if val > Q412_ONE as i32 {
        Q::from_bits(Q412_ONE)
    } else {
        Q::from_bits(val as i64)
    }
}

/// Promote an RGB565 framebuffer pixel to Q4.12 per-channel.
///
/// Matches RTL `fb_promote.sv` MSB-replication expansion:
/// - R5: `{3'b0, r5[4:0], r5[4:0], r5[4:2]}`
/// - G6: `{3'b0, g6[5:0], g6[5:0], 1'b0}`
/// - B5: same as R5
fn promote_rgb565(pixel: u16) -> (Q<4, 12>, Q<4, 12>, Q<4, 12>) {
    let r5 = (pixel >> 11) & 0x1F;
    let g6 = (pixel >> 5) & 0x3F;
    let b5 = pixel & 0x1F;

    // R5: {3'b000, r5[4:0], r5[4:0], r5[4:2]} = 16 bits
    let r_q412 = (r5 << 8) | (r5 << 3) | (r5 >> 2);
    // G6: {3'b000, g6[5:0], g6[5:0], 1'b0} = 16 bits
    let g_q412 = (g6 << 7) | (g6 << 1);
    // B5: same pattern as R5
    let b_q412 = (b5 << 8) | (b5 << 3) | (b5 >> 2);

    (
        Q::from_bits(r_q412 as i64),
        Q::from_bits(g_q412 as i64),
        Q::from_bits(b_q412 as i64),
    )
}

/// Blend a fragment with the destination framebuffer pixel.
///
/// # Arguments
///
/// * `frag` - Colored fragment (after alpha test).
/// * `memory` - GPU memory (SDRAM backing store for destination reads).
/// * `fb_config` - Framebuffer configuration (base addresses, dimensions).
/// * `blend_mode` - Blend mode from RENDER_MODE register.
///
/// # Returns
///
/// The blended `ColoredFragment`.
pub fn alpha_blend(
    frag: ColoredFragment,
    memory: &GpuMemory,
    fb_config: &FbConfigReg,
    blend_mode: AlphaBlendE,
) -> ColoredFragment {
    if blend_mode == AlphaBlendE::Disabled {
        return frag;
    }

    // Read destination pixel from framebuffer
    let wl2 = fb_config.width_log2();
    let dst_rgb565 = memory.read_tiled(fb_config.color_base(), wl2, frag.x as u32, frag.y as u32);

    // Promote RGB565 → Q4.12
    let (dst_r, dst_g, dst_b) = promote_rgb565(dst_rgb565);

    let src_r = frag.color.r.to_bits() as i32;
    let src_g = frag.color.g.to_bits() as i32;
    let src_b = frag.color.b.to_bits() as i32;
    let src_a = frag.color.a.to_bits() as i32;
    let dst_r = dst_r.to_bits() as i32;
    let dst_g = dst_g.to_bits() as i32;
    let dst_b = dst_b.to_bits() as i32;

    // Pre-multiply source by alpha for ADD, SUBTRACT, and BLEND.
    // Q4.12 × Q4.12 → 32-bit product; extract [28:12] as Q4.12.
    let premul = |ch: i32| -> i32 { (ch * src_a) >> 12 };

    let (res_r, res_g, res_b) = match blend_mode {
        AlphaBlendE::Disabled => unreachable!(),

        AlphaBlendE::Add => {
            // dst + src*alpha, saturated to [0, 1.0]
            (
                saturate_q412(dst_r + premul(src_r)),
                saturate_q412(dst_g + premul(src_g)),
                saturate_q412(dst_b + premul(src_b)),
            )
        }

        AlphaBlendE::Subtract => {
            // dst - src*alpha, saturated to [0, 1.0]
            (
                saturate_q412(dst_r - premul(src_r)),
                saturate_q412(dst_g - premul(src_g)),
                saturate_q412(dst_b - premul(src_b)),
            )
        }

        AlphaBlendE::Blend => {
            // Porter-Duff source-over: src*a + dst*(1-a)
            let one_minus_a = Q412_ONE as i32 - src_a;

            // 32-bit signed multiply, extract bits [28:12] as 17-bit Q4.12
            let blend_ch = |s: i32, d: i32| -> Q<4, 12> {
                let prod = (s * src_a) + (d * one_minus_a);
                // Extract [28:12] — shift right by 12, truncate (no rounding)
                let shifted = prod >> 12;
                saturate_q412(shifted)
            };

            (
                blend_ch(src_r, dst_r),
                blend_ch(src_g, dst_g),
                blend_ch(src_b, dst_b),
            )
        }
    };

    ColoredFragment {
        x: frag.x,
        y: frag.y,
        z: frag.z,
        color: ColorQ412 {
            r: res_r,
            g: res_g,
            b: res_b,
            a: frag.color.a,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gs_memory::GpuMemory;

    /// Helper: create a `ColoredFragment` with given Q4.12 raw values.
    fn make_frag(r: i64, g: i64, b: i64, a: i64, x: u16, y: u16) -> ColoredFragment {
        ColoredFragment {
            x,
            y,
            z: 0,
            color: ColorQ412 {
                r: Q::from_bits(r),
                g: Q::from_bits(g),
                b: Q::from_bits(b),
                a: Q::from_bits(a),
            },
        }
    }

    /// Helper: create memory with a destination pixel.
    fn make_memory_with_dst(width_log2: u8, x: u32, y: u32, rgb565: u16) -> GpuMemory {
        let mut mem = GpuMemory::new();
        mem.write_tiled(0, width_log2, x, y, rgb565);
        mem
    }

    fn fb_cfg(wl2: u8) -> FbConfigReg {
        let mut cfg = FbConfigReg::default();
        cfg.set_color_base(0);
        cfg.set_width_log2(wl2);
        cfg.set_height_log2(wl2);
        cfg
    }

    #[test]
    fn disabled_passes_through() {
        let frag = make_frag(0x1000, 0, 0, 0x1000, 0, 0);
        let mem = GpuMemory::new();
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Disabled);
        assert_eq!(result.color.r.to_bits(), 0x1000);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn add_full_alpha() {
        // src=0.25 alpha=1.0 dst=black → src*1.0 + 0 = 0.25
        let frag = make_frag(0x0400, 0x0400, 0x0400, 0x1000, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0x0000);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Add);
        assert_eq!(result.color.r.to_bits(), 0x0400);
    }

    #[test]
    fn add_zero_alpha() {
        // src=1.0 alpha=0 dst=black → src*0 + 0 = 0 (alpha zeroes out src)
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0x0000);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Add);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn add_half_alpha() {
        // src=1.0 alpha=0.5 dst=black → src*0.5 + 0 = 0.5
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x0800, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0x0000);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Add);
        assert_eq!(result.color.r.to_bits(), 0x0800);
    }

    #[test]
    fn add_saturation() {
        // src=1.0 alpha=1.0 dst=white → saturates to 1.0
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x1000, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0xFFFF);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Add);
        assert_eq!(result.color.r.to_bits(), 0x1000);
        assert_eq!(result.color.g.to_bits(), 0x1000);
        assert_eq!(result.color.b.to_bits(), 0x1000);
    }

    #[test]
    fn subtract_full_alpha() {
        // src=1.0 alpha=1.0 dst=white → white - 1.0*1.0 = clamps to 0
        // (white promotes to ~0x1FFF, src*alpha=0x1000, result ~0x0FFF)
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x1000, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0xFFFF);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Subtract);
        // dst(~0x1FFF) - src*1.0(0x1000) = ~0x0FFF
        assert_eq!(result.color.r.to_bits(), 0x0FFF);
    }

    #[test]
    fn subtract_zero_alpha() {
        // src=1.0 alpha=0 dst=white → white - 1.0*0 = white (unchanged)
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0xFFFF);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Subtract);
        // dst unchanged since src*0 = 0
        assert_eq!(result.color.r.to_bits(), 0x1000);
    }

    #[test]
    fn subtract_clamps_negative() {
        // src=1.0 alpha=1.0 dst=black → 0 - 1.0 = clamps to 0
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0x1000, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0x0000);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Subtract);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn blend_full_alpha() {
        // alpha=1.0 → result = src
        let frag = make_frag(0x0800, 0x0400, 0x0C00, 0x1000, 4, 4);
        let mem = make_memory_with_dst(8, 4, 4, 0xFFFF);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Blend);
        assert_eq!(result.color.r.to_bits(), 0x0800);
        assert_eq!(result.color.g.to_bits(), 0x0400);
        assert_eq!(result.color.b.to_bits(), 0x0C00);
    }

    #[test]
    fn blend_zero_alpha() {
        // alpha=0 → result = dst
        let frag = make_frag(0x1000, 0x1000, 0x1000, 0, 4, 4);
        // dst = black
        let mem = make_memory_with_dst(8, 4, 4, 0x0000);
        let cfg = fb_cfg(8);
        let result = alpha_blend(frag, &mem, &cfg, AlphaBlendE::Blend);
        assert_eq!(result.color.r.to_bits(), 0);
        assert_eq!(result.color.g.to_bits(), 0);
        assert_eq!(result.color.b.to_bits(), 0);
    }

    #[test]
    fn promote_rgb565_white() {
        // White = 0xFFFF: R5=31, G6=63, B5=31
        let (r, g, b) = promote_rgb565(0xFFFF);
        // R5=31: {3'b000, 11111, 11111, 111} = 0b000_11111_11111_111 = 0x1FFF
        assert_eq!(r.to_bits(), 0x1FFF);
        // G6=63: {3'b000, 111111, 111111, 0} = 0b000_111111_111111_0 = 0x1FFE
        assert_eq!(g.to_bits(), 0x1FFE);
        assert_eq!(b.to_bits(), 0x1FFF);
    }

    #[test]
    fn promote_rgb565_black() {
        let (r, g, b) = promote_rgb565(0x0000);
        assert_eq!(r.to_bits(), 0);
        assert_eq!(g.to_bits(), 0);
        assert_eq!(b.to_bits(), 0);
    }
}
