`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `c5a833b7799789bf` 2026-02-28
//
// RGBA8888 Texture Decoder — FORMAT=5
//
// Converts a 4x4 block of uncompressed RGBA8888 texels to RGBA5652 format.
// Each texel is a 32-bit value: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A.
// Truncation: R8->R5, G8->G6, B8->B5, A8->A2.
//
// The block_data input holds 16 texels x 32 bits = 512 bits.
// Texels are stored in row-major order within the 4x4 block.
//
// See: INT-014 (Texture Memory Layout, Format 5), INT-032 (Texture Cache, RGBA8888),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-6)

module texture_rgba8888 (
    // Block data: 16 texels x 32 bits = 512 bits (row-major within 4x4 block)
    input  wire [511:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 32-bit RGBA8888 pixel from the block.
    // INT-014 layout: [7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8

    wire [8:0] bit_offset = {texel_idx, 5'b00000};  // texel_idx * 32
    wire [31:0] pixel = block_data[bit_offset +: 32];

    // Low bits discarded during truncation (R8[2:0], G8[1:0], B8[2:0], A8[5:0])
    wire [13:0] _unused_truncated = {pixel[29:24], pixel[18:16], pixel[9:8], pixel[2:0]};

    // ========================================================================
    // Truncation to RGBA5652
    // ========================================================================
    // INT-014 layout: [7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8
    // R8[7:3] -> R5, G8[7:2] -> G6, B8[7:3] -> B5, A8[7:6] -> A2

    assign rgba5652 = {pixel[7:3], pixel[15:10], pixel[23:19], pixel[31:30]};

endmodule

`default_nettype wire
