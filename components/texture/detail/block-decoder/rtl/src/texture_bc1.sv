`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC1 (DXT1) Texture Decoder — FORMAT=0
//
// Decodes a 64-bit BC1 compressed block to produce one texel in UQ1.8 format.
//
// BC1 block structure (8 bytes):
//   Bytes 0-1: color0 (RGB565, little-endian)
//   Bytes 2-3: color1 (RGB565, little-endian)
//   Bytes 4-7: 32-bit index word (2 bits per texel, 16 texels)
//
// Two modes determined by color0 vs color1 comparison:
//   color0 >  color1: 4-color opaque mode
//     palette = [C0, C1, lerp(C0,C1,1/3), lerp(C0,C1,2/3)], all A=opaque
//   color0 <= color1: 3-color + transparent mode
//     palette = [C0, C1, lerp(C0,C1,1/2), transparent]
//
// See: INT-014 (Texture Memory Layout, Format 0), INT-032 (Texture Cache),
//      UNIT-006 (Pixel Pipeline), REQ-003.03, DD-038, DD-039

module texture_bc1 (
    // Block data: 64 bits (8 bytes, little-endian)
    //   [15:0]   = color0 (RGB565)
    //   [31:16]  = color1 (RGB565)
    //   [63:32]  = 32-bit index word (2 bits per texel, texel 0 = bits [1:0])
    input  wire [63:0]  bc1_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output: 36 bits = {R9, G9, B9, A9} in UQ1.8 per channel.
    output wire [35:0]  texel_out
);

    // ========================================================================
    // Endpoint Extraction
    // ========================================================================

    wire [15:0] color0 = bc1_data[15:0];
    wire [15:0] color1 = bc1_data[31:16];
    wire [31:0] indices = bc1_data[63:32];

    wire four_color_mode = (color0 > color1);

    // ========================================================================
    // Shared Color Block Decode
    // ========================================================================

    wire [8:0] r9;
    wire [8:0] g9;
    wire [8:0] b9;
    wire       transparent;

    bc_color_block u_color (
        .color0          (color0),
        .color1          (color1),
        .indices         (indices),
        .texel_idx       (texel_idx),
        .four_color_mode (four_color_mode),
        .r9              (r9),
        .g9              (g9),
        .b9              (b9),
        .transparent     (transparent)
    );

    // ========================================================================
    // Output Assembly
    // ========================================================================
    // A9 = opaque (0x100) unless transparent in 3-color mode

    wire [8:0] a9 = transparent ? 9'd0 : 9'h100;

    assign texel_out = {r9, g9, b9, a9};

endmodule

`default_nettype wire
