`default_nettype none

// Spec-ref: unit_011.04_block_decompressor.md `ae643bc5eafd7b0c` 2026-03-23
//
// BC Alpha Block Decode — Shared BC3 Alpha / BC4 Red Interpolation
//
// Decodes a 64-bit BC3-style alpha block (two 8-bit endpoints + 48-bit
// 3-bit index table) and selects one interpolated value.
//
// Two modes determined by endpoint0 vs endpoint1 comparison:
//   endpoint0 >  endpoint1: 8-entry interpolated palette (divide by 7)
//   endpoint0 <= endpoint1: 6-entry interpolated + 0, 255 (divide by 5)
//
// Interpolation uses shift+add reciprocal-multiply (DD-039, 0 DSP slices):
//   /7: (w0*e0 + w1*e1 + 3) * 2341 >> 14  (exact for x <= 1788)
//   /5: (w0*e0 + w1*e1 + 2) * 3277 >> 14  (exact for x <= 1277)
//
// Mux-first architecture: weights are selected by alpha_index before
// computing a single weighted sum and single reciprocal multiply,
// eliminating all hardware multipliers.
//
// Used by BC3 (alpha channel) and BC4 (red channel, replicated to RGB).
//
// See: INT-014, UNIT-011.04, UNIT-006, REQ-003.03, DD-038, DD-039

module bc_alpha_block (
    // Two 8-bit endpoints
    input  wire [7:0]  endpoint0,
    input  wire [7:0]  endpoint1,

    // 48-bit index table (3 bits per texel, 16 texels)
    input  wire [47:0] index_data,

    // Texel selection within 4x4 block (0..15)
    input  wire [3:0]  texel_idx,

    // Decoded value (8-bit, before UQ1.8 expansion)
    output wire [7:0]  decoded_value
);

    // ========================================================================
    // Index Extraction
    // ========================================================================
    // Each texel uses 3 bits; bit_offset = texel_idx * 3

    wire [5:0] idx_bit_offset = {2'b00, texel_idx} + {2'b00, texel_idx}
                               + {2'b00, texel_idx};
    wire [2:0] alpha_index = index_data[idx_bit_offset +: 3];

    // ========================================================================
    // Mode Selection
    // ========================================================================

    wire eight_entry_mode = (endpoint0 > endpoint1);

    // ========================================================================
    // Weight Lookup (mux-first: select weights before computing)
    // ========================================================================
    // 8-entry mode: w0 = 8-idx, w1 = idx-1  (indices 2..7, weights 1..6)
    // 6-entry mode: w0 = 6-idx, w1 = idx-1  (indices 2..5, weights 1..4)

    reg [2:0] weight0;
    reg [2:0] weight1;

    always_comb begin
        if (eight_entry_mode) begin
            case (alpha_index)
                3'd2:    begin weight0 = 3'd6; weight1 = 3'd1; end
                3'd3:    begin weight0 = 3'd5; weight1 = 3'd2; end
                3'd4:    begin weight0 = 3'd4; weight1 = 3'd3; end
                3'd5:    begin weight0 = 3'd3; weight1 = 3'd4; end
                3'd6:    begin weight0 = 3'd2; weight1 = 3'd5; end
                3'd7:    begin weight0 = 3'd1; weight1 = 3'd6; end
                default: begin weight0 = 3'd0; weight1 = 3'd0; end
            endcase
        end else begin
            case (alpha_index)
                3'd2:    begin weight0 = 3'd4; weight1 = 3'd1; end
                3'd3:    begin weight0 = 3'd3; weight1 = 3'd2; end
                3'd4:    begin weight0 = 3'd2; weight1 = 3'd3; end
                3'd5:    begin weight0 = 3'd1; weight1 = 3'd4; end
                default: begin weight0 = 3'd0; weight1 = 3'd0; end
            endcase
        end
    end

    // ========================================================================
    // Shift+Add Multiply: endpoint * weight (0 DSP slices)
    // ========================================================================
    // Weights are 1..6; each case is pure shift+add.

    reg [10:0] prod0;
    reg [10:0] prod1;

    always_comb begin
        case (weight0)
            3'd1:    prod0 = {3'b0, endpoint0};
            3'd2:    prod0 = {2'b0, endpoint0, 1'b0};
            3'd3:    prod0 = {2'b0, endpoint0, 1'b0} + {3'b0, endpoint0};
            3'd4:    prod0 = {1'b0, endpoint0, 2'b0};
            3'd5:    prod0 = {1'b0, endpoint0, 2'b0} + {3'b0, endpoint0};
            3'd6:    prod0 = {1'b0, endpoint0, 2'b0} + {2'b0, endpoint0, 1'b0};
            default: prod0 = 11'd0;
        endcase
    end

    always_comb begin
        case (weight1)
            3'd1:    prod1 = {3'b0, endpoint1};
            3'd2:    prod1 = {2'b0, endpoint1, 1'b0};
            3'd3:    prod1 = {2'b0, endpoint1, 1'b0} + {3'b0, endpoint1};
            3'd4:    prod1 = {1'b0, endpoint1, 2'b0};
            3'd5:    prod1 = {1'b0, endpoint1, 2'b0} + {3'b0, endpoint1};
            3'd6:    prod1 = {1'b0, endpoint1, 2'b0} + {2'b0, endpoint1, 1'b0};
            default: prod1 = 11'd0;
        endcase
    end

    // ========================================================================
    // Weighted Sum + Rounding Bias
    // ========================================================================

    wire [10:0] bias        = eight_entry_mode ? 11'd3 : 11'd2;
    wire [10:0] weighted_sum = prod0 + prod1 + bias;

    // ========================================================================
    // Reciprocal Multiply via Shift+Add (0 DSP slices)
    // ========================================================================
    // /7: x * 2341 = x*(2^11 + 2^8 + 2^5 + 2^2 + 2^0)
    // /5: x * 3277 = x*(2^11 + 2^10 + 2^7 + 2^6 + 2^3 + 2^2 + 2^0)

    // verilator lint_off UNUSEDSIGNAL
    wire [21:0] recip_7 = {weighted_sum, 11'b0}
                         + {3'b0, weighted_sum, 8'b0}
                         + {6'b0, weighted_sum, 5'b0}
                         + {9'b0, weighted_sum, 2'b0}
                         + {11'b0, weighted_sum};

    wire [21:0] recip_5 = {weighted_sum, 11'b0}
                         + {1'b0, weighted_sum, 10'b0}
                         + {4'b0, weighted_sum, 7'b0}
                         + {5'b0, weighted_sum, 6'b0}
                         + {8'b0, weighted_sum, 3'b0}
                         + {9'b0, weighted_sum, 2'b0}
                         + {11'b0, weighted_sum};
    // verilator lint_on UNUSEDSIGNAL

    wire [7:0] interp_value = eight_entry_mode ? recip_7[21:14]
                                               : recip_5[21:14];

    // ========================================================================
    // Output Mux
    // ========================================================================

    reg [7:0] result;

    always_comb begin
        case (alpha_index)
            3'd0:    result = endpoint0;
            3'd1:    result = endpoint1;
            3'd6:    result = eight_entry_mode ? interp_value : 8'd0;
            3'd7:    result = eight_entry_mode ? interp_value : 8'd255;
            default: result = interp_value;
        endcase
    end

    assign decoded_value = result;

endmodule

`default_nettype wire
