//! Debug pixel tracing — detailed pipeline state dump for a single pixel.
//!
//! When `--debug-pixel X,Y` is specified, the GPU captures and prints
//! comprehensive state at each pipeline stage for every fragment emitted
//! at the given coordinates.
//! This module defines the captured-state types and formatting functions.

use super::color_combine::CcInputs;
use super::fragment::{ColorQ412, ColoredFragment, RasterFragment, TexturedFragment};
use crate::pipeline::rasterize::{RasterTriangle, RasterVertex};
use crate::reg_ext::reg_to_raw;
use gpu_registers::components::cc_rgb_c_source_e::CcRgbCSourceE;
use gpu_registers::components::cc_source_e::CcSourceE;
use gpu_registers::components::gpu_regs::named_types::cc_mode_reg::CcModeReg;
use gpu_registers::components::gpu_regs::named_types::const_color_reg::ConstColorReg;
use gpu_registers::components::gpu_regs::named_types::render_mode_reg::RenderModeReg;
use gpu_registers::components::gpu_regs::named_types::tex_cfg_reg::TexCfgReg;

/// Attribute names for printing accumulator state.
const ATTR_NAMES: [&str; 14] = [
    "C0R", "C0G", "C0B", "C0A", "C1R", "C1G", "C1B", "C1A", "Z", "S0", "T0", "Q", "S1", "T1",
];

/// Raw accumulator state captured from the rasterizer at fragment emission.
///
/// Populated only for debug-pixel fragments; `None` for normal rendering.
#[derive(Debug, Clone)]
pub struct RasterAccumulatorDebug {
    /// All 14 attribute accumulators (32-bit signed each).
    pub acc: [i32; 14],

    /// Top 16 bits of Q accumulator (input to `recip_q`).
    pub q_top: u16,

    /// UQ7.10 reciprocal of Q from `recip_q`.
    pub inv_q: u32,

    /// Top 16 bits of S0 accumulator (signed, before perspective correction).
    pub s0_top: i16,

    /// Top 16 bits of T0 accumulator.
    pub t0_top: i16,

    /// Top 16 bits of S1 accumulator.
    pub s1_top: i16,

    /// Top 16 bits of T1 accumulator.
    pub t1_top: i16,

    /// Full signed product `s0_top * inv_q` (before bit extraction).
    pub s0_product: i64,

    /// Full signed product `t0_top * inv_q`.
    pub t0_product: i64,

    /// Full signed product `s1_top * inv_q`.
    pub s1_product: i64,

    /// Full signed product `t1_top * inv_q`.
    pub t1_product: i64,

    /// CLZ count of the Q input to `recip_q`.
    pub recip_clz: u8,

    /// 10-bit LUT index used by `recip_q`.
    pub recip_lut_index: u16,

    /// Error of the computed 1/Q in UQ7.10 LSBs (positive = too small).
    pub recip_error_lsb: i32,
}

/// Print the debug-pixel header and triangle vertex data.
pub fn print_triangle_header(px: u16, py: u16, tri: &RasterTriangle) {
    eprintln!();
    eprintln!("╔══════════════════════════════════════════════════════════════╗");
    eprintln!("║  DEBUG PIXEL ({px}, {py})                                      ");
    eprintln!("╠══════════════════════════════════════════════════════════════╣");
    eprintln!("║  Triangle Vertices");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    for (i, v) in tri.verts.iter().enumerate() {
        print_vertex(i, v);
    }
    eprintln!(
        "  bbox: ({}, {}) - ({}, {})",
        tri.bbox_min_x, tri.bbox_min_y, tri.bbox_max_x, tri.bbox_max_y
    );
    eprintln!("  gouraud_en: {}", tri.gouraud_en);
}

/// Print a single vertex's attributes.
fn print_vertex(idx: usize, v: &RasterVertex) {
    eprintln!(
        "  V{idx}: px={:<4} py={:<4} z=0x{:04X} q=0x{:04X}",
        v.px, v.py, v.z, v.q
    );
    eprintln!(
        "       color0=0x{:08X} color1=0x{:08X}",
        v.color0.0, v.color1.0
    );
    eprintln!(
        "       s0=0x{:04X} t0=0x{:04X} s1=0x{:04X} t1=0x{:04X}",
        v.s0, v.t0, v.s1, v.t1
    );
}

/// Print raw accumulator state from the rasterizer.
pub fn print_raster_accum(dbg: &RasterAccumulatorDebug) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Raw Accumulators");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    for (i, name) in ATTR_NAMES.iter().enumerate() {
        eprintln!("  {name:>3} = 0x{:08X} ({})", dbg.acc[i] as u32, dbg.acc[i]);
    }
}

