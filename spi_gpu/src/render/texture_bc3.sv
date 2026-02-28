`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `f7ece909bb04a361` 2026-02-28
//
// BC3 Texture Decoder — FORMAT=2
//
// Decodes a 128-bit BC3 compressed block to produce one RGBA5652 texel.
// BC3 block structure (16 bytes):
//   Bytes 0-1:  alpha0 (u8), alpha1 (u8)
//   Bytes 2-7:  6-byte alpha index table (3 bits per texel, 16 texels = 48 bits)
//   Bytes 8-15: BC1-style opaque color block (color0, color1, 32-bit indices)
//
// Alpha palette generation:
//   if alpha0 > alpha1: 8-entry interpolated palette
//   else: 6-entry interpolated + palette[6]=0, palette[7]=255
//
// Alpha is truncated to A2: A8[7:6] per INT-032.
// Color block always uses 4-color opaque mode (forced for BC3).
//
// See: INT-014 (Texture Memory Layout, Format 2), INT-032 (Texture Cache, BC3),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (FR-024-3), REQ-003.03

module texture_bc3 (
    // Block data: 128 bits (16 bytes, little-endian)
    //   [7:0]    = alpha0 (u8)
    //   [15:8]   = alpha1 (u8)
    //   [63:16]  = 48-bit alpha index table (3 bits per texel)
    //   [127:64] = BC1 color block (color0, color1, indices)
    input  wire [127:0] block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Alpha Block Decode (bytes 0-7)
    // ========================================================================

    wire [7:0] alpha0 = block_data[7:0];
    wire [7:0] alpha1 = block_data[15:8];

    // Extract 3-bit alpha index for the selected texel.
    // Alpha indices start at bit 16 (byte 2); each texel uses 3 bits.
    // bit_offset = 16 + texel_idx * 3
    wire [6:0] alpha_idx_bit_offset = 7'd16 + {3'b000, texel_idx} + {3'b000, texel_idx} + {3'b000, texel_idx};
    wire [2:0] alpha_index = block_data[alpha_idx_bit_offset +: 3];

    // Generate 8-entry alpha palette
    // Two modes based on alpha0 vs alpha1 comparison.
    reg [7:0] alpha_palette [0:7];

    always_comb begin
        alpha_palette[0] = alpha0;
        alpha_palette[1] = alpha1;

        if (alpha0 > alpha1) begin
            // 8-entry interpolated mode
            alpha_palette[2] = 8'((({2'b0, alpha0} * 10'd6) + ({2'b0, alpha1} * 10'd1) + 10'd3) / 10'd7);
            alpha_palette[3] = 8'((({2'b0, alpha0} * 10'd5) + ({2'b0, alpha1} * 10'd2) + 10'd3) / 10'd7);
            alpha_palette[4] = 8'((({2'b0, alpha0} * 10'd4) + ({2'b0, alpha1} * 10'd3) + 10'd3) / 10'd7);
            alpha_palette[5] = 8'((({2'b0, alpha0} * 10'd3) + ({2'b0, alpha1} * 10'd4) + 10'd3) / 10'd7);
            alpha_palette[6] = 8'((({2'b0, alpha0} * 10'd2) + ({2'b0, alpha1} * 10'd5) + 10'd3) / 10'd7);
            alpha_palette[7] = 8'((({2'b0, alpha0} * 10'd1) + ({2'b0, alpha1} * 10'd6) + 10'd3) / 10'd7);
        end else begin
            // 6-entry interpolated + 0 and 255
            alpha_palette[2] = 8'((({2'b0, alpha0} * 10'd4) + ({2'b0, alpha1} * 10'd1) + 10'd2) / 10'd5);
            alpha_palette[3] = 8'((({2'b0, alpha0} * 10'd3) + ({2'b0, alpha1} * 10'd2) + 10'd2) / 10'd5);
            alpha_palette[4] = 8'((({2'b0, alpha0} * 10'd2) + ({2'b0, alpha1} * 10'd3) + 10'd2) / 10'd5);
            alpha_palette[5] = 8'((({2'b0, alpha0} * 10'd1) + ({2'b0, alpha1} * 10'd4) + 10'd2) / 10'd5);
            alpha_palette[6] = 8'd0;
            alpha_palette[7] = 8'd255;
        end
    end

    wire [7:0] decoded_alpha = alpha_palette[alpha_index];

    // Low 6 bits of A8 are discarded during truncation to A2
    wire [5:0] _unused_alpha_low = decoded_alpha[5:0];

    // Truncate A8 to A2: take top 2 bits (INT-032)
    wire [1:0] alpha2 = decoded_alpha[7:6];

    // ========================================================================
    // BC1 Color Block Decode (bytes 8-15)
    // ========================================================================
    // Color block is at block_data[127:64].

    wire [15:0] color0 = block_data[79:64];
    wire [15:0] color1 = block_data[95:80];
    wire [31:0] indices = block_data[127:96];

    // Extract 2-bit color index for the selected texel
    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

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

    // Generate 4-color opaque palette (forced for BC3 color block)
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

    wire [15:0] selected_color = palette[color_index];

    assign rgba5652 = {selected_color, alpha2};

endmodule

`default_nettype wire
