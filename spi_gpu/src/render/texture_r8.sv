`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `f7ece909bb04a361` 2026-02-28
//
// R8 Texture Decoder — FORMAT=6
//
// Converts a 4x4 block of uncompressed R8 (single-channel) texels to RGBA5652.
// Each texel is an 8-bit unsigned value (UNORM8).
// The R channel is replicated to G and B; alpha is set to opaque (A2=11).
//
// INT-032 specifies: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
//
// The block_data input holds 16 texels x 8 bits = 128 bits.
// Texels are stored in row-major order within the 4x4 block.
//
// See: INT-014 (Texture Memory Layout, Format 6), INT-032 (Texture Cache, R8),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (Texture Sampling FR-024-7)

module texture_r8 (
    // Block data: 16 texels x 8 bits = 128 bits (row-major within 4x4 block)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 8-bit R value from the block.

    wire [6:0] bit_offset = {texel_idx, 3'b000};  // texel_idx * 8
    wire [7:0] r8 = block_data[bit_offset +: 8];

    // Low 2 bits of R8 are discarded during truncation to R5/B5
    wire [1:0] _unused_r8_low = r8[1:0];

    // ========================================================================
    // Channel Replication to RGBA5652
    // ========================================================================
    // INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
    // Replicates the red channel to green and blue for grayscale output.

    assign rgba5652 = {r8[7:3], r8[7:2], r8[7:3], 2'b11};

endmodule

`default_nettype wire
