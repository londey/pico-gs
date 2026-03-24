`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC5 Texture Decoder — FORMAT=4
//
// Decodes a 128-bit BC5 compressed block to produce one texel in UQ1.8 format.
//
// BC5 block structure (16 bytes):
//   Bytes 0-7:   Red channel block (BC3-style alpha encoding)
//     [7:0]   = red0 (u8)
//     [15:8]  = red1 (u8)
//     [63:16] = 48-bit red index table (3 bits per texel)
//   Bytes 8-15:  Green channel block (BC3-style alpha encoding)
//     [71:64]  = green0 (u8)
//     [79:72]  = green1 (u8)
//     [127:80] = 48-bit green index table (3 bits per texel)
//
// Each channel uses BC3 alpha interpolation:
//   if endpoint0 > endpoint1: 8-entry interpolated palette
//   else: 6-entry interpolated + palette[6]=0, palette[7]=255
//
// All interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   /5: (x + 2) * 3277 >> 14  (6-entry mode, exact for x <= 1277)
//   /7: (x + 3) * 2341 >> 14  (8-entry mode, exact for x <= 1788)
//
// Output: R = decoded red via ch8_to_uq18, G = decoded green via ch8_to_uq18,
//         B = 9'h000, A = 9'h100 (opaque).
// Typically used for compressed two-channel normal maps (XY normals).
//
// See: INT-014 (Texture Memory Layout, Format 4), UNIT-011.04 (Block Decompressor),
//      REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc5 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [63:0]   = Red channel block (BC3-style alpha encoding)
    //   [127:64] = Green channel block (BC3-style alpha encoding)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Red Channel Block Decode (bits [63:0])
    // ========================================================================

    wire [7:0] red0 = block_data[7:0];
    wire [7:0] red1 = block_data[15:8];

    // Extract 3-bit red index for the selected texel.
    // Indices start at bit 16; each texel uses 3 bits.
    // 7-bit offset required for indexing into 128-bit block_data.
    wire [6:0] red_bit_offset = 7'd16 + {3'b000, texel_idx} + {3'b000, texel_idx} + {3'b000, texel_idx};
    wire [2:0] red_index = block_data[red_bit_offset +: 3];

    // Weighted sums for red interpolation (8-entry mode, divide by 7).
    wire [10:0] r0x6_r1x1 = {2'b0, red0} * 4'd6 + {3'b0, red1}         + 11'd3;
    wire [10:0] r0x5_r1x2 = {2'b0, red0} * 4'd5 + {2'b0, red1} * 4'd2  + 11'd3;
    wire [10:0] r0x4_r1x3 = {2'b0, red0} * 4'd4 + {2'b0, red1} * 4'd3  + 11'd3;
    wire [10:0] r0x3_r1x4 = {2'b0, red0} * 4'd3 + {2'b0, red1} * 4'd4  + 11'd3;
    wire [10:0] r0x2_r1x5 = {2'b0, red0} * 4'd2 + {2'b0, red1} * 4'd5  + 11'd3;
    wire [10:0] r0x1_r1x6 = {3'b0, red0}         + {2'b0, red1} * 4'd6  + 11'd3;

    // Weighted sums for red interpolation (6-entry mode, divide by 5).
    wire [10:0] r0x4_r1x1_r2 = {2'b0, red0} * 4'd4 + {3'b0, red1}         + 11'd2;
    wire [10:0] r0x3_r1x2_r2 = {2'b0, red0} * 4'd3 + {2'b0, red1} * 4'd2  + 11'd2;
    wire [10:0] r0x2_r1x3_r2 = {2'b0, red0} * 4'd2 + {2'b0, red1} * 4'd3  + 11'd2;
    wire [10:0] r0x1_r1x4_r2 = {3'b0, red0}         + {2'b0, red1} * 4'd4  + 11'd2;

    // verilator lint_off UNUSEDSIGNAL
    wire [22:0] rp_7_2 = {12'b0, r0x6_r1x1} * 23'd2341;
    wire [22:0] rp_7_3 = {12'b0, r0x5_r1x2} * 23'd2341;
    wire [22:0] rp_7_4 = {12'b0, r0x4_r1x3} * 23'd2341;
    wire [22:0] rp_7_5 = {12'b0, r0x3_r1x4} * 23'd2341;
    wire [22:0] rp_7_6 = {12'b0, r0x2_r1x5} * 23'd2341;
    wire [22:0] rp_7_7 = {12'b0, r0x1_r1x6} * 23'd2341;

    wire [22:0] rp_5_2 = {12'b0, r0x4_r1x1_r2} * 23'd3277;
    wire [22:0] rp_5_3 = {12'b0, r0x3_r1x2_r2} * 23'd3277;
    wire [22:0] rp_5_4 = {12'b0, r0x2_r1x3_r2} * 23'd3277;
    wire [22:0] rp_5_5 = {12'b0, r0x1_r1x4_r2} * 23'd3277;
    // verilator lint_on UNUSEDSIGNAL

    // Generate 8-entry red palette (same algorithm as BC3 alpha / BC4)
    reg [7:0] red_palette [0:7];

    always_comb begin
        red_palette[0] = red0;
        red_palette[1] = red1;

        if (red0 > red1) begin
            // 8-entry interpolated mode
            red_palette[2] = rp_7_2[21:14];
            red_palette[3] = rp_7_3[21:14];
            red_palette[4] = rp_7_4[21:14];
            red_palette[5] = rp_7_5[21:14];
            red_palette[6] = rp_7_6[21:14];
            red_palette[7] = rp_7_7[21:14];
        end else begin
            // 6-entry interpolated + 0 and 255
            red_palette[2] = rp_5_2[21:14];
            red_palette[3] = rp_5_3[21:14];
            red_palette[4] = rp_5_4[21:14];
            red_palette[5] = rp_5_5[21:14];
            red_palette[6] = 8'd0;
            red_palette[7] = 8'd255;
        end
    end

    wire [7:0] decoded_red = red_palette[red_index];

    // ========================================================================
    // Green Channel Block Decode (bits [127:64])
    // ========================================================================

    wire [7:0] green0 = block_data[71:64];
    wire [7:0] green1 = block_data[79:72];

    // Extract 3-bit green index for the selected texel.
    // Indices start at bit 80; each texel uses 3 bits.
    wire [6:0] green_bit_offset = 7'd80 + {3'b000, texel_idx} + {3'b000, texel_idx} + {3'b000, texel_idx};
    wire [2:0] green_index = block_data[green_bit_offset +: 3];

    // Weighted sums for green interpolation (8-entry mode, divide by 7).
    wire [10:0] g0x6_g1x1 = {2'b0, green0} * 4'd6 + {3'b0, green1}         + 11'd3;
    wire [10:0] g0x5_g1x2 = {2'b0, green0} * 4'd5 + {2'b0, green1} * 4'd2  + 11'd3;
    wire [10:0] g0x4_g1x3 = {2'b0, green0} * 4'd4 + {2'b0, green1} * 4'd3  + 11'd3;
    wire [10:0] g0x3_g1x4 = {2'b0, green0} * 4'd3 + {2'b0, green1} * 4'd4  + 11'd3;
    wire [10:0] g0x2_g1x5 = {2'b0, green0} * 4'd2 + {2'b0, green1} * 4'd5  + 11'd3;
    wire [10:0] g0x1_g1x6 = {3'b0, green0}         + {2'b0, green1} * 4'd6  + 11'd3;

    // Weighted sums for green interpolation (6-entry mode, divide by 5).
    wire [10:0] g0x4_g1x1_r2 = {2'b0, green0} * 4'd4 + {3'b0, green1}         + 11'd2;
    wire [10:0] g0x3_g1x2_r2 = {2'b0, green0} * 4'd3 + {2'b0, green1} * 4'd2  + 11'd2;
    wire [10:0] g0x2_g1x3_r2 = {2'b0, green0} * 4'd2 + {2'b0, green1} * 4'd3  + 11'd2;
    wire [10:0] g0x1_g1x4_r2 = {3'b0, green0}         + {2'b0, green1} * 4'd4  + 11'd2;

    // verilator lint_off UNUSEDSIGNAL
    wire [22:0] gp_7_2 = {12'b0, g0x6_g1x1} * 23'd2341;
    wire [22:0] gp_7_3 = {12'b0, g0x5_g1x2} * 23'd2341;
    wire [22:0] gp_7_4 = {12'b0, g0x4_g1x3} * 23'd2341;
    wire [22:0] gp_7_5 = {12'b0, g0x3_g1x4} * 23'd2341;
    wire [22:0] gp_7_6 = {12'b0, g0x2_g1x5} * 23'd2341;
    wire [22:0] gp_7_7 = {12'b0, g0x1_g1x6} * 23'd2341;

    wire [22:0] gp_5_2 = {12'b0, g0x4_g1x1_r2} * 23'd3277;
    wire [22:0] gp_5_3 = {12'b0, g0x3_g1x2_r2} * 23'd3277;
    wire [22:0] gp_5_4 = {12'b0, g0x2_g1x3_r2} * 23'd3277;
    wire [22:0] gp_5_5 = {12'b0, g0x1_g1x4_r2} * 23'd3277;
    // verilator lint_on UNUSEDSIGNAL

    // Generate 8-entry green palette (same algorithm as BC3 alpha / BC4)
    reg [7:0] green_palette [0:7];

    always_comb begin
        green_palette[0] = green0;
        green_palette[1] = green1;

        if (green0 > green1) begin
            // 8-entry interpolated mode
            green_palette[2] = gp_7_2[21:14];
            green_palette[3] = gp_7_3[21:14];
            green_palette[4] = gp_7_4[21:14];
            green_palette[5] = gp_7_5[21:14];
            green_palette[6] = gp_7_6[21:14];
            green_palette[7] = gp_7_7[21:14];
        end else begin
            // 6-entry interpolated + 0 and 255
            green_palette[2] = gp_5_2[21:14];
            green_palette[3] = gp_5_3[21:14];
            green_palette[4] = gp_5_4[21:14];
            green_palette[5] = gp_5_5[21:14];
            green_palette[6] = 8'd0;
            green_palette[7] = 8'd255;
        end
    end

    wire [7:0] decoded_green = green_palette[green_index];

    // ========================================================================
    // Output Assembly: UQ1.8 channel expansion
    // ========================================================================
    // R9 = {1'b0, R8} + R8[7] → 0..256 (0x100 = 1.0)
    // G9 = {1'b0, G8} + G8[7] → 0..256 (0x100 = 1.0)
    // B9 = 9'h000
    // A9 = 9'h100 (opaque)
    wire [8:0] red9   = {1'b0, decoded_red}   + {8'b0, decoded_red[7]};
    wire [8:0] green9 = {1'b0, decoded_green} + {8'b0, decoded_green[7]};

    assign texel_out = {red9, green9, 9'h000, 9'h100};

endmodule

`default_nettype wire
