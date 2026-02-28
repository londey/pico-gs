`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `e530bac5b9c72705` 2026-02-28
//
// RGB565 Texture Decoder — FORMAT=4
//
// Converts a 4x4 block of uncompressed RGB565 texels to RGBA5652 format.
// Each texel is a 16-bit RGB565 value; alpha is set to opaque (A2=11).
//
// The block_data input holds 16 texels x 16 bits = 256 bits (low 256 bits used).
// Texels are stored in row-major order within the 4x4 block.
//
// See: INT-014 (Texture Memory Layout, Format 4), INT-032 (Texture Cache, RGB565),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-5)

module texture_rgb565 (
    // Block data: 16 texels x 16 bits = 256 bits (row-major within 4x4 block)
    input  wire [255:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 16-bit RGB565 pixel from the block.

    wire [7:0] bit_offset = {texel_idx, 4'b0000};  // texel_idx * 16
    wire [15:0] pixel = block_data[bit_offset +: 16];

    // ========================================================================
    // RGBA5652 Assembly
    // ========================================================================
    // RGB565 layout: [15:11]=R5, [10:5]=G6, [4:0]=B5
    // RGBA5652 layout: {R5[17:13], G6[12:7], B5[6:2], A2[1:0]}
    // A2 = 2'b11 (opaque)

    assign rgba5652 = {pixel[15:11], pixel[10:5], pixel[4:0], 2'b11};

endmodule

`default_nettype wire
