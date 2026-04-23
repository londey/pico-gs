`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC4 Texture Decoder — FORMAT=3
//
// Decodes a 64-bit BC4 compressed block to produce one texel in UQ1.8 format.
//
// BC4 stores a single channel (red) using the BC3 alpha block encoding:
//   Bytes 0-1: red0 (u8), red1 (u8)
//   Bytes 2-7: 6-byte 3-bit index table (16 texels)
//
// Output: R8→UQ1.8 replicated to G and B; A=opaque (A9=9'h100).
//
// See: INT-014 (Texture Memory Layout, Format 3), UNIT-011.04 (Block Decompressor, BC4),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc4 (
    // Block data: 64 bits (8 bytes, little-endian)
    //   [7:0]   = red0 (u8)
    //   [15:8]  = red1 (u8)
    //   [63:16] = 48-bit red index table (3 bits per texel)
    input  wire [63:0]  block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Red Block Decode (same encoding as BC3 alpha block)
    // ========================================================================

    wire [7:0] decoded_red;

    bc_alpha_block u_red (
        .endpoint0     (block_data[7:0]),
        .endpoint1     (block_data[15:8]),
        .index_data    (block_data[63:16]),
        .texel_idx     (texel_idx),
        .decoded_value (decoded_red)
    );

    // ========================================================================
    // Output Assembly: UQ1.8 channel replication
    // ========================================================================

    wire [8:0] red9 = fp_types_pkg::ch8_to_uq18(decoded_red);

    assign texel_out = {red9, red9, red9, 9'h100};

endmodule

`default_nettype wire
