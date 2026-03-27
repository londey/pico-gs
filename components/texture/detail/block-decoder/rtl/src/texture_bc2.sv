`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC2 Texture Decoder — FORMAT=1
//
// Decodes a 128-bit BC2 compressed block to produce one texel in UQ1.8 format.
//
// BC2 block structure (16 bytes):
//   Bytes 0-7:  Explicit 4-bit alpha per texel (4 u16 rows, 4 texels each)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// The color block is always decoded in 4-color opaque mode (forced).
//
// Alpha decode: each u16 row holds 4 texels at 4 bits each.
//   Row bits [3:0] = alpha col 0, [7:4] = col 1, [11:8] = col 2, [15:12] = col 3.
//   A4 expanded to UQ1.8 via ch4_to_uq18().
//
// See: INT-014 (Texture Memory Layout, Format 1), INT-032 (Texture Cache, BC2),
//      UNIT-006 (Pixel Pipeline), REQ-003.06, REQ-003.03, DD-038, DD-039

module texture_bc2 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [63:0]   = alpha data (4 x u16 rows of 4-bit alpha values)
    //   [127:64]  = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Alpha Data Extraction (bytes 0-7)
    // ========================================================================

    wire [1:0] texel_x = texel_idx[1:0];
    wire [1:0] texel_y = texel_idx[3:2];

    // Bit offset into the 64-bit alpha field: row * 16 + col * 4
    wire [6:0] alpha_bit_offset = {1'b0, texel_y, texel_x, 2'b00};
    wire [3:0] alpha4 = block_data[alpha_bit_offset +: 4];

    wire [8:0] alpha9 = fp_types_pkg::ch4_to_uq18(alpha4);

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
