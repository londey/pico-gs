`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// BC3 Texture Decoder — FORMAT=2
//
// Decodes a 128-bit BC3 compressed block to produce one texel in UQ1.8 format.
//
// BC3 block structure (16 bytes):
//   Bytes 0-1:  alpha0 (u8), alpha1 (u8)
//   Bytes 2-7:  6-byte alpha index table (3 bits per texel, 16 texels = 48 bits)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// Alpha palette generation:
//   if alpha0 > alpha1: 8-entry interpolated palette
//   else: 6-entry interpolated + palette[6]=0, palette[7]=255
//
// All interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   /3: (x * 683) >> 11   (color, exact for x <= 769)
//   /5: (x * 3277) >> 14  (alpha 6-entry mode, exact for x <= 1277)
//   /7: (x * 2341) >> 14  (alpha 8-entry mode, exact for x <= 1788)
//
// A8 expanded to UQ1.8; color endpoints expanded to UQ1.8 and interpolated
// at 9-bit precision. Output {R9, G9, B9, A9}.
//
// See: INT-014 (Texture Memory Layout, Format 2), INT-032 (Texture Cache, BC3),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc3 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [7:0]    = alpha0 (u8)
    //   [15:8]   = alpha1 (u8)
    //   [63:16]  = 48-bit alpha index table (3 bits per texel)
    //   [127:64] = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Alpha Block Decode (bytes 0-7)
    // ========================================================================

    wire [7:0] alpha0 = block_data[7:0];
    wire [7:0] alpha1 = block_data[15:8];

    // Extract 3-bit alpha index for the selected texel.
    // bit_offset = 16 + texel_idx * 3
    wire [6:0] alpha_idx_bit_offset = 7'd16 + {3'b000, texel_idx} + {3'b000, texel_idx} + {3'b000, texel_idx};
    wire [2:0] alpha_index = block_data[alpha_idx_bit_offset +: 3];

    // Weighted sums for alpha interpolation.
    // Division by 7: (sum * 2341) >> 14 (DD-039, exact for sum <= 1788)
    // Division by 5: (sum * 3277) >> 14 (DD-039, exact for sum <= 1277)
    // Only bits [21:14] of each product are used (8-bit quotient).
    wire [10:0] a0x6_a1x1 = {2'b0, alpha0} * 4'd6 + {3'b0, alpha1}         + 11'd3;
    wire [10:0] a0x5_a1x2 = {2'b0, alpha0} * 4'd5 + {2'b0, alpha1} * 4'd2  + 11'd3;
    wire [10:0] a0x4_a1x3 = {2'b0, alpha0} * 4'd4 + {2'b0, alpha1} * 4'd3  + 11'd3;
    wire [10:0] a0x3_a1x4 = {2'b0, alpha0} * 4'd3 + {2'b0, alpha1} * 4'd4  + 11'd3;
    wire [10:0] a0x2_a1x5 = {2'b0, alpha0} * 4'd2 + {2'b0, alpha1} * 4'd5  + 11'd3;
    wire [10:0] a0x1_a1x6 = {3'b0, alpha0}         + {2'b0, alpha1} * 4'd6  + 11'd3;

    wire [10:0] a0x4_a1x1_r2 = {2'b0, alpha0} * 4'd4 + {3'b0, alpha1}         + 11'd2;
    wire [10:0] a0x3_a1x2_r2 = {2'b0, alpha0} * 4'd3 + {2'b0, alpha1} * 4'd2  + 11'd2;
    wire [10:0] a0x2_a1x3_r2 = {2'b0, alpha0} * 4'd2 + {2'b0, alpha1} * 4'd3  + 11'd2;
    wire [10:0] a0x1_a1x4_r2 = {3'b0, alpha0}         + {2'b0, alpha1} * 4'd4  + 11'd2;

    // verilator lint_off UNUSEDSIGNAL
    wire [22:0] ap_7_2 = {12'b0, a0x6_a1x1} * 23'd2341;
    wire [22:0] ap_7_3 = {12'b0, a0x5_a1x2} * 23'd2341;
    wire [22:0] ap_7_4 = {12'b0, a0x4_a1x3} * 23'd2341;
    wire [22:0] ap_7_5 = {12'b0, a0x3_a1x4} * 23'd2341;
    wire [22:0] ap_7_6 = {12'b0, a0x2_a1x5} * 23'd2341;
    wire [22:0] ap_7_7 = {12'b0, a0x1_a1x6} * 23'd2341;

    wire [22:0] ap_5_2 = {12'b0, a0x4_a1x1_r2} * 23'd3277;
    wire [22:0] ap_5_3 = {12'b0, a0x3_a1x2_r2} * 23'd3277;
    wire [22:0] ap_5_4 = {12'b0, a0x2_a1x3_r2} * 23'd3277;
    wire [22:0] ap_5_5 = {12'b0, a0x1_a1x4_r2} * 23'd3277;
    // verilator lint_on UNUSEDSIGNAL

    // Generate 8-entry alpha palette
    reg [7:0] alpha_palette [0:7];

    always_comb begin
        alpha_palette[0] = alpha0;
        alpha_palette[1] = alpha1;

        if (alpha0 > alpha1) begin
            // 8-entry interpolated mode
            alpha_palette[2] = ap_7_2[21:14];
            alpha_palette[3] = ap_7_3[21:14];
            alpha_palette[4] = ap_7_4[21:14];
            alpha_palette[5] = ap_7_5[21:14];
            alpha_palette[6] = ap_7_6[21:14];
            alpha_palette[7] = ap_7_7[21:14];
        end else begin
            // 6-entry interpolated + 0 and 255
            alpha_palette[2] = ap_5_2[21:14];
            alpha_palette[3] = ap_5_3[21:14];
            alpha_palette[4] = ap_5_4[21:14];
            alpha_palette[5] = ap_5_5[21:14];
            alpha_palette[6] = 8'd0;
            alpha_palette[7] = 8'd255;
        end
    end

    wire [7:0] decoded_alpha = alpha_palette[alpha_index];

    // Expand A8 to UQ1.8: {1'b0, A8} + A8[7] → 0..256 (0x100 = 1.0)
    wire [8:0] alpha9 = {1'b0, decoded_alpha} + {8'b0, decoded_alpha[7]};

    // ========================================================================
    // BC1 Color Block Decode (bytes 8-15)
    // ========================================================================

    wire [15:0] color0 = block_data[79:64];
    wire [15:0] color1 = block_data[95:80];
    wire [31:0] indices = block_data[127:96];

    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

    wire [4:0] c0_r = color0[15:11];
    wire [4:0] c1_r = color1[15:11];
    wire [5:0] c0_g = color0[10:5];
    wire [5:0] c1_g = color1[10:5];
    wire [4:0] c0_b = color0[4:0];
    wire [4:0] c1_b = color1[4:0];

    // ========================================================================
    // UQ1.8 Color Interpolation (9-bit endpoints)
    // ========================================================================

    wire [8:0] c0_r9 = {1'b0, c0_r, c0_r[4:2]} + {8'b0, c0_r[4]};
    wire [8:0] c1_r9 = {1'b0, c1_r, c1_r[4:2]} + {8'b0, c1_r[4]};
    wire [8:0] c0_g9 = {1'b0, c0_g, c0_g[5:4]} + {8'b0, c0_g[5]};
    wire [8:0] c1_g9 = {1'b0, c1_g, c1_g[5:4]} + {8'b0, c1_g[5]};
    wire [8:0] c0_b9 = {1'b0, c0_b, c0_b[4:2]} + {8'b0, c0_b[4]};
    wire [8:0] c1_b9 = {1'b0, c1_b, c1_b[4:2]} + {8'b0, c1_b[4]};

    wire [10:0] s21_r9 = {2'b0, c0_r9} + {2'b0, c0_r9} + {2'b0, c1_r9} + 11'd1;
    wire [10:0] s21_g9 = {2'b0, c0_g9} + {2'b0, c0_g9} + {2'b0, c1_g9} + 11'd1;
    wire [10:0] s21_b9 = {2'b0, c0_b9} + {2'b0, c0_b9} + {2'b0, c1_b9} + 11'd1;

    // verilator lint_off UNUSEDSIGNAL
    wire [20:0] p21_r9 = {10'b0, s21_r9} * 21'd683;
    wire [20:0] p21_g9 = {10'b0, s21_g9} * 21'd683;
    wire [20:0] p21_b9 = {10'b0, s21_b9} * 21'd683;
    // verilator lint_on UNUSEDSIGNAL

    wire [8:0] i21_r9 = p21_r9[19:11];
    wire [8:0] i21_g9 = p21_g9[19:11];
    wire [8:0] i21_b9 = p21_b9[19:11];

    wire [10:0] s12_r9 = {2'b0, c0_r9} + {2'b0, c1_r9} + {2'b0, c1_r9} + 11'd1;
    wire [10:0] s12_g9 = {2'b0, c0_g9} + {2'b0, c1_g9} + {2'b0, c1_g9} + 11'd1;
    wire [10:0] s12_b9 = {2'b0, c0_b9} + {2'b0, c1_b9} + {2'b0, c1_b9} + 11'd1;

    // verilator lint_off UNUSEDSIGNAL
    wire [20:0] p12_r9 = {10'b0, s12_r9} * 21'd683;
    wire [20:0] p12_g9 = {10'b0, s12_g9} * 21'd683;
    wire [20:0] p12_b9 = {10'b0, s12_b9} * 21'd683;
    // verilator lint_on UNUSEDSIGNAL

    wire [8:0] i12_r9 = p12_r9[19:11];
    wire [8:0] i12_g9 = p12_g9[19:11];
    wire [8:0] i12_b9 = p12_b9[19:11];

    // ========================================================================
    // Color Palette Generation (4-color opaque mode, forced for BC3)
    // ========================================================================

    reg [35:0] palette [0:3];

    always_comb begin
        // UQ1.8 {R9, G9, B9, A9}
        palette[0] = {c0_r9, c0_g9, c0_b9, alpha9};
        palette[1] = {c1_r9, c1_g9, c1_b9, alpha9};
        palette[2] = {i21_r9, i21_g9, i21_b9, alpha9};
        palette[3] = {i12_r9, i12_g9, i12_b9, alpha9};
    end

    // ========================================================================
    // Output Assembly
    // ========================================================================

    assign texel_out = palette[color_index];

endmodule

`default_nettype wire
