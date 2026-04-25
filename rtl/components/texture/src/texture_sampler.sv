`default_nettype none

// Spec-ref: unit_011_texture_sampler.md `5bceb0685e6d8ee8` 2026-04-25
//
// Texture Sampler -- Assembly Module (NEAREST-only)
//
// Top-level wiring for a single texture sampler unit. pico-gs implements
// NEAREST (point-sample) filtering only; there is no bilinear/trilinear
// filter stage. This module instantiates UV coordinate processing
// (UNIT-011.01) and passes the single fetched texel straight through to
// the output.
//
// Data flow:
//   UV (Q4.12) + config -> [texture_uv_coord] -> wrapped texel coord
//                                              + sub-texel position
//   wrapped coord -> (external L1 cache lookup) -> texel_tap0 (UQ1.8)
//   texel_tap0 -> texel_out (pass-through)
//
// See: UNIT-011.01 (UV Coord), UNIT-011 (Texture Sampler),
//      tex_sample.rs (DT reference)

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

    // ====================================================================
    // Texel Coordinate Output (to L1 cache lookup)
    // ====================================================================
    output wire [9:0]   tap0_x,          // Wrapped texel X
    output wire [9:0]   tap0_y,          // Wrapped texel Y

    // ====================================================================
    // Sub-Texel Position (within enclosing 4x4 block, to L1 cache)
    // ====================================================================
    output wire [1:0]   sub_u,           // Column within 4x4 block
    output wire [1:0]   sub_v,           // Row within 4x4 block

    // ====================================================================
    // Texel Input from Cache (UQ1.8 RGBA)
    // ====================================================================
    input  wire [35:0]  texel_tap0,      // Texel at (tap0_x, tap0_y)

    // ====================================================================
    // Sampled Texel Output (UQ1.8 RGBA)
    // ====================================================================
    output wire [35:0]  texel_out        // Sampled texel result
);

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
        .tap0_x      (tap0_x),
        .tap0_y      (tap0_y),
        .sub_u       (sub_u),
        .sub_v       (sub_v)
    );

    // ====================================================================
    // NEAREST pass-through
    // ====================================================================
    // Single fetched texel from the L1 cache flows directly to the output.

    assign texel_out = texel_tap0;

    // ====================================================================
    // Suppress unused warnings
    // ====================================================================
    // clk/rst_n are exposed for future pipelined variants but unused in the
    // current purely combinational NEAREST-only assembly.

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_clk   = clk;
    wire _unused_rst_n = rst_n;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
