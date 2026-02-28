`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `f7ece909bb04a361` 2026-02-28
//
// BC1 (DXT1) Texture Decoder — FORMAT=0
//
// Decodes a 64-bit BC1 compressed block to produce one RGBA5652 texel.
// BC1 block structure (8 bytes):
//   Bytes 0-1: color0 (RGB565, little-endian)
//   Bytes 2-3: color1 (RGB565, little-endian)
//   Bytes 4-7: 32-bit index word (2 bits per texel, 16 texels)
//
// Two modes determined by color0 vs color1 comparison:
//   color0 >  color1: 4-color opaque mode
//     palette = [C0, C1, lerp(C0,C1,1/3), lerp(C0,C1,2/3)], all A2=11
//   color0 <= color1: 3-color + transparent mode
//     palette = [C0, C1, lerp(C0,C1,1/2), transparent (A2=00)]
//
// Interpolation uses integer arithmetic per DXT1 specification:
//   1/3: (2*C0 + C1 + 1) / 3
//   2/3: (C0 + 2*C1 + 1) / 3
//   1/2: (C0 + C1 + 1) / 2
//
// See: INT-014 (Texture Memory Layout, Format 0), INT-032 (Texture Cache, BC1),
//      UNIT-006 (Pixel Pipeline), REQ-003.03 (Compressed Textures)

module texture_bc1 (
    // Block data: 64 bits (8 bytes, little-endian)
    //   [15:0]   = color0 (RGB565)
    //   [31:16]  = color1 (RGB565)
    //   [63:32]  = 32-bit index word (2 bits per texel, texel 0 = bits [1:0])
    input  wire [63:0]  bc1_data,

    // Texel selection within 4x4 block (0..15, row-major: t = y*4 + x)
    input  wire [3:0]   texel_idx,

    // Decoded output in RGBA5652 format: {R5, G6, B5, A2} = 18 bits
    output wire [17:0]  rgba5652
);

    // ========================================================================
    // Endpoint Extraction
    // ========================================================================

    wire [15:0] color0 = bc1_data[15:0];
    wire [15:0] color1 = bc1_data[31:16];
    wire [31:0] indices = bc1_data[63:32];

    // Extract 2-bit index for the selected texel
    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};  // texel_idx * 2
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

    // Mode select: 4-color (opaque) vs 3-color + transparent
    wire four_color_mode = (color0 > color1);

    // ========================================================================
    // Per-Channel Interpolation
    // ========================================================================
    // R5 channel: color0[15:11], color1[15:11]
    // G6 channel: color0[10:5],  color1[10:5]
    // B5 channel: color0[4:0],   color1[4:0]

    wire [4:0] c0_r = color0[15:11];
    wire [4:0] c1_r = color1[15:11];
    wire [5:0] c0_g = color0[10:5];
    wire [5:0] c1_g = color1[10:5];
    wire [4:0] c0_b = color0[4:0];
    wire [4:0] c1_b = color1[4:0];

    // Interpolation intermediates (wider for arithmetic, only low bits used)
    // 1/3 point: (2*C0 + C1 + 1) / 3
    wire [6:0] interp13_r = ({2'b0, c0_r} + {2'b0, c0_r} + {2'b0, c1_r} + 7'd1) / 7'd3;
    wire [7:0] interp13_g = ({2'b0, c0_g} + {2'b0, c0_g} + {2'b0, c1_g} + 8'd1) / 8'd3;
    wire [6:0] interp13_b = ({2'b0, c0_b} + {2'b0, c0_b} + {2'b0, c1_b} + 7'd1) / 7'd3;

    // 2/3 point: (C0 + 2*C1 + 1) / 3
    wire [6:0] interp23_r = ({2'b0, c0_r} + {2'b0, c1_r} + {2'b0, c1_r} + 7'd1) / 7'd3;
    wire [7:0] interp23_g = ({2'b0, c0_g} + {2'b0, c1_g} + {2'b0, c1_g} + 8'd1) / 8'd3;
    wire [6:0] interp23_b = ({2'b0, c0_b} + {2'b0, c1_b} + {2'b0, c1_b} + 7'd1) / 7'd3;

    // 1/2 point: (C0 + C1 + 1) / 2  (rounding addition, standard halving)
    wire [5:0] interp12_r = ({1'b0, c0_r} + {1'b0, c1_r} + 6'd1) >> 1;
    wire [6:0] interp12_g = ({1'b0, c0_g} + {1'b0, c1_g} + 7'd1) >> 1;
    wire [5:0] interp12_b = ({1'b0, c0_b} + {1'b0, c1_b} + 6'd1) >> 1;

    // High bits of interpolation results are unused (division result fits in low bits)
    wire [1:0] _unused_interp13_r_hi = interp13_r[6:5];
    wire [1:0] _unused_interp13_g_hi = interp13_g[7:6];
    wire [1:0] _unused_interp13_b_hi = interp13_b[6:5];
    wire [1:0] _unused_interp23_r_hi = interp23_r[6:5];
    wire [1:0] _unused_interp23_g_hi = interp23_g[7:6];
    wire [1:0] _unused_interp23_b_hi = interp23_b[6:5];
    wire       _unused_interp12_r_hi = interp12_r[5];
    wire       _unused_interp12_g_hi = interp12_g[6];
    wire       _unused_interp12_b_hi = interp12_b[5];

    // ========================================================================
    // Palette Generation
    // ========================================================================

    reg [15:0] palette [0:3];
    reg [1:0]  palette_alpha [0:3];

    always_comb begin
        // Entry 0: color0, opaque
        palette[0] = color0;
        palette_alpha[0] = 2'b11;

        // Entry 1: color1, opaque
        palette[1] = color1;
        palette_alpha[1] = 2'b11;

        if (four_color_mode) begin
            // 4-color opaque mode
            // Entry 2: lerp(C0, C1, 1/3)
            palette[2] = {interp13_r[4:0], interp13_g[5:0], interp13_b[4:0]};
            palette_alpha[2] = 2'b11;

            // Entry 3: lerp(C0, C1, 2/3)
            palette[3] = {interp23_r[4:0], interp23_g[5:0], interp23_b[4:0]};
            palette_alpha[3] = 2'b11;
        end else begin
            // 3-color + transparent mode
            // Entry 2: lerp(C0, C1, 1/2)
            palette[2] = {interp12_r[4:0], interp12_g[5:0], interp12_b[4:0]};
            palette_alpha[2] = 2'b11;

            // Entry 3: transparent black
            palette[3] = 16'h0000;
            palette_alpha[3] = 2'b00;
        end
    end

    // ========================================================================
    // Output Assembly
    // ========================================================================
    // Select palette entry by index, assemble RGBA5652

    wire [15:0] selected_color = palette[color_index];
    wire [1:0]  selected_alpha = palette_alpha[color_index];

    assign rgba5652 = {selected_color, selected_alpha};

endmodule

`default_nettype wire
