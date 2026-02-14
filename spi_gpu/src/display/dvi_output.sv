// DVI Output - TMDS Serialization using ECP5 SERDES
// Uses ECP5 ODDRX2F primitives for 10:1 serialization
// Outputs differential TMDS pairs for RGB data and clock

module dvi_output (
    input  wire       clk_pixel,        // 25.000 MHz pixel clock (clk_core / 4)
    input  wire       clk_tmds,         // 250.0 MHz TMDS bit clock (10x pixel clock)
    input  wire       rst_n,            // Active-low reset

    // Pixel data inputs
    input  wire [7:0] red,
    input  wire [7:0] green,
    input  wire [7:0] blue,
    input  wire       hsync,
    input  wire       vsync,
    input  wire       display_enable,

    // TMDS outputs (differential)
    output wire       tmds_red_p,
    output wire       tmds_red_n,
    output wire       tmds_green_p,
    output wire       tmds_green_n,
    output wire       tmds_blue_p,
    output wire       tmds_blue_n,
    output wire       tmds_clk_p,
    output wire       tmds_clk_n
);

    // ========================================================================
    // TMDS Encoders
    // ========================================================================

    wire [9:0] tmds_red;
    wire [9:0] tmds_green;
    wire [9:0] tmds_blue;

    // Red channel encoder
    tmds_encoder u_tmds_red (
        .clk(clk_pixel),
        .rst_n(rst_n),
        .data_in(red),
        .data_enable(display_enable),
        .control(2'b00),
        .tmds_out(tmds_red)
    );

    // Green channel encoder
    tmds_encoder u_tmds_green (
        .clk(clk_pixel),
        .rst_n(rst_n),
        .data_in(green),
        .data_enable(display_enable),
        .control(2'b00),
        .tmds_out(tmds_green)
    );

    // Blue channel encoder (includes sync signals)
    tmds_encoder u_tmds_blue (
        .clk(clk_pixel),
        .rst_n(rst_n),
        .data_in(blue),
        .data_enable(display_enable),
        .control({vsync, hsync}),
        .tmds_out(tmds_blue)
    );

    // ========================================================================
    // SERDES - 10:1 Serialization
    // ========================================================================

    // For ECP5, we use ODDRX2F primitives to create a 10:1 serializer
    // This requires 5 DDR outputs running at 5× pixel clock
    // However, the ECP5 SERDES is complex - for now we'll use a simpler approach

    // Note: Proper ECP5 SERDES implementation would use ODDRX2F + OLVDS
    // For simplicity in this initial implementation, we'll use a shift register
    // This may need to be replaced with actual SERDES primitives for hardware

    reg [9:0] shift_red;
    reg [9:0] shift_green;
    reg [9:0] shift_blue;
    reg [2:0] bit_count;

    // Simplified serialization (WARNING: This may not meet timing on real hardware)
    // Replace with proper SERDES instantiation for production
    always_ff @(posedge clk_tmds or negedge rst_n) begin
        if (!rst_n) begin
            shift_red <= 10'b0;
            shift_green <= 10'b0;
            shift_blue <= 10'b0;
            bit_count <= 3'd0;
        end else begin
            if (bit_count == 3'd0) begin
                // Load new data
                shift_red <= tmds_red;
                shift_green <= tmds_green;
                shift_blue <= tmds_blue;
                bit_count <= 3'd9;
            end else begin
                // Shift out MSB
                shift_red <= {shift_red[8:0], 1'b0};
                shift_green <= {shift_green[8:0], 1'b0};
                shift_blue <= {shift_blue[8:0], 1'b0};
                bit_count <= bit_count - 3'd1;
            end
        end
    end

    // ========================================================================
    // Differential Output Buffers
    // ========================================================================

    // For ECP5, use OLVDS primitive for differential LVDS output
    // TODO: Replace with proper OLVDS instantiation

    // Temporary single-ended assignments (for initial testing)
    assign tmds_red_p = shift_red[9];
    assign tmds_red_n = ~shift_red[9];

    assign tmds_green_p = shift_green[9];
    assign tmds_green_n = ~shift_green[9];

    assign tmds_blue_p = shift_blue[9];
    assign tmds_blue_n = ~shift_blue[9];

    // Clock channel (just output the pixel clock serialized)
    assign tmds_clk_p = clk_pixel;
    assign tmds_clk_n = ~clk_pixel;

endmodule
