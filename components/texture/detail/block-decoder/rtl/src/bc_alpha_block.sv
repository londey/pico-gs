`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC Alpha Block Decode — Shared BC3 Alpha / BC4 Red Interpolation
//
// Decodes a 64-bit BC3-style alpha block (two 8-bit endpoints + 48-bit
// 3-bit index table) and selects one interpolated value.
//
// Two modes determined by endpoint0 vs endpoint1 comparison:
//   endpoint0 >  endpoint1: 8-entry interpolated palette (divide by 7)
//   endpoint0 <= endpoint1: 6-entry interpolated + 0, 255 (divide by 5)
//
// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   /7: (x + 3) * 2341 >> 14  (exact for x <= 1788)
//   /5: (x + 2) * 3277 >> 14  (exact for x <= 1277)
//
// Used by BC3 (alpha channel) and BC4 (red channel, replicated to RGB).
//
// See: INT-014, INT-032, UNIT-006, REQ-003.03, DD-038, DD-039

module bc_alpha_block (
    // Two 8-bit endpoints
    input  wire [7:0]  endpoint0,
    input  wire [7:0]  endpoint1,

    // 48-bit index table (3 bits per texel, 16 texels)
    input  wire [47:0] index_data,

    // Texel selection within 4x4 block (0..15)
    input  wire [3:0]  texel_idx,

    // Decoded value (8-bit, before UQ1.8 expansion)
    output wire [7:0]  decoded_value
);

    // ========================================================================
    // Index Extraction
    // ========================================================================
    // Each texel uses 3 bits; bit_offset = texel_idx * 3

    wire [5:0] idx_bit_offset = {2'b00, texel_idx} + {2'b00, texel_idx} + {2'b00, texel_idx};
    wire [2:0] alpha_index = index_data[idx_bit_offset +: 3];

    // ========================================================================
    // Weighted Sums for 8-Entry Mode (/7 rounding)
    // ========================================================================

    wire [10:0] w7_2 = {2'b0, endpoint0} * 4'd6 + {3'b0, endpoint1}         + 11'd3;
    wire [10:0] w7_3 = {2'b0, endpoint0} * 4'd5 + {2'b0, endpoint1} * 4'd2  + 11'd3;
    wire [10:0] w7_4 = {2'b0, endpoint0} * 4'd4 + {2'b0, endpoint1} * 4'd3  + 11'd3;
    wire [10:0] w7_5 = {2'b0, endpoint0} * 4'd3 + {2'b0, endpoint1} * 4'd4  + 11'd3;
    wire [10:0] w7_6 = {2'b0, endpoint0} * 4'd2 + {2'b0, endpoint1} * 4'd5  + 11'd3;
    wire [10:0] w7_7 = {3'b0, endpoint0}         + {2'b0, endpoint1} * 4'd6  + 11'd3;

    // ========================================================================
    // Weighted Sums for 6-Entry Mode (/5 rounding)
    // ========================================================================

    wire [10:0] w5_2 = {2'b0, endpoint0} * 4'd4 + {3'b0, endpoint1}         + 11'd2;
    wire [10:0] w5_3 = {2'b0, endpoint0} * 4'd3 + {2'b0, endpoint1} * 4'd2  + 11'd2;
    wire [10:0] w5_4 = {2'b0, endpoint0} * 4'd2 + {2'b0, endpoint1} * 4'd3  + 11'd2;
    wire [10:0] w5_5 = {3'b0, endpoint0}         + {2'b0, endpoint1} * 4'd4  + 11'd2;

    // ========================================================================
    // Reciprocal Multiply Products
    // ========================================================================

    // verilator lint_off UNUSEDSIGNAL
    wire [22:0] p7_2 = {12'b0, w7_2} * 23'd2341;
    wire [22:0] p7_3 = {12'b0, w7_3} * 23'd2341;
    wire [22:0] p7_4 = {12'b0, w7_4} * 23'd2341;
    wire [22:0] p7_5 = {12'b0, w7_5} * 23'd2341;
    wire [22:0] p7_6 = {12'b0, w7_6} * 23'd2341;
    wire [22:0] p7_7 = {12'b0, w7_7} * 23'd2341;

    wire [22:0] p5_2 = {12'b0, w5_2} * 23'd3277;
    wire [22:0] p5_3 = {12'b0, w5_3} * 23'd3277;
    wire [22:0] p5_4 = {12'b0, w5_4} * 23'd3277;
    wire [22:0] p5_5 = {12'b0, w5_5} * 23'd3277;
    // verilator lint_on UNUSEDSIGNAL

    // ========================================================================
    // Palette Generation
    // ========================================================================

    wire eight_entry_mode = (endpoint0 > endpoint1);

    reg [7:0] palette [0:7];

    always_comb begin
        palette[0] = endpoint0;
        palette[1] = endpoint1;

        if (eight_entry_mode) begin
            palette[2] = p7_2[21:14];
            palette[3] = p7_3[21:14];
            palette[4] = p7_4[21:14];
            palette[5] = p7_5[21:14];
            palette[6] = p7_6[21:14];
            palette[7] = p7_7[21:14];
        end else begin
            palette[2] = p5_2[21:14];
            palette[3] = p5_3[21:14];
            palette[4] = p5_4[21:14];
            palette[5] = p5_5[21:14];
            palette[6] = 8'd0;
            palette[7] = 8'd255;
        end
    end

    // ========================================================================
    // Output
    // ========================================================================

    assign decoded_value = palette[alpha_index];

endmodule

`default_nettype wire
