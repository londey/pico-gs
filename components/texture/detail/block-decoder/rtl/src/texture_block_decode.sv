`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// Texture Block Decode — Top-Level Format Dispatcher (4-wide)
//
// Accepts raw block data from the L2 compressed cache (up to 32 u16 words)
// and dispatches to the appropriate format-specific decoder based on
// tex_format[3:0].
// Decodes 4 texels per evaluation to match the L1 cache's 4-bank
// write bandwidth.
// Each output is 36 bits in UQ1.8 format ({R9, G9, B9, A9}).
//
// Format codes (from gpu_regs_pkg::tex_format_e):
//   0 = BC1       (4 words,  64 bits)
//   1 = BC2       (8 words, 128 bits)
//   2 = BC3       (8 words, 128 bits)
//   3 = BC4       (4 words,  64 bits)
//   4 = reserved
//   5 = RGB565   (16 words, 256 bits)
//   6 = RGBA8888 (32 words, 512 bits)
//   7 = R8        (8 words, 128 bits)
//
// See: INT-014 (Texture Memory Layout), INT-032 (Texture Cache Architecture),
//      UNIT-011.04 (Block Decompressor), REQ-003.03, REQ-003.06

module texture_block_decode (
    // Raw block data from L2 cache (up to 32 u16 words)
    input  wire [15:0] block_word_0,
    input  wire [15:0] block_word_1,
    input  wire [15:0] block_word_2,
    input  wire [15:0] block_word_3,
    input  wire [15:0] block_word_4,
    input  wire [15:0] block_word_5,
    input  wire [15:0] block_word_6,
    input  wire [15:0] block_word_7,
    input  wire [15:0] block_word_8,
    input  wire [15:0] block_word_9,
    input  wire [15:0] block_word_10,
    input  wire [15:0] block_word_11,
    input  wire [15:0] block_word_12,
    input  wire [15:0] block_word_13,
    input  wire [15:0] block_word_14,
    input  wire [15:0] block_word_15,
    input  wire [15:0] block_word_16,
    input  wire [15:0] block_word_17,
    input  wire [15:0] block_word_18,
    input  wire [15:0] block_word_19,
    input  wire [15:0] block_word_20,
    input  wire [15:0] block_word_21,
    input  wire [15:0] block_word_22,
    input  wire [15:0] block_word_23,
    input  wire [15:0] block_word_24,
    input  wire [15:0] block_word_25,
    input  wire [15:0] block_word_26,
    input  wire [15:0] block_word_27,
    input  wire [15:0] block_word_28,
    input  wire [15:0] block_word_29,
    input  wire [15:0] block_word_30,
    input  wire [15:0] block_word_31,

    // 4 texel selections within 4x4 block (0..15 each)
    input  wire [3:0]  texel_idx_0,
    input  wire [3:0]  texel_idx_1,
    input  wire [3:0]  texel_idx_2,
    input  wire [3:0]  texel_idx_3,

    // Texture format (TEXn_CFG.FORMAT[3:0])
    input  wire [3:0]  tex_format,

    // 4 decoded texels: 36 bits each = {R9, G9, B9, A9} in UQ1.8 per channel
    output reg  [35:0] texel_out_0,
    output reg  [35:0] texel_out_1,
    output reg  [35:0] texel_out_2,
    output reg  [35:0] texel_out_3
);

    // ========================================================================
    // Block Data Assembly
    // ========================================================================
    // Concatenate individual words into the widths each decoder expects.
    // Words are in little-endian order: word 0 is bits [15:0].

    // 64-bit block (BC1, BC4: 4 words)
    wire [63:0] block_64 = {block_word_3, block_word_2,
                             block_word_1, block_word_0};

    // 128-bit block (BC2, BC3, R8: 8 words)
    wire [127:0] block_128 = {block_word_7, block_word_6,
                               block_word_5, block_word_4,
                               block_word_3, block_word_2,
                               block_word_1, block_word_0};

    // 256-bit block (RGB565: 16 words)
    wire [255:0] block_256 = {block_word_15, block_word_14,
                               block_word_13, block_word_12,
                               block_word_11, block_word_10,
                               block_word_9,  block_word_8,
                               block_word_7,  block_word_6,
                               block_word_5,  block_word_4,
                               block_word_3,  block_word_2,
                               block_word_1,  block_word_0};

    // 512-bit block (RGBA8888: 32 words)
    wire [511:0] block_512 = {block_word_31, block_word_30,
                               block_word_29, block_word_28,
                               block_word_27, block_word_26,
                               block_word_25, block_word_24,
                               block_word_23, block_word_22,
                               block_word_21, block_word_20,
                               block_word_19, block_word_18,
                               block_word_17, block_word_16,
                               block_word_15, block_word_14,
                               block_word_13, block_word_12,
                               block_word_11, block_word_10,
                               block_word_9,  block_word_8,
                               block_word_7,  block_word_6,
                               block_word_5,  block_word_4,
                               block_word_3,  block_word_2,
                               block_word_1,  block_word_0};

    // ========================================================================
    // Texel Index Array (for generate loop)
    // ========================================================================

    wire [3:0] tidx [0:3];
    assign tidx[0] = texel_idx_0;
    assign tidx[1] = texel_idx_1;
    assign tidx[2] = texel_idx_2;
    assign tidx[3] = texel_idx_3;

    // ========================================================================
    // Format-Specific Decoders (4 instances each)
    // ========================================================================
    // Block data is shared; only texel_idx differs per lane.
    // Synthesis shares the common palette/interpolation logic.

    wire [35:0] bc1_texel [0:3];
    wire [35:0] bc2_texel [0:3];
    wire [35:0] bc3_texel [0:3];
    wire [35:0] bc4_texel [0:3];
    wire [35:0] rgb565_texel [0:3];
    wire [35:0] rgba8888_texel [0:3];
    wire [35:0] r8_texel [0:3];

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_decode
            texture_bc1 u_bc1 (
                .bc1_data  (block_64),
                .texel_idx (tidx[gi]),
                .texel_out (bc1_texel[gi])
            );

            texture_bc2 u_bc2 (
                .block_data (block_128),
                .texel_idx  (tidx[gi]),
                .texel_out  (bc2_texel[gi])
            );

            texture_bc3 u_bc3 (
                .block_data (block_128),
                .texel_idx  (tidx[gi]),
                .texel_out  (bc3_texel[gi])
            );

            texture_bc4 u_bc4 (
                .block_data (block_64),
                .texel_idx  (tidx[gi]),
                .texel_out  (bc4_texel[gi])
            );

            texture_rgb565 u_rgb565 (
                .block_data (block_256),
                .texel_idx  (tidx[gi]),
                .texel_out  (rgb565_texel[gi])
            );

            texture_rgba8888 u_rgba8888 (
                .block_data (block_512),
                .texel_idx  (tidx[gi]),
                .texel_out  (rgba8888_texel[gi])
            );

            texture_r8 u_r8 (
                .block_data (block_128),
                .texel_idx  (tidx[gi]),
                .texel_out  (r8_texel[gi])
            );
        end
    endgenerate

    // ========================================================================
    // Format Selection Mux (4 lanes)
    // ========================================================================

    always_comb begin
        case (tex_format)
            4'd0: begin
                texel_out_0 = bc1_texel[0];
                texel_out_1 = bc1_texel[1];
                texel_out_2 = bc1_texel[2];
                texel_out_3 = bc1_texel[3];
            end
            4'd1: begin
                texel_out_0 = bc2_texel[0];
                texel_out_1 = bc2_texel[1];
                texel_out_2 = bc2_texel[2];
                texel_out_3 = bc2_texel[3];
            end
            4'd2: begin
                texel_out_0 = bc3_texel[0];
                texel_out_1 = bc3_texel[1];
                texel_out_2 = bc3_texel[2];
                texel_out_3 = bc3_texel[3];
            end
            4'd3: begin
                texel_out_0 = bc4_texel[0];
                texel_out_1 = bc4_texel[1];
                texel_out_2 = bc4_texel[2];
                texel_out_3 = bc4_texel[3];
            end
            4'd5: begin
                texel_out_0 = rgb565_texel[0];
                texel_out_1 = rgb565_texel[1];
                texel_out_2 = rgb565_texel[2];
                texel_out_3 = rgb565_texel[3];
            end
            4'd6: begin
                texel_out_0 = rgba8888_texel[0];
                texel_out_1 = rgba8888_texel[1];
                texel_out_2 = rgba8888_texel[2];
                texel_out_3 = rgba8888_texel[3];
            end
            4'd7: begin
                texel_out_0 = r8_texel[0];
                texel_out_1 = r8_texel[1];
                texel_out_2 = r8_texel[2];
                texel_out_3 = r8_texel[3];
            end
            default: begin
                texel_out_0 = 36'd0;
                texel_out_1 = 36'd0;
                texel_out_2 = 36'd0;
                texel_out_3 = 36'd0;
            end
        endcase
    end

endmodule

`default_nettype wire
