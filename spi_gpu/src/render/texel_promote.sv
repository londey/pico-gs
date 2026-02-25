`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `ea25bc5506e6da48` 2026-02-24
//
// Texel Promote — RGBA5652 to Q4.12 Conversion
//
// Combinational module that promotes an 18-bit RGBA5652 cached texel to four
// 16-bit Q4.12 signed fixed-point channels for the fragment pipeline.
//
// UNORM color range [0.0, 1.0] maps to Q4.12 [0x0000, 0x1000].
// MSB-replication fills fractional bits to span the full [0, 1.0] range.
//
// Conversion formulas (INT-032):
//   R5 -> Q4.12: {3'b0, R5, R5[4:1], 3'b0}
//   G6 -> Q4.12: {3'b0, G6, G6[5:0], 2'b0} (note: spec uses G6[5:2] for 4 bits)
//   B5 -> Q4.12: {3'b0, B5, B5[4:1], 3'b0}
//   A2 -> Q4.12: 00->0x0000, 01->0x0555, 10->0x0AAA, 11->0x1000
//
// See: INT-032 (Onward Conversion to Q4.12), UNIT-006 (Stage 3),
//      REQ-004.02 (Extended Precision Fragment Processing),
//      REQ-003.06 (FR-024-11)

module texel_promote (
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
    // R5 -> Q4.12 Promotion
    // ========================================================================
    // Q4.12 has 16 bits: [15] sign, [14:12] integer, [11:0] fraction
    // Place R5 at [12:8], replicate MSBs to fill [7:0]:
    // {3'b0, R5[4:0], R5[4:0], R5[4:2]} = 3+5+5+3 = 16 bits
    // R5=31 -> 0x0FFF (close to 1.0), R5=0 -> 0x0000

    assign r_q412 = {3'b000, r5[4:0], r5[4:0], r5[4:2]};

    // ========================================================================
    // G6 -> Q4.12 Promotion
    // ========================================================================
    // Place G6 at [12:7], replicate MSBs to fill [6:0]:
    // {3'b0, G6[5:0], G6[5:0], 1'b0} = 3+6+6+1 = 16 bits
    // G6=63 -> 0x0FFE (close to 1.0), G6=0 -> 0x0000

    assign g_q412 = {3'b000, g6[5:0], g6[5:0], 1'b0};

    // ========================================================================
    // B5 -> Q4.12 Promotion
    // ========================================================================
    // Same MSB-replication as R5.

    assign b_q412 = {3'b000, b5[4:0], b5[4:0], b5[4:2]};

    // ========================================================================
    // A2 -> Q4.12 Promotion
    // ========================================================================
    // Four-level expansion: equal spacing across [0, 1.0].
    //   00 -> 0x0000 (0.0)
    //   01 -> 0x0555 (0.333...)
    //   10 -> 0x0AAA (0.666...)
    //   11 -> 0x1000 (1.0)

    reg [15:0] a_q412_reg;

    always_comb begin
        case (a2)
            2'b00:   a_q412_reg = 16'h0000;
            2'b01:   a_q412_reg = 16'h0555;
            2'b10:   a_q412_reg = 16'h0AAA;
            2'b11:   a_q412_reg = 16'h1000;
            default: a_q412_reg = 16'h0000;
        endcase
    end

    assign a_q412 = a_q412_reg;

endmodule

`default_nettype wire
