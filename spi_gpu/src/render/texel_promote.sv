`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `af6f054089e37f68` 2026-03-01
//
// Texel Promote — RGBA5652 to Q4.12 Conversion
//
// Thin wrapper that promotes an 18-bit RGBA5652 cached texel to four
// 16-bit Q4.12 signed fixed-point channels for the fragment pipeline.
// Delegates to the named promotion functions in fp_types_pkg.
//
// UNORM color range [0.0, 1.0] maps to Q4.12 [0x0000, 0x1000].
// MSB-replication fills fractional bits to span the full [0, 1.0] range.
//
// Conversion formulas (INT-032, implemented in fp_types_pkg):
//   R5 -> Q4.12: promote_r5_to_q412()
//   G6 -> Q4.12: promote_g6_to_q412()
//   B5 -> Q4.12: promote_b5_to_q412()
//   A2 -> Q4.12: promote_a2_to_q412()
//
// See: INT-032 (Onward Conversion to Q4.12), UNIT-006 (Stage 3),
//      REQ-004.02 (Extended Precision Fragment Processing),
//      REQ-003.06 (FR-024-11)

module texel_promote
    import fp_types_pkg::*;
(
    // Input: RGBA5652 from texture cache (18 bits)
    //   [17:13] = R5
    //   [12:7]  = G6
    //   [6:2]   = B5
    //   [1:0]   = A2
    input  wire [17:0] rgba5652,

    // Output: Q4.12 per channel (16 bits each, signed, [0, 1.0] = [0x0000, 0x1000])
    output wire [15:0] r_q412,
    output wire [15:0] g_q412,
    output wire [15:0] b_q412,
    output wire [15:0] a_q412
);

    // ========================================================================
    // Channel Extraction
    // ========================================================================

    wire [4:0] r5 = rgba5652[17:13];
    wire [5:0] g6 = rgba5652[12:7];
    wire [4:0] b5 = rgba5652[6:2];
    wire [1:0] a2 = rgba5652[1:0];

    // ========================================================================
    // Promotion via fp_types_pkg Functions
    // ========================================================================
    // All promotion formulas are defined once in fp_types_pkg (INT-032).
    // This module delegates to those functions to ensure bit-exact consistency
    // across all promotion call sites.

    assign r_q412 = promote_r5_to_q412(r5);

    assign g_q412 = promote_g6_to_q412(g6);

    assign b_q412 = promote_b5_to_q412(b5);

    assign a_q412 = promote_a2_to_q412(a2);

endmodule

`default_nettype wire
