// Display Controller - Framebuffer Scanout with Prefetch
// Fetches pixels from SRAM and feeds them to the display via scanline FIFO
// Stays ahead of scanout to prevent underruns

module display_controller (
    // SRAM clock domain (100 MHz)
    input  wire         clk_sram,
    input  wire         rst_n_sram,

    // Pixel clock domain (25 MHz)
    input  wire         clk_pixel,
    input  wire         rst_n_pixel,

    // Timing inputs (pixel clock domain)
    input  wire         display_enable,
    input  wire [9:0]   pixel_x,
    input  wire [9:0]   pixel_y,
    input  wire         frame_start,

    // Framebuffer configuration (SRAM clock domain)
    input  wire [31:12] fb_display_base,    // Display framebuffer base address

    // SRAM interface (SRAM clock domain)
    output reg          sram_req,
    output wire         sram_we,        // Always 0 (read-only)
    output reg  [23:0]  sram_addr,
    output wire [31:0]  sram_wdata,     // Always 0 (read-only)
    input  wire [31:0]  sram_rdata,
    input  wire         sram_ack,
    input  wire         sram_ready,

    // Pixel output (pixel clock domain)
    output wire [7:0]   pixel_red,
    output wire [7:0]   pixel_green,
    output wire [7:0]   pixel_blue,
    output wire         vsync_out           // VSYNC output for GPIO
);

    // ========================================================================
    // Constants
    // ========================================================================

    localparam H_DISPLAY = 640;
    localparam V_DISPLAY = 480;
    localparam PREFETCH_THRESHOLD = 32;     // Start prefetch when FIFO has <32 words

    // ========================================================================
    // Scanline FIFO (crosses clock domains)
    // ========================================================================

    wire        fifo_wr_en;
    wire [31:0] fifo_wr_data;
    wire        fifo_wr_full;
    wire        fifo_rd_en;
    wire [31:0] fifo_rd_data;
    wire        fifo_rd_empty;
    wire [9:0]  fifo_rd_count;

    async_fifo #(
        .WIDTH(32),         // RGBA8888 pixels
        .DEPTH(1024)        // ~1.6 scanlines
    ) u_scanline_fifo (
        .wr_clk(clk_sram),
        .wr_rst_n(rst_n_sram),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .wr_almost_full(),

        .rd_clk(clk_pixel),
        .rd_rst_n(rst_n_pixel),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .rd_empty(fifo_rd_empty),
        .rd_count(fifo_rd_count)
    );

    // ========================================================================
    // SRAM Fetch State Machine (SRAM clock domain)
    // ========================================================================

    typedef enum logic [1:0] {
        FETCH_IDLE,
        FETCH_WAIT_ACK,
        FETCH_STORE
    } fetch_state_t;

    fetch_state_t fetch_state;

    reg [23:0] fetch_addr;      // Current fetch address (word-aligned)
    reg [23:0] fetch_line_end;  // End address of current line
    reg [9:0]  fetch_y;         // Current Y line being fetched

    // SRAM request logic
    // Display controller never writes to SRAM
    assign sram_we = 1'b0;

    // Tie wdata to rdata to avoid Yosys constant driver error
    // (This value is never used since we is always 0)
    assign sram_wdata = sram_rdata;

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            fetch_state <= FETCH_IDLE;
            sram_req <= 1'b0;
            sram_addr <= 24'b0;
            fetch_addr <= 24'b0;
            fetch_line_end <= 24'b0;
            fetch_y <= 10'b0;

        end else begin
            case (fetch_state)
                FETCH_IDLE: begin
                    // Check if we need to fetch more data
                    if (fifo_rd_count < PREFETCH_THRESHOLD && fetch_y < V_DISPLAY && sram_ready) begin
                        // Calculate address: base + (y * 640 + x) * 4 bytes / 4 bytes per word
                        // Address = base + y * 640 (in words)
                        fetch_addr <= {fb_display_base, 12'b0} + (fetch_y * 10'd640);
                        fetch_line_end <= {fb_display_base, 12'b0} + (fetch_y * 10'd640) + 10'd640;

                        // Issue read request
                        sram_req <= 1'b1;
                        sram_addr <= {fb_display_base, 12'b0} + (fetch_y * 10'd640);

                        fetch_state <= FETCH_WAIT_ACK;
                    end
                end

                FETCH_WAIT_ACK: begin
                    if (sram_ack) begin
                        sram_req <= 1'b0;
                        fetch_state <= FETCH_STORE;
                    end
                end

                FETCH_STORE: begin
                    // Store read data in FIFO
                    fetch_addr <= fetch_addr + 24'd1;

                    if (fetch_addr + 24'd1 >= fetch_line_end) begin
                        // Finished this line
                        fetch_y <= fetch_y + 10'd1;
                        fetch_state <= FETCH_IDLE;
                    end else if (!fifo_wr_full && sram_ready) begin
                        // Continue fetching this line
                        sram_req <= 1'b1;
                        sram_addr <= fetch_addr + 24'd1;
                        fetch_state <= FETCH_WAIT_ACK;
                    end else begin
                        // FIFO full or SRAM busy - wait
                        fetch_state <= FETCH_IDLE;
                    end
                end

                default: begin
                    fetch_state <= FETCH_IDLE;
                end
            endcase

            // Reset fetch address at frame start
            // This signal needs to be synchronized to SRAM clock domain
            // For now, we'll reset when fetch_y reaches end
            if (fetch_y >= V_DISPLAY) begin
                fetch_y <= 10'd0;
            end
        end
    end

    // FIFO write enable
    assign fifo_wr_en = (fetch_state == FETCH_STORE);
    assign fifo_wr_data = sram_rdata;

    // ========================================================================
    // Pixel Output (pixel clock domain)
    // ========================================================================

    // Read from FIFO when display is active
    assign fifo_rd_en = display_enable && !fifo_rd_empty;

    // Extract RGB from FIFO data (RGBA8888 format)
    assign pixel_red   = fifo_rd_data[23:16];
    assign pixel_green = fifo_rd_data[15:8];
    assign pixel_blue  = fifo_rd_data[7:0];

    // VSYNC output for GPIO (synchronized to pixel clock)
    assign vsync_out = frame_start;

endmodule
