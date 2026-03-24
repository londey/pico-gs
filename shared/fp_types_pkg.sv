`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `dc1fc845dfc0615c` 2026-03-23
//
// fp_types_pkg — Q4.12 Fixed-Point Type Definitions and Promotion Functions
//
// Single authoritative source for the Q4.12 signed fixed-point type used
// throughout the pixel pipeline, along with named promotion functions for
// converting UQ1.8 texture cache channels and UNORM8 values to Q4.12.
//
// Q4.12 format: 1 sign bit, 3 integer bits, 12 fractional bits (16 bits total).
// UNORM color range [0.0, 1.0] maps to [0x0000, 0x1000].
//
// Promotion formulas match INT-032 (Onward Conversion to Q4.12) and the
// existing texel_promote.sv implementation.
//
// See: UNIT-006 (Pixel Pipeline), UNIT-010 (Color Combiner), INT-032,
//      REQ-004.02 (Extended Precision Fragment Processing)

package fp_types_pkg;

    // ========================================================================
    // Q4.12 Signed Fixed-Point Type
    // ========================================================================
    // 16-bit signed: [15] sign, [14:12] integer, [11:0] fraction
    // Range: approximately -8.0 to +7.999755859375
    typedef logic signed [15:0] q4_12_t;

    // ========================================================================
    // Arithmetic Constants
    // ========================================================================
    // Package-level constants consumed by importing modules; suppress standalone
    // unused-parameter warnings.
    // verilator lint_off UNUSEDPARAM
    // 1.0 in Q4.12 = 0x1000 = 4096
    localparam q4_12_t Q412_ONE  = 16'sh1000;
    // 0.0 in Q4.12 = 0x0000
    localparam q4_12_t Q412_ZERO = 16'sh0000;
    // verilator lint_on UNUSEDPARAM

    // ========================================================================
    // UQ1.8 -> Q4.12 Promotion Function
    // ========================================================================
    // Promotes a 9-bit UQ1.8 channel value to Q4.12 by left-shifting 4 bits.
    // {3'b000, channel[8:0], 4'b0000} = 3+9+4 = 16 bits
    // UQ1.8 value 0x100 (1.0) maps to Q4.12 value 0x1000 (1.0).
    // UQ1.8 LSB resolution 2^-8 maps to Q4.12 resolution 2^-8, so no
    // precision is lost.
    //
    // Used for texel promotion (INT-032, UNIT-006 Stage 3).
    function automatic q4_12_t promote_uq18_to_q412(input logic [8:0] channel);
        promote_uq18_to_q412 = {3'b000, channel[8:0], 4'b0000};
    endfunction

    // ========================================================================
    // UNORM8 -> Q4.12 Promotion Function
    // ========================================================================
    // Promotes an 8-bit unsigned normalized value to Q4.12 using MSB replication.
    // {4'b0000, unorm8[7:0], unorm8[7:4]} = 4+8+4 = 16 bits
    // unorm8=255 -> 0x0FFF (close to 1.0), unorm8=0 -> 0x0000
    //
    // Used for vertex color promotion (FR-134-3) and CONST_COLOR register
    // promotion (RGBA8888 UNORM8 to Q4.12).
    function automatic q4_12_t promote_unorm8_to_q412(input logic [7:0] unorm8);
        promote_unorm8_to_q412 = {4'b0000, unorm8[7:0], unorm8[7:4]};
    endfunction

endpackage

`default_nettype wire
