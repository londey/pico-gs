`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// R8 Texture Decoder — FORMAT=6
//
// Converts a 4x4 block of uncompressed R8 (single-channel) texels to
// UQ1.8 RGBA format.
// Each texel is an 8-bit unsigned value (UNORM8).
// The R channel is replicated to G and B; alpha is set to opaque.
//
// R9=G9=B9={R8, R8[7]}, A9=9'h1FF (opaque) (DD-038).
//
// The block_data input holds 16 texels x 8 bits = 128 bits.
// Texels are stored in row-major order within the 4x4 block.
//
// See: INT-014 (Texture Memory Layout, Format 6), INT-032 (Texture Cache, R8),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-7), DD-038

module texture_r8 (
    // Block data: 16 texels x 8 bits = 128 bits (row-major within 4x4 block)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {A9, B9, G9, R9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 8-bit R value from the block.

    wire [6:0] bit_offset = {texel_idx, 3'b000};  // texel_idx * 8
    wire [7:0] r8 = block_data[bit_offset +: 8];

    // ========================================================================
    // UQ1.8 Expansion (36-bit)
    // ========================================================================
    // R8 expanded to 9-bit UQ1.8: {R8[7:0], R8[7]}
    // Replicated to all three color channels; alpha = opaque (9'h1FF).
    // R8=0xFF -> 9'h1FF, R8=0x00 -> 9'h000

    wire [8:0] ch9 = {r8, r8[7]};
    wire [8:0] a9  = 9'h1FF;

    assign texel_out = {a9, ch9, ch9, ch9};

endmodule

`default_nettype wire
