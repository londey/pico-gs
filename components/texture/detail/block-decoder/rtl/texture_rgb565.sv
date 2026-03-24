`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// RGB565 Texture Decoder — FORMAT=4
//
// Converts a 4x4 block of uncompressed RGB565 texels to UQ1.8 RGBA format.
// Each texel is a 16-bit RGB565 value; alpha is set to opaque.
//
// The block_data input holds 16 texels x 16 bits = 256 bits (low 256 bits used).
// Texels are stored in row-major order within the 4x4 block.
//
// Output [35:0] = {A9, B9, G9, R9} in UQ1.8 per channel (DD-038).
//   R5→R9 and B5→B9 via bit-replication with correction:
//     R9 = {R5[4:0], R5[4:2]} + {8'b0, R5[4]} (gs-twin exact formula)
//   G6→G9 via bit-replication with correction:
//     G9 = {G6[5:0], G6[5:4]} + {8'b0, G6[5]}
//   A9 = 9'h1FF (opaque, slightly below 1.0, matching gs-twin).
//
// See: INT-014 (Texture Memory Layout, Format 4), INT-032 (Texture Cache, RGB565),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-5), DD-038

module texture_rgb565 (
    // Block data: 16 texels x 16 bits = 256 bits (row-major within 4x4 block)
    input  wire [255:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {A9, B9, G9, R9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 16-bit RGB565 pixel from the block.

    wire [7:0] bit_offset = {texel_idx, 4'b0000};  // texel_idx * 16
    wire [15:0] pixel = block_data[bit_offset +: 16];

    // ========================================================================
    // Channel Extraction
    // ========================================================================
    // RGB565 layout: [15:11]=R5, [10:5]=G6, [4:0]=B5

    wire [4:0] r5 = pixel[15:11];
    wire [5:0] g6 = pixel[10:5];
    wire [4:0] b5 = pixel[4:0];

    // ========================================================================
    // UQ1.8 Expansion (36-bit)
    // ========================================================================
    // Bit-replication with correction term (matches gs-twin exactly):
    //   R9 = {R5[4:0], R5[4:2]} + {8'b0, R5[4]}
    //   G9 = {G6[5:0], G6[5:4]} + {8'b0, G6[5]}
    //   B9 = same as R9 (from B5)
    //   A9 = 9'h1FF (opaque)

    wire [8:0] r9 = {r5[4:0], r5[4:2]} + {8'b0, r5[4]};
    wire [8:0] g9 = {g6[5:0], g6[5:4]} + {8'b0, g6[5]};
    wire [8:0] b9 = {b5[4:0], b5[4:2]} + {8'b0, b5[4]};
    wire [8:0] a9 = 9'h1FF;

    assign texel_out = {a9, b9, g9, r9};

endmodule

`default_nettype wire
