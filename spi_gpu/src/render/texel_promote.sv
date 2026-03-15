`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// Texel Promote — UQ1.8 Texel to Q4.12 Conversion
//
// Promotes a cached texel to four 16-bit Q4.12 signed fixed-point channels
// for the fragment pipeline.
//
// All 36 bits of texel_in are interpreted as four 9-bit UQ1.8 channels
// {R9, G9, B9, A9} and promoted via promote_uq18_to_q412() (left-shift by 4).
//
// UNORM color range [0.0, 1.0] maps to Q4.12 [0x0000, 0x1000].
//
// UQ1.8 bit layout per INT-032:
//   texel_in[35:27] = R9 (UQ1.8)
//   texel_in[26:18] = G9 (UQ1.8)
//   texel_in[17:9]  = B9 (UQ1.8)
//   texel_in[8:0]   = A9 (UQ1.8)
//
// See: INT-032 (Onward Conversion to Q4.12), UNIT-006 (Stage 3),
//      REQ-004.02 (Extended Precision Fragment Processing),
//      REQ-003.06 (FR-024-11), DD-038

module texel_promote (
    // Input: 36-bit texel from texture cache / decoder mux
    //   [35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9 (UQ1.8)
    input  wire [35:0] texel_in,

    // Output: Q4.12 per channel (16 bits each, signed, [0, 1.0] = [0x0000, 0x1000])
    output wire [15:0] r_q412,
    output wire [15:0] g_q412,
    output wire [15:0] b_q412,
    output wire [15:0] a_q412
);

    // ========================================================================
    // UQ1.8 Channel Extraction (all 36 bits)
    // ========================================================================

    wire [8:0] r9 = texel_in[35:27];
    wire [8:0] g9 = texel_in[26:18];
    wire [8:0] b9 = texel_in[17:9];
    wire [8:0] a9 = texel_in[8:0];

    // ========================================================================
    // Promotion to Q4.12: left-shift by 4
    // ========================================================================

    assign r_q412 = fp_types_pkg::promote_uq18_to_q412(r9);
    assign g_q412 = fp_types_pkg::promote_uq18_to_q412(g9);
    assign b_q412 = fp_types_pkg::promote_uq18_to_q412(b9);
    assign a_q412 = fp_types_pkg::promote_uq18_to_q412(a9);

endmodule

`default_nettype wire
