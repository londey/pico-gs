`default_nettype none

// Timing Generator - 640×480 @ 60Hz Video Timing
// Generates horizontal and vertical sync signals and pixel coordinates
// CEA-861 standard timing for VGA resolution

module timing_generator (
    input  wire         clk_pixel,      // 25.000 MHz pixel clock
    input  wire         rst_n,          // Active-low reset

    output wire         hsync,          // Horizontal sync
    output wire         vsync,          // Vertical sync
    output wire         display_enable, // Active display area
    output wire [9:0]   pixel_x,        // Pixel X coordinate (0-639)
    output wire [9:0]   pixel_y,        // Pixel Y coordinate (0-479)
    output wire         frame_start     // Pulse at start of new frame
);

    // ========================================================================
    // Timing Parameters for 640×480 @ 60Hz
    // ========================================================================

    // Horizontal timing (pixel clock = 25.000 MHz)
    localparam [9:0] H_DISPLAY    = 10'd640;  // Active video
    localparam [9:0] H_FRONT      = 10'd16;   // Front porch
    localparam [9:0] H_SYNC       = 10'd96;   // Sync pulse
    localparam [9:0] H_BACK       = 10'd48;   // Back porch (used in H_TOTAL calculation)
    localparam [9:0] H_TOTAL      = 10'd800;  // Total horizontal period

    // H_BACK and V_BACK are retained for specification completeness; H_TOTAL and
    // V_TOTAL are pre-computed constants that incorporate them.
    wire [9:0] _unused_h_back = H_BACK;

    // Vertical timing
    localparam [9:0] V_DISPLAY    = 10'd480;  // Active video
    localparam [9:0] V_FRONT      = 10'd10;   // Front porch
    localparam [9:0] V_SYNC       = 10'd2;    // Sync pulse
    localparam [9:0] V_BACK       = 10'd33;   // Back porch (used in V_TOTAL calculation)
    localparam [9:0] V_TOTAL      = 10'd525;  // Total vertical period

    wire [9:0] _unused_v_back = V_BACK;

    // Sync pulse positions
    localparam [9:0] H_SYNC_START = H_DISPLAY + H_FRONT;
    localparam [9:0] H_SYNC_END   = H_SYNC_START + H_SYNC;
    localparam [9:0] V_SYNC_START = V_DISPLAY + V_FRONT;
    localparam [9:0] V_SYNC_END   = V_SYNC_START + V_SYNC;

    // ========================================================================
    // Counters
    // ========================================================================

    reg [9:0] h_count;      // Horizontal pixel counter (0-799)
    reg [9:0] v_count;      // Vertical line counter (0-524)

    // ========================================================================
    // Horizontal Counter
    // ========================================================================

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 10'd0;
        end else begin
            if (h_count == H_TOTAL - 1) begin
                h_count <= 10'd0;
            end else begin
                h_count <= h_count + 10'd1;
            end
        end
    end

    // ========================================================================
    // Vertical Counter
    // ========================================================================

    wire h_end;
    assign h_end = (h_count == H_TOTAL - 1);

    always_ff @(posedge clk_pixel or negedge rst_n) begin
        if (!rst_n) begin
            v_count <= 10'd0;
        end else begin
            if (h_end) begin
                if (v_count == V_TOTAL - 1) begin
                    v_count <= 10'd0;
                end else begin
                    v_count <= v_count + 10'd1;
                end
            end
        end
    end

    // ========================================================================
    // Sync Generation
    // ========================================================================

    // Combinational sync signals (negative polarity for VGA)
    // Active low when in sync pulse region
    wire hsync_active;
    wire vsync_active;

    assign hsync_active = (h_count >= H_SYNC_START) && (h_count < H_SYNC_END);
    assign vsync_active = (v_count >= V_SYNC_START) && (v_count < V_SYNC_END);

    // Sync outputs - active low (0 during pulse, 1 otherwise)
    assign hsync = ~hsync_active;
    assign vsync = ~vsync_active;

    // ========================================================================
    // Display Enable and Pixel Coordinates
    // ========================================================================

    wire h_active;
    wire v_active;

    assign h_active = (h_count < H_DISPLAY);
    assign v_active = (v_count < V_DISPLAY);

    // Combinational outputs based on current counter values
    assign display_enable = h_active && v_active;
    assign pixel_x = h_active ? h_count : 10'd0;
    assign pixel_y = v_active ? v_count : 10'd0;

    // ========================================================================
    // Frame Start Pulse
    // ========================================================================

    assign frame_start = (h_count == 10'd0) && (v_count == 10'd0);

endmodule

`default_nettype wire
