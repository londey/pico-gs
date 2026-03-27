`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC3 Texture Decoder — FORMAT=2
//
// Decodes a 128-bit BC3 compressed block to produce one texel in UQ1.8 format.
//
// BC3 block structure (16 bytes):
//   Bytes 0-1:  alpha0 (u8), alpha1 (u8)
//   Bytes 2-7:  6-byte alpha index table (3 bits per texel, 16 texels = 48 bits)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// Alpha uses the shared bc_alpha_block (8-entry or 6-entry interpolation).
// Color uses the shared bc_color_block (forced 4-color opaque mode).
//
// See: INT-014 (Texture Memory Layout, Format 2), INT-032 (Texture Cache, BC3),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc3 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [7:0]    = alpha0 (u8)
    //   [15:8]   = alpha1 (u8)
    //   [63:16]  = 48-bit alpha index table (3 bits per texel)
    //   [127:64] = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Alpha Block Decode (bytes 0-7)
    // ========================================================================

    wire [7:0] decoded_alpha;

    bc_alpha_block u_alpha (
        .endpoint0     (block_data[7:0]),
        .endpoint1     (block_data[15:8]),
        .index_data    (block_data[63:16]),
        .texel_idx     (texel_idx),
        .decoded_value (decoded_alpha)
    );

    wire [8:0] alpha9 = fp_types_pkg::ch8_to_uq18(decoded_alpha);

    // ========================================================================
    // BC1 Color Block Decode (bytes 8-15, forced 4-color opaque)
    // ========================================================================

    wire [8:0] r9;
    wire [8:0] g9;
    wire [8:0] b9;

    // verilator lint_off PINCONNECTEMPTY
    bc_color_block u_color (
        .color0          (block_data[79:64]),
        .color1          (block_data[95:80]),
        .indices         (block_data[127:96]),
        .texel_idx       (texel_idx),
        .four_color_mode (1'b1),
        .r9              (r9),
        .g9              (g9),
        .b9              (b9),
        .transparent     ()
    );
    // verilator lint_on PINCONNECTEMPTY

    // ========================================================================
    // Output Assembly
    // ========================================================================

    assign texel_out = {r9, g9, b9, alpha9};

endmodule

`default_nettype wire
