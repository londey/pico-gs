`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `f7ece909bb04a361` 2026-02-28
//
// fp_types_pkg — Q4.12 Fixed-Point Type Definitions and Promotion Functions
//
// Single authoritative source for the Q4.12 signed fixed-point type used
// throughout the pixel pipeline, along with named promotion functions for
// converting RGBA5652 texture cache channels and UNORM8 values to Q4.12.
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
    // RGBA5652 -> Q4.12 Promotion Functions
    // ========================================================================
    // These functions are the authoritative implementations of the RGBA5652 to
    // Q4.12 conversion formulas defined in INT-032. All consuming modules
    // (texel_promote.sv, color_combiner.sv, fb_promote.sv) should import this
    // package and call these functions to ensure bit-exact consistency.

    // R5 -> Q4.12: MSB replication to span [0.0, 1.0]
    // {3'b000, R5[4:0], R5[4:0], R5[4:2]} = 3+5+5+3 = 16 bits
    // R5=31 -> 0x0FFF (close to 1.0), R5=0 -> 0x0000
    function automatic q4_12_t promote_r5_to_q412(input logic [4:0] r5);
        return {3'b000, r5[4:0], r5[4:0], r5[4:2]};
    endfunction

    // G6 -> Q4.12: MSB replication to span [0.0, 1.0]
    // {3'b000, G6[5:0], G6[5:0], 1'b0} = 3+6+6+1 = 16 bits
    // G6=63 -> 0x0FFE (close to 1.0), G6=0 -> 0x0000
    function automatic q4_12_t promote_g6_to_q412(input logic [5:0] g6);
        return {3'b000, g6[5:0], g6[5:0], 1'b0};
    endfunction

    // B5 -> Q4.12: Same MSB replication as R5
    // {3'b000, B5[4:0], B5[4:0], B5[4:2]} = 3+5+5+3 = 16 bits
    // B5=31 -> 0x0FFF (close to 1.0), B5=0 -> 0x0000
    function automatic q4_12_t promote_b5_to_q412(input logic [4:0] b5);
        return {3'b000, b5[4:0], b5[4:0], b5[4:2]};
    endfunction

    // A2 -> Q4.12: Four-level expansion, equal spacing across [0.0, 1.0]
    //   00 -> 0x0000 (0.0)
    //   01 -> 0x0555 (0.333...)
    //   10 -> 0x0AAA (0.666...)
    //   11 -> 0x1000 (1.0)
    // NOTE: The a2 argument IS used as the case selector below. The lint tool
    // flags it as unused due to a known limitation with package function args.
    // verilator lint_off UNUSEDSIGNAL
    function automatic q4_12_t promote_a2_to_q412(input logic [1:0] a2);
        case (a2)
            2'b00:   return 16'sh0000;
            2'b01:   return 16'sh0555;
            2'b10:   return 16'sh0AAA;
            2'b11:   return 16'sh1000;
            default: return 16'sh0000;
        endcase
    endfunction
    // verilator lint_on UNUSEDSIGNAL

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
        return {4'b0000, unorm8[7:0], unorm8[7:4]};
    endfunction

endpackage

`default_nettype wire
