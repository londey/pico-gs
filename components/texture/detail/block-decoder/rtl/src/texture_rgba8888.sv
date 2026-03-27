`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// RGBA8888 Texture Decoder — FORMAT=5
//
// Converts a 4x4 block of uncompressed RGBA8888 texels to UQ1.8 RGBA format.
// Each texel is a 32-bit value: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A.
//
// Each 8-bit channel is expanded to UQ1.8 via ch8_to_uq18():
//   {1'b0, ch8} + {8'b0, ch8[7]}  =>  255 -> 0x100 (exactly 1.0)
//
// The block_data input holds 16 texels x 32 bits = 512 bits.
// Texels are stored in row-major order within the 4x4 block.
//
// See: INT-014 (Texture Memory Layout, Format 5), INT-032 (Texture Cache, RGBA8888),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-6), DD-038

module texture_rgba8888 (
    // Block data: 16 texels x 32 bits = 512 bits (row-major within 4x4 block)
    input  wire [511:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 32-bit RGBA8888 pixel from the block.
    // INT-014 layout: [7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8

    wire [8:0] bit_offset = {texel_idx, 5'b00000};  // texel_idx * 32
    wire [31:0] pixel = block_data[bit_offset +: 32];

    // ========================================================================
    // UQ1.8 Expansion
    // ========================================================================

    wire [8:0] r9 = fp_types_pkg::ch8_to_uq18(pixel[7:0]);
    wire [8:0] g9 = fp_types_pkg::ch8_to_uq18(pixel[15:8]);
    wire [8:0] b9 = fp_types_pkg::ch8_to_uq18(pixel[23:16]);
    wire [8:0] a9 = fp_types_pkg::ch8_to_uq18(pixel[31:24]);

    assign texel_out = {r9, g9, b9, a9};

endmodule

`default_nettype wire
