`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `164319138ecccf06` 2026-03-14
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
// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   1/3: (2*C0 + C1 + 1) * 683 >> 11   (exact for operands up to 769)
//   2/3: (C0 + 2*C1 + 1) * 683 >> 11
//   1/2: (C0 + C1 + 1) >> 1
//
// Endpoints expanded to UQ1.8 (9 bits) before interpolation;
// output {R9, G9, B9, A9} in bits [35:0].
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

    // Extract 2-bit index for the selected texel
    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};  // texel_idx * 2
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

    // Mode select: 4-color (opaque) vs 3-color + transparent
    wire four_color_mode = (color0 > color1);

    // ========================================================================
    // Endpoint Channel Extraction
    // ========================================================================

    wire [4:0] c0_r = color0[15:11];
    wire [4:0] c1_r = color1[15:11];
    wire [5:0] c0_g = color0[10:5];
    wire [5:0] c1_g = color1[10:5];
    wire [4:0] c0_b = color0[4:0];
    wire [4:0] c1_b = color1[4:0];

    // ========================================================================
    // UQ1.8 Interpolation (9-bit promoted endpoints)
    // ========================================================================
    // Expand R5/G6/B5 endpoints to UQ1.8 (9-bit) via bit-replication + correction,
    // matching gs-twin ch5_to_uq18()/ch6_to_uq18() formulas. Then interpolate
    // at 9-bit precision.
    //
    // R5→UQ1.8: {r5, r5[4:2]} + r5[4] = (r5<<3 | r5>>2) + (r5>>4)
    // G6→UQ1.8: {g6, g6[5:4]} + g6[5] = (g6<<2 | g6>>4) + (g6>>5)
    // B5→UQ1.8: same as R5

    wire [8:0] c0_r9 = {1'b0, c0_r, c0_r[4:2]} + {8'b0, c0_r[4]};
    wire [8:0] c1_r9 = {1'b0, c1_r, c1_r[4:2]} + {8'b0, c1_r[4]};
    wire [8:0] c0_g9 = {1'b0, c0_g, c0_g[5:4]} + {8'b0, c0_g[5]};
    wire [8:0] c1_g9 = {1'b0, c1_g, c1_g[5:4]} + {8'b0, c1_g[5]};
    wire [8:0] c0_b9 = {1'b0, c0_b, c0_b[4:2]} + {8'b0, c0_b[4]};
    wire [8:0] c1_b9 = {1'b0, c1_b, c1_b[4:2]} + {8'b0, c1_b[4]};

    // 1/3 point UQ1.8: (2*C0_9 + C1_9 + 1) / 3 via (x * 683) >> 11
    wire [10:0] sum13_r9 = {2'b0, c0_r9} + {2'b0, c0_r9} + {2'b0, c1_r9} + 11'd1;
    wire [10:0] sum13_g9 = {2'b0, c0_g9} + {2'b0, c0_g9} + {2'b0, c1_g9} + 11'd1;
    wire [10:0] sum13_b9 = {2'b0, c0_b9} + {2'b0, c0_b9} + {2'b0, c1_b9} + 11'd1;

    // verilator lint_off UNUSEDSIGNAL
    wire [20:0] prod13_r9 = {10'b0, sum13_r9} * 21'd683;
    wire [20:0] prod13_g9 = {10'b0, sum13_g9} * 21'd683;
    wire [20:0] prod13_b9 = {10'b0, sum13_b9} * 21'd683;
    // verilator lint_on UNUSEDSIGNAL

    wire [8:0] interp13_r9 = prod13_r9[19:11];
    wire [8:0] interp13_g9 = prod13_g9[19:11];
    wire [8:0] interp13_b9 = prod13_b9[19:11];

    // 2/3 point UQ1.8
    wire [10:0] sum23_r9 = {2'b0, c0_r9} + {2'b0, c1_r9} + {2'b0, c1_r9} + 11'd1;
    wire [10:0] sum23_g9 = {2'b0, c0_g9} + {2'b0, c1_g9} + {2'b0, c1_g9} + 11'd1;
    wire [10:0] sum23_b9 = {2'b0, c0_b9} + {2'b0, c1_b9} + {2'b0, c1_b9} + 11'd1;

    // verilator lint_off UNUSEDSIGNAL
    wire [20:0] prod23_r9 = {10'b0, sum23_r9} * 21'd683;
    wire [20:0] prod23_g9 = {10'b0, sum23_g9} * 21'd683;
    wire [20:0] prod23_b9 = {10'b0, sum23_b9} * 21'd683;
    // verilator lint_on UNUSEDSIGNAL

    wire [8:0] interp23_r9 = prod23_r9[19:11];
    wire [8:0] interp23_g9 = prod23_g9[19:11];
    wire [8:0] interp23_b9 = prod23_b9[19:11];

    // 1/2 point UQ1.8: (C0_9 + C1_9 + 1) / 2 — bit-select [N:1]
    // verilator lint_off UNUSEDSIGNAL
    wire [9:0] sum12_r9 = {1'b0, c0_r9} + {1'b0, c1_r9} + 10'd1;
    wire [9:0] sum12_g9 = {1'b0, c0_g9} + {1'b0, c1_g9} + 10'd1;
    wire [9:0] sum12_b9 = {1'b0, c0_b9} + {1'b0, c1_b9} + 10'd1;
    // verilator lint_on UNUSEDSIGNAL
    wire [8:0] interp12_r9 = sum12_r9[9:1];
    wire [8:0] interp12_g9 = sum12_g9[9:1];
    wire [8:0] interp12_b9 = sum12_b9[9:1];

    // ========================================================================
    // Palette Generation
    // ========================================================================

    reg [35:0] palette [0:3];

    always_comb begin
        // UQ1.8 {R9, G9, B9, A9} = 36 bits
        palette[0] = {c0_r9, c0_g9, c0_b9, 9'h100};
        palette[1] = {c1_r9, c1_g9, c1_b9, 9'h100};

        if (four_color_mode) begin
            palette[2] = {interp13_r9, interp13_g9, interp13_b9, 9'h100};
            palette[3] = {interp23_r9, interp23_g9, interp23_b9, 9'h100};
        end else begin
            palette[2] = {interp12_r9, interp12_g9, interp12_b9, 9'h100};
            palette[3] = 36'b0;  // transparent black (A9=0)
        end
    end

    // ========================================================================
    // Output Assembly
    // ========================================================================

    assign texel_out = palette[color_index];

endmodule

`default_nettype wire