/// Print perspective correction intermediates.
pub fn print_perspective_correction(dbg: &RasterAccumulatorDebug, frag: &RasterFragment) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Perspective Correction");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    // Compute the floating-point value of 1/Q for readability
    let inv_q_float = dbg.inv_q as f64 / 1024.0;
    let q_float = dbg.q_top as f64 / 32768.0;
    eprintln!(
        "  q_top = 0x{:04X} ({:.6})  inv_q = 0x{:05X} (UQ7.10 = {:.6})",
        dbg.q_top, q_float, dbg.inv_q, inv_q_float
    );
    eprintln!(
        "  recip: clz={} lut_index={} error={} LSB ({:.4} UQ7.10)",
        dbg.recip_clz,
        dbg.recip_lut_index,
        dbg.recip_error_lsb,
        dbg.recip_error_lsb as f64 / 1024.0
    );
    eprintln!(
        "  S0: s_top=0x{:04X} ({:>6})  product=0x{:010X}  u0=0x{:04X} ({})",
        dbg.s0_top as u16,
        dbg.s0_top,
        dbg.s0_product as u64,
        frag.u0.to_bits() as u16,
        frag.u0.to_bits()
    );
    eprintln!(
        "  T0: t_top=0x{:04X} ({:>6})  product=0x{:010X}  v0=0x{:04X} ({})",
        dbg.t0_top as u16,
        dbg.t0_top,
        dbg.t0_product as u64,
        frag.v0.to_bits() as u16,
        frag.v0.to_bits()
    );
    eprintln!(
        "  S1: s_top=0x{:04X} ({:>6})  product=0x{:010X}  u1=0x{:04X} ({})",
        dbg.s1_top as u16,
        dbg.s1_top,
        dbg.s1_product as u64,
        frag.u1.to_bits() as u16,
        frag.u1.to_bits()
    );
    eprintln!(
        "  T1: t_top=0x{:04X} ({:>6})  product=0x{:010X}  v1=0x{:04X} ({})",
        dbg.t1_top as u16,
        dbg.t1_top,
        dbg.t1_product as u64,
        frag.v1.to_bits() as u16,
        frag.v1.to_bits()
    );
}

/// Print the raster fragment (post-perspective-correction).
pub fn print_raster_fragment(frag: &RasterFragment) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Raster Fragment");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!(
        "  x={} y={} z=0x{:04X} lod=0x{:02X}",
        frag.x, frag.y, frag.z, frag.lod
    );
    print_color_q412("shade0", &frag.shade0);
    print_color_q412("shade1", &frag.shade1);
    eprintln!(
        "  u0=0x{:04X} v0=0x{:04X} u1=0x{:04X} v1=0x{:04X}",
        frag.u0.to_bits() as u16,
        frag.v0.to_bits() as u16,
        frag.u1.to_bits() as u16,
        frag.v1.to_bits() as u16
    );
}

/// Print textured fragment state (after tex_sample).
pub fn print_textured_fragment(frag: &TexturedFragment) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  After Texture Sampling");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    print_color_q412("tex0", &frag.tex0);
    print_color_q412("tex1", &frag.tex1);
}

/// Print color combiner debug state for one stage.
pub fn print_combiner_stage(stage: u8, cc_mode: CcModeReg, inputs: &CcInputs, output: &ColorQ412) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Color Combiner Stage {stage}");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");

    if stage == 0 {
        let rgb_a = cc_mode.c0_rgb_a();
        let rgb_b = cc_mode.c0_rgb_b();
        let rgb_c = cc_mode.c0_rgb_c();
        let rgb_d = cc_mode.c0_rgb_d();
        let alpha_a = cc_mode.c0_alpha_a();
        let alpha_b = cc_mode.c0_alpha_b();
        let alpha_c = cc_mode.c0_alpha_c();
        let alpha_d = cc_mode.c0_alpha_d();

        eprintln!("  RGB:   A={rgb_a:?} B={rgb_b:?} C={rgb_c:?} D={rgb_d:?}");
        eprintln!("  Alpha: A={alpha_a:?} B={alpha_b:?} C={alpha_c:?} D={alpha_d:?}");

        let a_rgb = resolve_source_val(rgb_a, inputs);
        let b_rgb = resolve_source_val(rgb_b, inputs);
        let c_rgb = resolve_rgb_c_source_val(rgb_c, inputs);
        let d_rgb = resolve_source_val(rgb_d, inputs);
        eprintln!("  RGB resolved:");
        print_color_q412("    A", &a_rgb);
        print_color_q412("    B", &b_rgb);
        print_color_q412("    C", &c_rgb);
        print_color_q412("    D", &d_rgb);
    } else {
        let rgb_a = cc_mode.c1_rgb_a();
        let rgb_b = cc_mode.c1_rgb_b();
        let rgb_c = cc_mode.c1_rgb_c();
        let rgb_d = cc_mode.c1_rgb_d();
        let alpha_a = cc_mode.c1_alpha_a();
        let alpha_b = cc_mode.c1_alpha_b();
        let alpha_c = cc_mode.c1_alpha_c();
        let alpha_d = cc_mode.c1_alpha_d();

        eprintln!("  RGB:   A={rgb_a:?} B={rgb_b:?} C={rgb_c:?} D={rgb_d:?}");
        eprintln!("  Alpha: A={alpha_a:?} B={alpha_b:?} C={alpha_c:?} D={alpha_d:?}");

        let a_rgb = resolve_source_val(rgb_a, inputs);
        let b_rgb = resolve_source_val(rgb_b, inputs);
        let c_rgb = resolve_rgb_c_source_val(rgb_c, inputs);
        let d_rgb = resolve_source_val(rgb_d, inputs);
        eprintln!("  RGB resolved:");
        print_color_q412("    A", &a_rgb);
        print_color_q412("    B", &b_rgb);
        print_color_q412("    C", &c_rgb);
        print_color_q412("    D", &d_rgb);
    }

    print_color_q412("output", output);
}

