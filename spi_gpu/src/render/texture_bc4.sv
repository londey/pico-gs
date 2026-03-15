`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// BC4 Texture Decoder — FORMAT=3
//
// Decodes a 64-bit BC4 compressed block to produce one texel in either
// RGBA5652 format (CACHE_MODE=0) or UQ1.8 format (CACHE_MODE=1).
//
// BC4 stores a single channel (red) using the BC3 alpha block encoding:
//   Bytes 0-1: red0 (u8), red1 (u8)
//   Bytes 2-7: 6-byte 3-bit index table (16 texels)
//
// CACHE_MODE=0: R=decoded value, replicated to G and B; A=opaque (A2=11).
//   INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
// CACHE_MODE=1: R8→UQ1.8 replicated to G and B; A=opaque (A9=9'h100).
//   R9=G9=B9={1'b0, R8} + R8[7], A9=9'h100
//
// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   /7: (x * 2341) >> 14  (exact for x <= 1788)
//   /5: (x * 3277) >> 14  (exact for x <= 1277)
//
// See: INT-014 (Texture Memory Layout, Format 3), INT-032 (Texture Cache, BC4),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-037, DD-038, DD-039

module texture_bc4 (
    // Block data: 64 bits (8 bytes, little-endian)
    //   [7:0]   = red0 (u8)
    //   [15:8]  = red1 (u8)
    //   [63:16] = 48-bit red index table (3 bits per texel)
    input  wire [63:0]  block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Cache mode: 0 = RGBA5652 (18-bit), 1 = UQ1.8 (36-bit)
    input  wire         cache_mode,

    // Decoded output: 36 bits
    //   CACHE_MODE=0: [35:18]=0, [17:0]=RGBA5652 {R5, G6, B5, A2}
    //   CACHE_MODE=1: [35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9 (UQ1.8)
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Red Block Decode (same encoding as BC3 alpha block)
    // ========================================================================

    wire [7:0] red0 = block_data[7:0];
    wire [7:0] red1 = block_data[15:8];

    // Extract 3-bit index for the selected texel.
    // Indices start at bit 16; each texel uses 3 bits.
    // bit_offset = 16 + texel_idx * 3
    wire [5:0] idx_bit_offset = 6'd16 + {2'b00, texel_idx} + {2'b00, texel_idx} + {2'b00, texel_idx};
    wire [2:0] red_index = block_data[idx_bit_offset +: 3];

    // Weighted sums for red interpolation.
    // Division by 7: (sum * 2341) >> 14 (DD-039)
    // Division by 5: (sum * 3277) >> 14 (DD-039)
    wire [10:0] r0x6_r1x1 = {2'b0, red0} * 4'd6 + {3'b0, red1}         + 11'd3;
    wire [10:0] r0x5_r1x2 = {2'b0, red0} * 4'd5 + {2'b0, red1} * 4'd2  + 11'd3;
    wire [10:0] r0x4_r1x3 = {2'b0, red0} * 4'd4 + {2'b0, red1} * 4'd3  + 11'd3;
    wire [10:0] r0x3_r1x4 = {2'b0, red0} * 4'd3 + {2'b0, red1} * 4'd4  + 11'd3;
    wire [10:0] r0x2_r1x5 = {2'b0, red0} * 4'd2 + {2'b0, red1} * 4'd5  + 11'd3;
    wire [10:0] r0x1_r1x6 = {3'b0, red0}         + {2'b0, red1} * 4'd6  + 11'd3;

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

    // Generate 8-entry red palette (same algorithm as BC3 alpha)
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
    // Output Assembly
    // ========================================================================

    // CACHE_MODE=0: RGBA5652 channel replication
    // INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
    wire [17:0] rgba5652 = {decoded_red[7:3], decoded_red[7:2], decoded_red[7:3], 2'b11};

    // CACHE_MODE=1: UQ1.8 channel replication
    // R9 = {1'b0, R8} + R8[7] → 0..256 (0x100 = 1.0)
    wire [8:0] red9 = {1'b0, decoded_red} + {8'b0, decoded_red[7]};

    assign texel_out = cache_mode ? {red9, red9, red9, 9'h100} : {18'b0, rgba5652};

endmodule

`default_nettype wire
