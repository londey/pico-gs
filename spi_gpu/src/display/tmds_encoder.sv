// TMDS Encoder - 8b/10b Encoding for DVI/HDMI
// Implements standard TMDS encoding with DC balancing
// Converts 8-bit pixel data to 10-bit TMDS symbols

module tmds_encoder (
    input  wire       clk,              // Pixel clock
    input  wire       rst_n,            // Active-low reset
    input  wire [7:0] data_in,          // 8-bit pixel data
    input  wire       data_enable,      // Data enable (vs control period)
    input  wire [1:0] control,          // Control signals (hsync, vsync)
    output reg  [9:0] tmds_out          // 10-bit TMDS output
);

    // ========================================================================
    // Stage 1: XOR or XNOR Encoding
    // ========================================================================

    wire [8:0] stage1;
    wire [3:0] ones_count;

    // Count number of ones in input data
    assign ones_count = data_in[0] + data_in[1] + data_in[2] + data_in[3] +
                        data_in[4] + data_in[5] + data_in[6] + data_in[7];

    // Use XNOR if ones > 4 or (ones == 4 and bit 0 is 0), otherwise use XOR
    wire use_xnor;
    assign use_xnor = (ones_count > 4'd4) || ((ones_count == 4'd4) && (data_in[0] == 1'b0));

    // Encode using XOR or XNOR
    assign stage1[0] = data_in[0];
    assign stage1[1] = use_xnor ? (stage1[0] ~^ data_in[1]) : (stage1[0] ^ data_in[1]);
    assign stage1[2] = use_xnor ? (stage1[1] ~^ data_in[2]) : (stage1[1] ^ data_in[2]);
    assign stage1[3] = use_xnor ? (stage1[2] ~^ data_in[3]) : (stage1[2] ^ data_in[3]);
    assign stage1[4] = use_xnor ? (stage1[3] ~^ data_in[4]) : (stage1[3] ^ data_in[4]);
    assign stage1[5] = use_xnor ? (stage1[4] ~^ data_in[5]) : (stage1[4] ^ data_in[5]);
    assign stage1[6] = use_xnor ? (stage1[5] ~^ data_in[6]) : (stage1[5] ^ data_in[6]);
    assign stage1[7] = use_xnor ? (stage1[6] ~^ data_in[7]) : (stage1[6] ^ data_in[7]);
    assign stage1[8] = use_xnor ? 1'b0 : 1'b1;  // Bit 8 indicates XOR (1) or XNOR (0)

    // ========================================================================
    // Stage 2: DC Balancing
    // ========================================================================

    reg signed [4:0] dc_bias;   // Running DC bias (-16 to +16)

    wire [3:0] stage1_ones;
    wire [3:0] stage1_zeros;
    wire signed [4:0] disparity;

    // Count ones and zeros in stage1[7:0]
    assign stage1_ones = stage1[0] + stage1[1] + stage1[2] + stage1[3] +
                         stage1[4] + stage1[5] + stage1[6] + stage1[7];
    assign stage1_zeros = 4'd8 - stage1_ones;

    // Calculate disparity
    assign disparity = $signed({1'b0, stage1_ones}) - $signed({1'b0, stage1_zeros});

    wire [9:0] stage2;
    wire signed [4:0] dc_bias_next;

    always_comb begin
        if ((dc_bias == 5'sd0) || (disparity == 5'sd0)) begin
            // Balance is neutral - invert if bit 8 is 0
            stage2[9] = ~stage1[8];
            stage2[8] = stage1[8];
            stage2[7:0] = stage1[8] ? stage1[7:0] : ~stage1[7:0];

            if (stage1[8] == 1'b0) begin
                dc_bias_next = dc_bias - disparity;
            end else begin
                dc_bias_next = dc_bias + disparity;
            end

        end else if (((dc_bias > 5'sd0) && (disparity > 5'sd0)) ||
                     ((dc_bias < 5'sd0) && (disparity < 5'sd0))) begin
            // Same sign - invert to correct balance
            stage2[9] = 1'b1;
            stage2[8] = stage1[8];
            stage2[7:0] = ~stage1[7:0];
            dc_bias_next = dc_bias + $signed({stage1[8], 1'b0}) - disparity;

        end else begin
            // Opposite sign - don't invert
            stage2[9] = 1'b0;
            stage2[8] = stage1[8];
            stage2[7:0] = stage1[7:0];
            dc_bias_next = dc_bias - $signed({~stage1[8], 1'b0}) + disparity;
        end
    end

    // ========================================================================
    // Control Period Encoding
    // ========================================================================

    wire [9:0] control_symbol;

    always_comb begin
        case (control)
            2'b00: control_symbol = 10'b1101010100;  // Control 0
            2'b01: control_symbol = 10'b0010101011;  // Control 1
            2'b10: control_symbol = 10'b0101010100;  // Control 2
            2'b11: control_symbol = 10'b1010101011;  // Control 3
        endcase
    end

    // ========================================================================
    // Output Selection and DC Bias Update
    // ========================================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tmds_out <= 10'b0;
            dc_bias <= 5'sd0;
        end else begin
            if (data_enable) begin
                // Data period - use encoded data
                tmds_out <= stage2;
                dc_bias <= dc_bias_next;
            end else begin
                // Control period - use control symbols and reset DC bias
                tmds_out <= control_symbol;
                dc_bias <= 5'sd0;
            end
        end
    end

endmodule