/// Print the final colored fragment.
pub fn print_final_fragment(frag: &ColoredFragment) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Final Colored Fragment");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("  x={} y={} z=0x{:04X}", frag.x, frag.y, frag.z);
    print_color_q412("color", &frag.color);
}

/// Print a register state snapshot.
pub fn print_register_snapshot(
    render_mode: RenderModeReg,
    cc_mode: CcModeReg,
    tex0_cfg: Option<TexCfgReg>,
    tex1_cfg: Option<TexCfgReg>,
    const_color: ConstColorReg,
) {
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("║  Register State");
    eprintln!("╠──────────────────────────────────────────────────────────────╣");
    eprintln!("  render_mode = 0x{:016X}", reg_to_raw(render_mode));
    eprintln!("  cc_mode     = 0x{:016X}", reg_to_raw(cc_mode));
    if let Some(cfg) = tex0_cfg {
        eprintln!("  tex0_cfg    = 0x{:016X}", reg_to_raw(cfg));
    }
    if let Some(cfg) = tex1_cfg {
        eprintln!("  tex1_cfg    = 0x{:016X}", reg_to_raw(cfg));
    }
    eprintln!("  const_color = 0x{:016X}", reg_to_raw(const_color));
    eprintln!("╚══════════════════════════════════════════════════════════════╝");
    eprintln!();
}

/// Trigger a debugger breakpoint if a debugger is attached.
///
/// Uses `dbg_breakpoint::breakpoint_if_debugging()` to safely trigger
/// a platform-appropriate debug trap (e.g., INT3 on x86_64, BRK on
/// AArch64) only when a debugger is present.
/// When no debugger is attached, this is a no-op.
///
/// This function is also a convenient named symbol for setting a manual
/// debugger breakpoint (e.g.,
/// `break gs_twin::pipeline::debug_pixel::debug_breakpoint`).
#[inline(never)]
pub fn debug_breakpoint(px: u16, py: u16) {
    // Prevent the function from being optimized away.
    std::hint::black_box((px, py));
    dbg_breakpoint::breakpoint_if_debugging();
}

// ── Helper functions ────────────────────────────────────────────────────────

/// Print a Q4.12 color with label.
fn print_color_q412(label: &str, c: &ColorQ412) {
    eprintln!(
        "  {label}: R=0x{:04X} G=0x{:04X} B=0x{:04X} A=0x{:04X}",
        c.r.to_bits() as u16,
        c.g.to_bits() as u16,
        c.b.to_bits() as u16,
        c.a.to_bits() as u16,
    );
}

/// Resolve a standard combiner source (mirrors `color_combine::resolve_source`).
fn resolve_source_val(sel: CcSourceE, inputs: &CcInputs) -> ColorQ412 {
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
        _ => ColorQ412::default(),
    }
}

/// Resolve an extended RGB C source (mirrors `color_combine::resolve_rgb_c_source`).
fn resolve_rgb_c_source_val(sel: CcRgbCSourceE, inputs: &CcInputs) -> ColorQ412 {
    match sel {
        CcRgbCSourceE::CcCCombined => inputs.combined,
        CcRgbCSourceE::CcCTex0 => inputs.tex0,
        CcRgbCSourceE::CcCTex1 => inputs.tex1,
        CcRgbCSourceE::CcCShade0 => inputs.shade0,
        CcRgbCSourceE::CcCConst0 => inputs.const0,
        CcRgbCSourceE::CcCConst1 => inputs.const1,
        CcRgbCSourceE::CcCOne => ColorQ412::OPAQUE_WHITE,
        CcRgbCSourceE::CcCZero => ColorQ412::default(),
        CcRgbCSourceE::CcCTex0Alpha => alpha_broadcast(inputs.tex0),
        CcRgbCSourceE::CcCTex1Alpha => alpha_broadcast(inputs.tex1),
        CcRgbCSourceE::CcCShade0Alpha => alpha_broadcast(inputs.shade0),
        CcRgbCSourceE::CcCConst0Alpha => alpha_broadcast(inputs.const0),
        CcRgbCSourceE::CcCCombinedAlpha => alpha_broadcast(inputs.combined),
        CcRgbCSourceE::CcCShade1 => inputs.shade1,
        CcRgbCSourceE::CcCShade1Alpha => alpha_broadcast(inputs.shade1),
        CcRgbCSourceE::CcCRsvd15 => ColorQ412::default(),
    }
}

/// Broadcast alpha to all channels.
fn alpha_broadcast(c: ColorQ412) -> ColorQ412 {
    ColorQ412 {
        r: c.a,
        g: c.a,
        b: c.a,
        a: c.a,
    }
}
