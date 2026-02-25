`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `9922acb997237266` 2026-02-25
//
// BC2 Texture Decoder — FORMAT=1
//
// Decodes a 128-bit BC2 compressed block to produce one RGBA5652 texel.
// BC2 block structure (16 bytes):
//   Bytes 0-7:  Explicit 4-bit alpha per texel (4 u16 rows, 4 texels each)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// The color block is always decoded in 4-color opaque mode (color0 > color1
// comparison is forced true for BC2 color decode).
//
// Alpha decode: each u16 row holds 4 texels at 4 bits each.
//   Row bits [3:0] = alpha col 0, [7:4] = col 1, [11:8] = col 2, [15:12] = col 3.
//   A4 is truncated to A2: A4[3:2] per INT-032 spec.
//
// See: INT-014 (Texture Memory Layout, Format 1), INT-032 (Texture Cache, BC2),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (FR-024-2), REQ-003.03

module texture_bc2 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [63:0]   = alpha data (4 x u16 rows of 4-bit alpha values)
    //   [127:64]  = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Alpha Data Extraction (bytes 0-7)
    // ========================================================================
    // Alpha is stored as 4 bits per texel in 4 u16 rows (each row = 4 texels).
    // Row 0 = bits [15:0], Row 1 = bits [31:16], etc.
    // Within a row: bits [3:0]=col0, [7:4]=col1, [11:8]=col2, [15:12]=col3.

    wire [1:0] texel_x = texel_idx[1:0];
    wire [1:0] texel_y = texel_idx[3:2];

    // Bit offset into the 64-bit alpha field: row * 16 + col * 4
    wire [6:0] alpha_bit_offset = {1'b0, texel_y, texel_x, 2'b00};
    wire [3:0] alpha4 = block_data[alpha_bit_offset +: 4];

    // Low 2 bits of A4 are discarded during truncation to A2
    wire [1:0] _unused_alpha_low = alpha4[1:0];

    // Truncate A4 to A2: take top 2 bits (INT-032)
    wire [1:0] alpha2 = alpha4[3:2];

    // ========================================================================
    // BC1 Color Block Decode (bytes 8-15)
    // ========================================================================
    // Color block is at block_data[127:64].
    // BC1 layout: color0 [79:64], color1 [95:80], indices [127:96]

    wire [15:0] color0 = block_data[79:64];
    wire [15:0] color1 = block_data[95:80];
    wire [31:0] indices = block_data[127:96];

    // Extract 2-bit index for the selected texel
    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

    // ========================================================================
    // Color Palette Generation (4-color opaque mode, forced for BC2)
    // ========================================================================
    // BC2 always uses 4-color opaque mode regardless of color0/color1 ordering.

    // BC1 color interpolation: (2*c0 + c1 + 1) / 3 per channel
    function automatic [15:0] interp_2_1(input [15:0] c0, input [15:0] c1);
        begin
            interp_2_1 = {
                5'(({2'b0, c0[15:11]} + {2'b0, c0[15:11]} + {2'b0, c1[15:11]} + 7'd1) / 7'd3),
                6'(({2'b0, c0[10:5]}  + {2'b0, c0[10:5]}  + {2'b0, c1[10:5]}  + 8'd1) / 8'd3),
                5'(({2'b0, c0[4:0]}   + {2'b0, c0[4:0]}   + {2'b0, c1[4:0]}   + 7'd1) / 7'd3)
            };
        end
    endfunction

    // Generate all 4 palette entries
    reg [15:0] palette [0:3];

    always_comb begin
        palette[0] = color0;
        palette[1] = color1;
        palette[2] = interp_2_1(color0, color1);
        palette[3] = interp_2_1(color1, color0);
    end

    // ========================================================================
    // Output Assembly
    // ========================================================================
    // Combine color from palette with explicit alpha.

    wire [15:0] selected_color = palette[color_index];

    assign rgba5652 = {selected_color, alpha2};

endmodule

`default_nettype wire
