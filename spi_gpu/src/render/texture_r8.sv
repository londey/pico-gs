`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// R8 Texture Decoder — FORMAT=6
//
// Converts a 4x4 block of uncompressed R8 (single-channel) texels to RGBA5652
// (CACHE_MODE=0) or UQ1.8 RGBA (CACHE_MODE=1) format.
// Each texel is an 8-bit unsigned value (UNORM8).
// The R channel is replicated to G and B; alpha is set to opaque.
//
// CACHE_MODE=0: INT-032 specifies: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
// CACHE_MODE=1: R9=G9=B9={R8, R8[7]}, A9=9'h1FF (opaque) (DD-038).
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

    // Cache mode: 0 = RGBA5652 (18-bit), 1 = UQ1.8 RGBA (36-bit)
    input  wire         cache_mode,

    // Decoded output: 36 bits wide.
    // CACHE_MODE=0: [17:0] = RGBA5652 {R5, G6, B5, A2}, [35:18] = 0.
    // CACHE_MODE=1: [35:0] = {A9, B9, G9, R9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Texel Extraction
    // ========================================================================
    // Extract the selected 8-bit R value from the block.

    wire [6:0] bit_offset = {texel_idx, 3'b000};  // texel_idx * 8
    wire [7:0] r8 = block_data[bit_offset +: 8];

    // ========================================================================
    // CACHE_MODE=0: Channel Replication to RGBA5652 (18-bit)
    // ========================================================================
    // INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
    // Replicates the red channel to green and blue for grayscale output.

    wire [17:0] mode0_out = {r8[7:3], r8[7:2], r8[7:3], 2'b11};

    // ========================================================================
    // CACHE_MODE=1: UQ1.8 Expansion (36-bit)
    // ========================================================================
    // R8 expanded to 9-bit UQ1.8: {R8[7:0], R8[7]}
    // Replicated to all three color channels; alpha = opaque (9'h1FF).
    // R8=0xFF -> 9'h1FF, R8=0x00 -> 9'h000

    wire [8:0] ch9 = {r8, r8[7]};
    wire [8:0] a9  = 9'h1FF;

    wire [35:0] mode1_out = {a9, ch9, ch9, ch9};

    // ========================================================================
    // Output Mux
    // ========================================================================

    assign texel_out = cache_mode ? mode1_out : {18'b0, mode0_out};

endmodule

`default_nettype wire
