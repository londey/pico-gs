`default_nettype none

// Spec-ref: unit_011_texture_sampler.md `692b2d18436a5eaa` 2026-04-23
//
// Texture Sampler — Assembly Module
//
// Top-level wiring for a single texture sampler unit.
// Instantiates UV coordinate processing (UNIT-011.01) and bilinear
// filtering (UNIT-011.02), connecting them through tap coordinates
// and fractional weights.
//
// Data flow:
//   UV (Q4.12) + config → [texture_uv_coord] → tap coords + frac weights
//   tap coords → (external cache lookup) → 4 × UQ1.8 texels
//   texels + frac weights → [texture_bilinear] → sampled texel (UQ1.8)
//
// See: UNIT-011.01 (UV Coord), UNIT-011.02 (Bilinear Filter),
//      UNIT-011 (Texture Sampler), tex_sample.rs (DT reference)

module texture_sampler (
    input  wire         clk,
    input  wire         rst_n,

    // ====================================================================
    // UV Input (Q4.12 signed from rasterizer)
    // ====================================================================
    input  wire [15:0]  u_q412,          // U coordinate, Q4.12
    input  wire [15:0]  v_q412,          // V coordinate, Q4.12

    // ====================================================================
    // Texture Configuration
    // ====================================================================
    input  wire [3:0]   width_log2,      // Texture width = 1 << width_log2
    input  wire [3:0]   height_log2,     // Texture height = 1 << height_log2
    input  wire [1:0]   u_wrap,          // U wrap mode (WrapModeE)
    input  wire [1:0]   v_wrap,          // V wrap mode (WrapModeE)
    input  wire [1:0]   filter_mode,     // Filter mode (TexFilterE)

    // ====================================================================
    // Texel Coordinate Output (to cache lookup)
    // ====================================================================
    // For nearest: only tap0 coordinates are used.
    // For bilinear: all 4 tap coordinates are used.
    output wire [9:0]   tap0_x,          // Tap 0 wrapped texel X
    output wire [9:0]   tap0_y,          // Tap 0 wrapped texel Y
    output wire [9:0]   tap1_x,          // Tap 1 (tx+1, ty)
    output wire [9:0]   tap1_y,
    output wire [9:0]   tap2_x,          // Tap 2 (tx, ty+1)
    output wire [9:0]   tap2_y,
    output wire [9:0]   tap3_x,          // Tap 3 (tx+1, ty+1)
    output wire [9:0]   tap3_y,

    output wire         is_bilinear,     // 1 if bilinear/trilinear mode

    // ====================================================================
    // Texel Input from Cache (4 bank outputs, UQ1.8 RGBA)
    // ====================================================================
    // For nearest: only texel_in_nearest is used (selected externally).
    // For bilinear: all 4 texels at tap positions are provided.
    input  wire [35:0]  texel_tap0,      // Texel at (tap0_x, tap0_y)
    input  wire [35:0]  texel_tap1,      // Texel at (tap1_x, tap1_y)
    input  wire [35:0]  texel_tap2,      // Texel at (tap2_x, tap2_y)
    input  wire [35:0]  texel_tap3,      // Texel at (tap3_x, tap3_y)

    // ====================================================================
    // Sampled Texel Output (UQ1.8 RGBA)
    // ====================================================================
    output wire [35:0]  texel_out        // Blended texel result
);

    // ====================================================================
    // Filter mode detection
    // ====================================================================

    assign is_bilinear = (filter_mode == 2'd1) || (filter_mode == 2'd2);

    // ====================================================================
    // Internal wires: UV coord → bilinear filter
    // ====================================================================

    wire [7:0] frac_u;                   // Sub-texel U fraction, UQ0.8
    wire [7:0] frac_v;                   // Sub-texel V fraction, UQ0.8

    // ====================================================================
    // UNIT-011.01: UV Coordinate Processing
    // ====================================================================

    texture_uv_coord u_uv_coord (
        .u_q412      (u_q412),
        .v_q412      (v_q412),
        .width_log2  (width_log2),
        .height_log2 (height_log2),
        .u_wrap      (u_wrap),
        .v_wrap      (v_wrap),
        .is_bilinear (is_bilinear),
        .tap0_x      (tap0_x),
        .tap0_y      (tap0_y),
        .tap1_x      (tap1_x),
        .tap1_y      (tap1_y),
        .tap2_x      (tap2_x),
        .tap2_y      (tap2_y),
        .tap3_x      (tap3_x),
        .tap3_y      (tap3_y),
        .frac_u      (frac_u),
        .frac_v      (frac_v)
    );

    // ====================================================================
    // UNIT-011.02: Bilinear Filter
    // ====================================================================

    texture_bilinear u_bilinear (
        .frac_u      (frac_u),
        .frac_v      (frac_v),
        .is_bilinear (is_bilinear),
        .texel_tap0  (texel_tap0),
        .texel_tap1  (texel_tap1),
        .texel_tap2  (texel_tap2),
        .texel_tap3  (texel_tap3),
        .texel_out   (texel_out)
    );

    // ====================================================================
    // Suppress unused warnings
    // ====================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_clk   = clk;
    wire _unused_rst_n = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
