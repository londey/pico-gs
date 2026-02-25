`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `ea25bc5506e6da48` 2026-02-24
//
// BC4 Texture Decoder — FORMAT=3
//
// Decodes a 64-bit BC4 compressed block to produce one RGBA5652 texel.
// BC4 stores a single channel (red) using the BC3 alpha block encoding:
//   Bytes 0-1: red0 (u8), red1 (u8)
//   Bytes 2-7: 6-byte 3-bit index table (16 texels)
//
// Output: R=decoded value, replicated to G and B; A=opaque (11).
// INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11
//
// See: INT-014 (Texture Memory Layout, Format 3), INT-032 (Texture Cache, BC4),
//      UNIT-006 (Pixel Pipeline), REQ-003.06 (FR-024-4), REQ-003.03

module texture_bc4 (
    // Block data: 64 bits (8 bytes, little-endian)
    //   [7:0]   = red0 (u8)
    //   [15:8]  = red1 (u8)
    //   [63:16] = 48-bit red index table (3 bits per texel)
    input  wire [63:0]  block_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Red Block Decode (same encoding as BC3 alpha block)
    // ========================================================================

    wire [7:0] red0 = block_data[7:0];
    wire [7:0] red1 = block_data[15:8];

    // Extract 3-bit index for the selected texel.
    // Indices start at bit 16; each texel uses 3 bits.
    // bit_offset = 16 + texel_idx * 3
    wire [5:0] idx_bit_offset = 6'd16 + {2'b00, texel_idx} + {2'b00, texel_idx} + {2'b00, texel_idx};
    wire [2:0] red_index = block_data[idx_bit_offset +: 3];

    // Generate 8-entry red palette (same algorithm as BC3 alpha)
    reg [7:0] red_palette [0:7];

    always_comb begin
        red_palette[0] = red0;
        red_palette[1] = red1;

        if (red0 > red1) begin
            // 8-entry interpolated mode
            red_palette[2] = 8'((({2'b0, red0} * 10'd6) + ({2'b0, red1} * 10'd1) + 10'd3) / 10'd7);
            red_palette[3] = 8'((({2'b0, red0} * 10'd5) + ({2'b0, red1} * 10'd2) + 10'd3) / 10'd7);
            red_palette[4] = 8'((({2'b0, red0} * 10'd4) + ({2'b0, red1} * 10'd3) + 10'd3) / 10'd7);
            red_palette[5] = 8'((({2'b0, red0} * 10'd3) + ({2'b0, red1} * 10'd4) + 10'd3) / 10'd7);
            red_palette[6] = 8'((({2'b0, red0} * 10'd2) + ({2'b0, red1} * 10'd5) + 10'd3) / 10'd7);
            red_palette[7] = 8'((({2'b0, red0} * 10'd1) + ({2'b0, red1} * 10'd6) + 10'd3) / 10'd7);
        end else begin
            // 6-entry interpolated + 0 and 255
            red_palette[2] = 8'((({2'b0, red0} * 10'd4) + ({2'b0, red1} * 10'd1) + 10'd2) / 10'd5);
            red_palette[3] = 8'((({2'b0, red0} * 10'd3) + ({2'b0, red1} * 10'd2) + 10'd2) / 10'd5);
            red_palette[4] = 8'((({2'b0, red0} * 10'd2) + ({2'b0, red1} * 10'd3) + 10'd2) / 10'd5);
            red_palette[5] = 8'((({2'b0, red0} * 10'd1) + ({2'b0, red1} * 10'd4) + 10'd2) / 10'd5);
            red_palette[6] = 8'd0;
            red_palette[7] = 8'd255;
        end
    end

    wire [7:0] decoded_red = red_palette[red_index];

    // Low 2 bits of R8 are discarded during truncation to R5/B5
    wire [1:0] _unused_red_low = decoded_red[1:0];

    // ========================================================================
    // Channel Replication to RGBA5652
    // ========================================================================
    // INT-032: R5={R8[7:3]}, G6={R8[7:2]}, B5={R8[7:3]}, A2=11

    assign rgba5652 = {decoded_red[7:3], decoded_red[7:2], decoded_red[7:3], 2'b11};

endmodule

`default_nettype wire
