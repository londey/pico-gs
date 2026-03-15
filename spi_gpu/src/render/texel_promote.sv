`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// Texel Promote — Dual-Mode Texel to Q4.12 Conversion
//
// Promotes a cached texel to four 16-bit Q4.12 signed fixed-point channels
// for the fragment pipeline.  Supports two cache modes selected by
// `cache_mode`:
//
//   CACHE_MODE=0 (RGBA5652): Lower 18 bits of texel_in are interpreted as
//     RGBA5652 and promoted via MSB-replication (promote_r5/g6/b5/a2).
//
//   CACHE_MODE=1 (UQ1.8): All 36 bits of texel_in are interpreted as four
//     9-bit UQ1.8 channels {R9, G9, B9, A9} and promoted via
//     promote_uq18_to_q412() (left-shift by 4).
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
    // Cache mode: 0 = RGBA5652 (18-bit), 1 = UQ1.8 (36-bit)
    input  wire        cache_mode,

    // Input: 36-bit texel from texture cache / decoder mux
    //   CACHE_MODE=0: [17:0] = RGBA5652 {R5, G6, B5, A2}, [35:18] unused
    //   CACHE_MODE=1: [35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9 (UQ1.8)
    input  wire [35:0] texel_in,

    // Output: Q4.12 per channel (16 bits each, signed, [0, 1.0] = [0x0000, 0x1000])
    output wire [15:0] r_q412,
    output wire [15:0] g_q412,
    output wire [15:0] b_q412,
    output wire [15:0] a_q412
);

    // ========================================================================
    // CACHE_MODE=0: RGBA5652 Channel Extraction (lower 18 bits)
    // ========================================================================

    wire [4:0] r5 = texel_in[17:13];
    wire [5:0] g6 = texel_in[12:7];
    wire [4:0] b5 = texel_in[6:2];
    wire [1:0] a2 = texel_in[1:0];

    wire [15:0] r_rgba5652 = fp_types_pkg::promote_r5_to_q412(r5);
    wire [15:0] g_rgba5652 = fp_types_pkg::promote_g6_to_q412(g6);
    wire [15:0] b_rgba5652 = fp_types_pkg::promote_b5_to_q412(b5);
    wire [15:0] a_rgba5652 = fp_types_pkg::promote_a2_to_q412(a2);

    // ========================================================================
    // CACHE_MODE=1: UQ1.8 Channel Extraction (all 36 bits)
    // ========================================================================

    wire [8:0] r9 = texel_in[35:27];
    wire [8:0] g9 = texel_in[26:18];
    wire [8:0] b9 = texel_in[17:9];
    wire [8:0] a9 = texel_in[8:0];

    wire [15:0] r_uq18 = fp_types_pkg::promote_uq18_to_q412(r9);
    wire [15:0] g_uq18 = fp_types_pkg::promote_uq18_to_q412(g9);
    wire [15:0] b_uq18 = fp_types_pkg::promote_uq18_to_q412(b9);
    wire [15:0] a_uq18 = fp_types_pkg::promote_uq18_to_q412(a9);

    // ========================================================================
    // Output Mux: Select Promotion Path by cache_mode
    // ========================================================================

    assign r_q412 = cache_mode ? r_uq18 : r_rgba5652;
    assign g_q412 = cache_mode ? g_uq18 : g_rgba5652;
    assign b_q412 = cache_mode ? b_uq18 : b_rgba5652;
    assign a_q412 = cache_mode ? a_uq18 : a_rgba5652;

endmodule

`default_nettype wire
