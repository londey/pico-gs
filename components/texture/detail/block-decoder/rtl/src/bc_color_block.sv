`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC Color Block Decode — Shared BC1/BC2/BC3 Color Endpoint + Interpolation
//
// Decodes a 64-bit BC1-style color block (two RGB565 endpoints + 32-bit index
// word) and selects one interpolated texel color in UQ1.8 format.
//
// Two modes controlled by `four_color_mode`:
//   1 (four-color opaque): palette = [C0, C1, lerp(1/3), lerp(2/3)]
//   0 (three-color + transparent): palette = [C0, C1, lerp(1/2), black]
//
// BC1 uses four_color_mode = (color0 > color1).
// BC2/BC3 force four_color_mode = 1'b1 (always 4-color opaque).
//
// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   1/3: (2*C0 + C1 + 1) * 683 >> 11
//   2/3: (C0 + 2*C1 + 1) * 683 >> 11
//   1/2: (C0 + C1 + 1) >> 1
//
// See: INT-014, INT-032, UNIT-006, REQ-003.03, DD-038, DD-039

module bc_color_block (
    // Two RGB565 color endpoints
    input  wire [15:0] color0,
    input  wire [15:0] color1,

    // 32-bit index word (2 bits per texel, texel 0 = bits [1:0])
    input  wire [31:0] indices,

    // Texel selection within 4x4 block (0..15)
    input  wire [3:0]  texel_idx,

    // Mode: 1 = 4-color opaque, 0 = 3-color + transparent
    input  wire        four_color_mode,

    // Decoded color channels (UQ1.8, 9 bits each)
    output wire [8:0]  r9,
    output wire [8:0]  g9,
    output wire [8:0]  b9,

    // Transparency flag: 1 when color_index==3 in 3-color mode
    output wire        transparent
);

    // ========================================================================
    // Index Extraction
    // ========================================================================

    wire [4:0] idx_bit_offset = {texel_idx, 1'b0};  // texel_idx * 2
    wire [1:0] color_index = indices[idx_bit_offset +: 2];

    // ========================================================================
    // Endpoint Channel Extraction + UQ1.8 Expansion
    // ========================================================================

    wire [8:0] c0_r9 = fp_types_pkg::ch5_to_uq18(color0[15:11]);
    wire [8:0] c1_r9 = fp_types_pkg::ch5_to_uq18(color1[15:11]);
    wire [8:0] c0_g9 = fp_types_pkg::ch6_to_uq18(color0[10:5]);
    wire [8:0] c1_g9 = fp_types_pkg::ch6_to_uq18(color1[10:5]);
    wire [8:0] c0_b9 = fp_types_pkg::ch5_to_uq18(color0[4:0]);
    wire [8:0] c1_b9 = fp_types_pkg::ch5_to_uq18(color1[4:0]);

    // ========================================================================
    // 1/3 Interpolation: (2*C0 + C1 + 1) * 683 >> 11
    // ========================================================================

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

    // ========================================================================
    // 2/3 Interpolation: (C0 + 2*C1 + 1) * 683 >> 11
    // ========================================================================

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

    // ========================================================================
    // 1/2 Interpolation: (C0 + C1 + 1) >> 1  (3-color mode only)
    // ========================================================================

    // verilator lint_off UNUSEDSIGNAL
    wire [9:0] sum12_r9 = {1'b0, c0_r9} + {1'b0, c1_r9} + 10'd1;
    wire [9:0] sum12_g9 = {1'b0, c0_g9} + {1'b0, c1_g9} + 10'd1;
    wire [9:0] sum12_b9 = {1'b0, c0_b9} + {1'b0, c1_b9} + 10'd1;
    // verilator lint_on UNUSEDSIGNAL

    wire [8:0] interp12_r9 = sum12_r9[9:1];
    wire [8:0] interp12_g9 = sum12_g9[9:1];
    wire [8:0] interp12_b9 = sum12_b9[9:1];

    // ========================================================================
    // Palette Selection
    // ========================================================================

    reg [8:0] sel_r9;
    reg [8:0] sel_g9;
    reg [8:0] sel_b9;
    reg       sel_transparent;

    always_comb begin
        sel_transparent = 1'b0;

        case (color_index)
            2'd0: begin
                sel_r9 = c0_r9;
                sel_g9 = c0_g9;
                sel_b9 = c0_b9;
            end
            2'd1: begin
                sel_r9 = c1_r9;
                sel_g9 = c1_g9;
                sel_b9 = c1_b9;
            end
            2'd2: begin
                if (four_color_mode) begin
                    sel_r9 = interp13_r9;
                    sel_g9 = interp13_g9;
                    sel_b9 = interp13_b9;
                end else begin
                    sel_r9 = interp12_r9;
                    sel_g9 = interp12_g9;
                    sel_b9 = interp12_b9;
                end
            end
            2'd3: begin
                if (four_color_mode) begin
                    sel_r9 = interp23_r9;
                    sel_g9 = interp23_g9;
                    sel_b9 = interp23_b9;
                end else begin
                    sel_r9 = 9'd0;
                    sel_g9 = 9'd0;
                    sel_b9 = 9'd0;
                    sel_transparent = 1'b1;
                end
            end
            default: begin
                sel_r9 = 9'd0;
                sel_g9 = 9'd0;
                sel_b9 = 9'd0;
            end
        endcase
    end

    assign r9 = sel_r9;
    assign g9 = sel_g9;
    assign b9 = sel_b9;
    assign transparent = sel_transparent;

endmodule

`default_nettype wire
