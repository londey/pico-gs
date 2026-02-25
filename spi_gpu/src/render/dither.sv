`default_nettype none

// Spec-ref: unit_006_pixel_pipeline.md `9922acb997237266` 2026-02-25
//
// Ordered Dithering — EBR-based 16x16 Blue Noise Dither Matrix
//
// Adds a dither offset to Q4.12 color channels before truncation to RGB565.
// The dither matrix is stored in a 256-entry EBR (16x16, 16 bits per entry).
//
// The dither offset is scaled to the quantization step size of the target channel:
//   R5/B5: step = 1/31  in Q4.12 ~ 132 (0x0084)
//   G6:    step = 1/63  in Q4.12 ~ 65  (0x0041)
// The dither value from the matrix (0..255) is scaled by (step / 256) to produce
// a dither offset in [0, step) that is added to the channel before rounding.
//
// Initially the matrix is filled with a constant baked-in blue noise pattern;
// the actual values can be refined when the pattern is finalized.
//
// See: UNIT-006 (Pixel Pipeline, Ordered Dithering), REQ-005.10 (Ordered Dithering)

module dither (
    input  wire        clk,              // 100 MHz core clock
    input  wire        rst_n,            // Active-low reset

    // Fragment position (low 4 bits for 16x16 matrix lookup)
    input  wire [3:0]  frag_x,           // Fragment X coordinate [3:0]
    input  wire [3:0]  frag_y,           // Fragment Y coordinate [3:0]

    // Input color in Q4.12 format (RGB, 48 bits total)
    //   [47:32] = R Q4.12
    //   [31:16] = G Q4.12
    //   [15:0]  = B Q4.12
    input  wire [47:0] color_in,

    // Dither enable (from RENDER_MODE.DITHER_EN)
    input  wire        dither_en,

    // Output color with dither added (Q4.12 format, ready for truncation)
    //   [47:32] = R Q4.12
    //   [31:16] = G Q4.12
    //   [15:0]  = B Q4.12
    output reg  [47:0] color_out
);

    // ========================================================================
    // Suppress unused signal warnings
    // ========================================================================

    wire _unused_clk   = clk;
    wire _unused_rst_n = rst_n;

    // ========================================================================
    // Dither Matrix (256 entries x 8-bit, stored in EBR)
    // ========================================================================
    // 16x16 Bayer ordered dither matrix (placeholder — replace with blue noise
    // when the final pattern is available). Values range [0, 255].

    reg [7:0] dither_matrix [0:255];

    // Initialize with 4x4 Bayer matrix tiled to 16x16
    // Standard 4x4 Bayer threshold matrix (scaled to 0..255):
    //   [  0, 128,  32, 160 ]
    //   [192,  64, 224,  96 ]
    //   [ 48, 176,  16, 144 ]
    //   [240, 112, 208,  80 ]
    integer init_x, init_y;
    reg [7:0] bayer4x4 [0:15];

    initial begin
        // 4x4 Bayer matrix entries (row-major)
        bayer4x4[0]  = 8'd0;   bayer4x4[1]  = 8'd128; bayer4x4[2]  = 8'd32;  bayer4x4[3]  = 8'd160;
        bayer4x4[4]  = 8'd192; bayer4x4[5]  = 8'd64;  bayer4x4[6]  = 8'd224; bayer4x4[7]  = 8'd96;
        bayer4x4[8]  = 8'd48;  bayer4x4[9]  = 8'd176; bayer4x4[10] = 8'd16;  bayer4x4[11] = 8'd144;
        bayer4x4[12] = 8'd240; bayer4x4[13] = 8'd112; bayer4x4[14] = 8'd208; bayer4x4[15] = 8'd80;

        // Tile the 4x4 matrix across the 16x16 matrix
        for (init_y = 0; init_y < 16; init_y = init_y + 1) begin
            for (init_x = 0; init_x < 16; init_x = init_x + 1) begin
                dither_matrix[init_y * 16 + init_x] =
                    bayer4x4[(init_y & 3) * 4 + (init_x & 3)];
            end
        end
    end

    // ========================================================================
    // Matrix Lookup
    // ========================================================================

    wire [7:0] matrix_addr = {frag_y, frag_x};
    wire [7:0] dither_val  = dither_matrix[matrix_addr];

    // ========================================================================
    // Dither Offset Calculation
    // ========================================================================
    // For R5/B5: quantization step in Q4.12 ~ 0x0084 (132)
    //   dither_offset = dither_val * 132 / 256 = dither_val * 132 >> 8
    // For G6: quantization step in Q4.12 ~ 0x0041 (65)
    //   dither_offset = dither_val * 65 / 256 = dither_val * 65 >> 8
    //
    // Use 16-bit intermediates for multiplication.

    wire [15:0] offset_r5 = ({8'b0, dither_val} * 16'd132) >> 8;
    wire [15:0] offset_g6 = ({8'b0, dither_val} * 16'd65)  >> 8;

    // ========================================================================
    // Channel Extraction and Dither Application
    // ========================================================================

    wire [15:0] r_in = color_in[47:32];
    wire [15:0] g_in = color_in[31:16];
    wire [15:0] b_in = color_in[15:0];

    // Add dither offset (unsigned addition, clamp handled downstream)
    wire [15:0] r_dithered = r_in + offset_r5;
    wire [15:0] g_dithered = g_in + offset_g6;
    wire [15:0] b_dithered = b_in + offset_r5;  // B5 same step as R5

    // ========================================================================
    // Output Mux
    // ========================================================================

    always_comb begin
        if (dither_en) begin
            color_out = {r_dithered, g_dithered, b_dithered};
        end else begin
            color_out = color_in;
        end
    end

endmodule

`default_nettype wire
