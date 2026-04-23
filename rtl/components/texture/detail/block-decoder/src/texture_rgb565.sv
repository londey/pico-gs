`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// RGB565 Texture Decoder — FORMAT=4
//
// Converts a 4x4 block of uncompressed RGB565 texels to UQ1.8 RGBA format.
// Each texel is a 16-bit RGB565 value; alpha is set to opaque (0x100).
//
// The block_data input holds 16 texels x 16 bits = 256 bits (low 256 bits used).
// Texels are stored in row-major order within the 4x4 block.
//
// Output [35:0] = {R9, G9, B9, A9} in UQ1.8 per channel (DD-038).
//   R5→R9 and B5→B9 via ch5_to_uq18()
//   G6→G9 via ch6_to_uq18()
//   A9 = 9'h100 (opaque, 1.0 in UQ1.8)
//
// See: INT-014 (Texture Memory Layout, Format 4), UNIT-011.04 (Block Decompressor, RGB565),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-5), DD-038

module texture_rgb565 (
    // Block data: 16 texels x 16 bits = 256 bits (row-major within 4x4 block)
    input  wire [255:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================

    wire [7:0] bit_offset = {texel_idx, 4'b0000};  // texel_idx * 16
    wire [15:0] pixel = block_data[bit_offset +: 16];

    // ========================================================================
    // UQ1.8 Expansion
    // ========================================================================

    wire [8:0] r9 = fp_types_pkg::ch5_to_uq18(pixel[15:11]);
    wire [8:0] g9 = fp_types_pkg::ch6_to_uq18(pixel[10:5]);
    wire [8:0] b9 = fp_types_pkg::ch5_to_uq18(pixel[4:0]);

    assign texel_out = {r9, g9, b9, 9'h100};

endmodule

`default_nettype wire
