`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
//
// RGBA8888 Texture Decoder — FORMAT=5
//
// Converts a 4x4 block of uncompressed RGBA8888 texels to RGBA5652 (CACHE_MODE=0)
// or UQ1.8 RGBA (CACHE_MODE=1) format.
// Each texel is a 32-bit value: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A.
//
// CACHE_MODE=0: Truncation to RGBA5652: R8->R5, G8->G6, B8->B5, A8->A2.
// CACHE_MODE=1: Expansion to UQ1.8: {ch8[7:0], ch8[7]} per channel (DD-038).
//   R9={R8, R8[7]}, G9={G8, G8[7]}, B9={B8, B8[7]}, A9={A8, A8[7]}.
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
    // Extract the selected 32-bit RGBA8888 pixel from the block.
    // INT-014 layout: [7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8

    wire [8:0] bit_offset = {texel_idx, 5'b00000};  // texel_idx * 32
    wire [31:0] pixel = block_data[bit_offset +: 32];

    // ========================================================================
    // Channel Extraction
    // ========================================================================

    wire [7:0] r8 = pixel[7:0];
    wire [7:0] g8 = pixel[15:8];
    wire [7:0] b8 = pixel[23:16];
    wire [7:0] a8 = pixel[31:24];

    // ========================================================================
    // CACHE_MODE=0: Truncation to RGBA5652 (18-bit)
    // ========================================================================
    // R8[7:3] -> R5, G8[7:2] -> G6, B8[7:3] -> B5, A8[7:6] -> A2

    wire [17:0] mode0_out = {r8[7:3], g8[7:2], b8[7:3], a8[7:6]};

    // ========================================================================
    // CACHE_MODE=1: UQ1.8 Expansion (36-bit)
    // ========================================================================
    // Each 8-bit channel expanded to 9-bit UQ1.8: {ch8[7:0], ch8[7]}
    // ch8=0xFF -> 9'h1FF (max UQ1.8, slightly below 1.0)
    // ch8=0x00 -> 9'h000

    wire [8:0] r9 = {r8, r8[7]};
    wire [8:0] g9 = {g8, g8[7]};
    wire [8:0] b9 = {b8, b8[7]};
    wire [8:0] a9 = {a8, a8[7]};

    wire [35:0] mode1_out = {a9, b9, g9, r9};

    // ========================================================================
    // Output Mux
    // ========================================================================

    assign texel_out = cache_mode ? mode1_out : {18'b0, mode0_out};

endmodule

`default_nettype wire
