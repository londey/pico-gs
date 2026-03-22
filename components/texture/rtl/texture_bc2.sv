`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// BC2 Texture Decoder — FORMAT=1
//
// Decodes a 128-bit BC2 compressed block to produce one texel in UQ1.8 format.
//
// BC2 block structure (16 bytes):
//   Bytes 0-7:  Explicit 4-bit alpha per texel (4 u16 rows, 4 texels each)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// The color block is always decoded in 4-color opaque mode (color0 > color1
// comparison is forced true for BC2 color decode).
//
// Alpha decode: each u16 row holds 4 texels at 4 bits each.
//   Row bits [3:0] = alpha col 0, [7:4] = col 1, [11:8] = col 2, [15:12] = col 3.
//   A4 expanded to UQ1.8 via bit-replication + correction.
//
// Color interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   1/3: (2*C0 + C1 + 1) * 683 >> 11
//
// See: INT-014 (Texture Memory Layout, Format 1), INT-032 (Texture Cache, BC2),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc2 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [63:0]   = alpha data (4 x u16 rows of 4-bit alpha values)
    //   [127:64]  = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Alpha Data Extraction (bytes 0-7)
    // ========================================================================

    wire [1:0] texel_x = texel_idx[1:0];
    wire [1:0] texel_y = texel_idx[3:2];

    // Bit offset into the 64-bit alpha field: row * 16 + col * 4
    wire [6:0] alpha_bit_offset = {1'b0, texel_y, texel_x, 2'b00};
    wire [3:0] alpha4 = block_data[alpha_bit_offset +: 4];

    // Expand A4 to UQ1.8 via bit-replication + correction
    // {1'b0, a4, a4} + a4[3] → 0..256 (0x100 = 1.0 for a4=15)
    wire [8:0] alpha9 = {1'b0, alpha4, alpha4} + {8'b0, alpha4[3]};

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

    // interp_2_1 UQ1.8: (2*C0 + C1 + 1) / 3 via (x * 683) >> 11
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

    // interp_1_2 UQ1.8: (C0 + 2*C1 + 1) / 3
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
    // Color Palette Generation (4-color opaque mode, forced for BC2)
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
