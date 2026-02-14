`default_nettype none

// Display Controller - Framebuffer Scanout with Prefetch
// Fetches pixels from SRAM and feeds them to the display via scanline FIFO
// Operates entirely in the clk_core (100 MHz) domain with pixel_tick enable
// for 4:1 synchronous clock ratio to pixel clock

module display_controller (
    // Core clock domain (clk_core, 100 MHz)
    input  wire         clk_sram,
    input  wire         rst_n_sram,

    // Timing inputs (from timing generator, clk_pixel domain)
    // Synchronized internally since clk_pixel = clk_core / 4
    input  wire         display_enable,
    input  wire [9:0]   pixel_x,        // Reserved for future use (color grading LUT)
    input  wire [9:0]   pixel_y,        // Reserved for future use (color grading LUT)
    input  wire         frame_start,

    // Framebuffer configuration (core clock domain)
    input  wire [31:12] fb_display_base,    // Display framebuffer base address

    // SRAM interface (core clock domain)
    output reg          sram_req,
    output wire         sram_we,        // Always 0 (read-only)
    output reg  [23:0]  sram_addr,
    output wire [31:0]  sram_wdata,     // Always 0 (read-only)
    input  wire [31:0]  sram_rdata,
    input  wire         sram_ack,
    input  wire         sram_ready,

    // Pixel output (core clock domain, stable for 4 clk_core cycles)
    output reg  [7:0]   pixel_red,
    output reg  [7:0]   pixel_green,
    output reg  [7:0]   pixel_blue,
    output wire         vsync_out           // VSYNC output for GPIO
);

    // ========================================================================
    // Constants
    // ========================================================================

    localparam H_DISPLAY = 640;
    localparam V_DISPLAY = 480;
    localparam PREFETCH_THRESHOLD = 32;     // Start prefetch when FIFO has <32 words

    // ========================================================================
    // Pixel Tick Generation (4:1 clock enable)
    // ========================================================================

    // Free-running 2-bit counter generates pixel_tick at clk_core / 4 rate.
    // This matches the clk_pixel frequency for synchronous 4:1 operation.

    reg [1:0] pixel_phase;
    wire pixel_tick = (pixel_phase == 2'd0);

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            pixel_phase <= 2'd0;
        end else begin
            pixel_phase <= pixel_phase + 2'd1;
        end
    end

    // ========================================================================
    // Timing Input Synchronization
    // ========================================================================

    // Timing generator runs at clk_pixel = clk_core / 4 (synchronous).
    // Single-stage capture at pixel_tick rate safely samples these signals
    // since the clocks share a synchronous integer ratio from the same PLL.

    reg display_enable_sync;
    reg frame_start_sync;

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            display_enable_sync <= 1'b0;
            frame_start_sync <= 1'b0;
        end else if (pixel_tick) begin
            display_enable_sync <= display_enable;
            frame_start_sync <= frame_start;
        end
    end

    // ========================================================================
    // Scanline FIFO (synchronous, single clock domain)
    // ========================================================================

    // Replaces async_fifo: no gray-code CDC needed since write and read
    // share the same clk_core clock. Reads are gated by pixel_tick.

    wire        fifo_wr_en;
    wire [15:0] fifo_wr_data;
    wire        fifo_wr_full;
    wire        fifo_rd_en;
    wire [15:0] fifo_rd_data;
    wire        fifo_rd_empty;
    wire [10:0] fifo_rd_count;

    sync_fifo #(
        .WIDTH(16),         // RGB565 pixels (16-bit color)
        .DEPTH(1024)        // ~1.6 scanlines
    ) u_scanline_fifo (
        .clk(clk_sram),
        .rst_n(rst_n_sram),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .rd_empty(fifo_rd_empty),
        .rd_count(fifo_rd_count)
    );

    // ========================================================================
    // SRAM Fetch State Machine (core clock domain)
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
                    // fifo_rd_count is in same clock domain (no CDC delay)
                    if (fifo_rd_count < PREFETCH_THRESHOLD && fetch_y < V_DISPLAY && sram_ready) begin
                        // Calculate address: base + (y * 640) pixels
                        // RGB565 stored in lower 16 bits of 32-bit words (upper 16 bits unused)
                        // Address = base + y * 640 (in 32-bit words, 1 pixel per word)
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
    assign fifo_wr_data = sram_rdata[15:0];

    // ========================================================================
    // Pixel Output (core clock domain, gated by pixel_tick)
    // ========================================================================

    // Read from FIFO once per pixel_tick when display is active
    assign fifo_rd_en = pixel_tick && display_enable_sync && !fifo_rd_empty;

    // Extract RGB from FIFO data (RGB565 format) and expand to RGB888
    // RGB565: [15:11]=R5, [10:5]=G6, [4:0]=B5
    // Expand to 8-bit by replicating MSBs to minimize color banding
    // Registered output: updates once per pixel_tick, stable for 4 clk_core cycles
    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            pixel_red <= 8'd0;
            pixel_green <= 8'd0;
            pixel_blue <= 8'd0;
        end else if (pixel_tick) begin
            if (display_enable_sync && !fifo_rd_empty) begin
                pixel_red   <= {fifo_rd_data[15:11], fifo_rd_data[15:13]};  // R5->R8
                pixel_green <= {fifo_rd_data[10:5],  fifo_rd_data[10:9]};   // G6->G8
                pixel_blue  <= {fifo_rd_data[4:0],   fifo_rd_data[4:2]};    // B5->B8
            end else begin
                // Outside active display area or FIFO empty: output black
                pixel_red <= 8'd0;
                pixel_green <= 8'd0;
                pixel_blue <= 8'd0;
            end
        end
    end

    // VSYNC output for GPIO (synchronized to core clock domain)
    assign vsync_out = frame_start_sync;

endmodule

`default_nettype wire
