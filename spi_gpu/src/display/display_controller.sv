`default_nettype none

// Display Controller - Framebuffer Scanout with Burst Prefetch
// Fetches pixels from SRAM using burst reads and feeds them to the display
// via scanline FIFO.  Operates entirely in the clk_core (100 MHz) domain
// with pixel_tick enable for 4:1 synchronous clock ratio to pixel clock.
//
// Burst mode: the prefetch FSM issues burst read requests (128 x 16-bit SRAM
// words per burst = 64 pixels) to the arbiter.  Since framebuffer pixels are
// stored as RGB565 in the lower 16 bits of 32-bit SRAM words, each 32-bit word
// occupies two sequential 16-bit SRAM addresses.  The FSM filters out the
// unused upper-half words using a toggle bit, pushing only pixel data to the
// scanline FIFO.

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
    // Only bits [22:12] used — upper bits exceed 24-bit SRAM address space
    input  wire [31:12] fb_display_base,    // Display framebuffer base address

    // SRAM interface — single-word (core clock domain)
    output reg          sram_req,
    output wire         sram_we,        // Always 0 (read-only)
    output reg  [23:0]  sram_addr,
    output wire [31:0]  sram_wdata,     // Always 0 (read-only)
    input  wire [31:0]  sram_rdata,
    input  wire         sram_ack,
    input  wire         sram_ready,

    // SRAM interface — burst (core clock domain)
    output reg  [7:0]   sram_burst_len,
    input  wire [15:0]  sram_burst_rdata,
    input  wire         sram_burst_data_valid,

    // Pixel output (core clock domain, stable for 4 clk_core cycles)
    output reg  [7:0]   pixel_red,
    output reg  [7:0]   pixel_green,
    output reg  [7:0]   pixel_blue,
    output wire         vsync_out           // VSYNC output for GPIO
);

    // ========================================================================
    // Unused Signal Declarations
    // ========================================================================

    // pixel_x and pixel_y reserved for future color grading LUT
    wire _unused_pixel_x = |pixel_x;
    wire _unused_pixel_y = |pixel_y;

    // fb_display_base bits [31:23] exceed 24-bit SRAM address space
    wire [8:0] _unused_fb_display_base_high = fb_display_base[31:23];

    // ========================================================================
    // Constants
    // ========================================================================

    localparam H_DISPLAY = 640;
    localparam V_DISPLAY = 480;
    localparam PREFETCH_THRESHOLD = 32;     // Start prefetch when FIFO has <32 words
    localparam [7:0] BURST_MAX = 8'd128;   // 16-bit SRAM words per burst (yields 64 pixels)

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
    // Frame Start Edge Detector
    // ========================================================================

    reg frame_start_prev;
    wire frame_start_edge = frame_start_sync && !frame_start_prev;

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            frame_start_prev <= 1'b0;
        end else if (pixel_tick) begin
            frame_start_prev <= frame_start_sync;
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
    // SRAM Burst Prefetch State Machine (core clock domain)
    // ========================================================================

    typedef enum logic [1:0] {
        PREFETCH_IDLE,
        PREFETCH_BURST,
        PREFETCH_DONE
    } prefetch_state_t;

    prefetch_state_t prefetch_state;
    prefetch_state_t next_prefetch_state;

    reg [9:0]  pixels_fetched;      // Pixels fetched on current scanline (0..640)
    reg [9:0]  fetch_y;             // Current Y line being fetched (0..479)
    reg        burst_word_toggle;   // 0=pixel data (even SRAM addr), 1=padding (odd)

    // Display controller never writes to SRAM
    assign sram_we = 1'b0;

    // Tie wdata to rdata to avoid Yosys constant driver error
    // (This value is never used since we is always 0)
    assign sram_wdata = sram_rdata;

    // Pixels remaining on current scanline
    wire [9:0] pixels_left = H_DISPLAY[9:0] - pixels_fetched;

    // Burst length for next request: 128 (64 pixels) or 2*remaining if fewer left
    // burst_len is in 16-bit SRAM words; 2 words per pixel (low=data, high=padding)
    wire [7:0] next_burst_len = (pixels_left >= 10'd64)
                               ? BURST_MAX
                               : {pixels_left[6:0], 1'b0};

    // Number of pixels the current burst will produce (registered burst_len / 2)
    wire [9:0] burst_pixels = {3'b0, sram_burst_len[7:1]};

    // 32-bit word address for the next burst start
    // base + y*640 + pixels already fetched on this line
    // Only 23 bits needed: {fetch_word_addr, 1'b0} produces the 24-bit SRAM address
    wire [22:0] fetch_word_addr = {fb_display_base[22:12], 12'b0}
                                + ({13'b0, fetch_y} * 23'd640)
                                + {13'b0, pixels_fetched};

    // Prefetch FSM — state register (always_ff)
    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            prefetch_state <= PREFETCH_IDLE;
        end else begin
            prefetch_state <= next_prefetch_state;
        end
    end

    // Prefetch FSM — next-state logic (always_comb)
    always_comb begin
        // Default: hold current state
        next_prefetch_state = prefetch_state;

        case (prefetch_state)
            PREFETCH_IDLE: begin
                if (frame_start_edge) begin
                    // New frame: stay IDLE while counters reset
                    next_prefetch_state = PREFETCH_IDLE;
                end else if (fifo_rd_count < PREFETCH_THRESHOLD &&
                             fetch_y < V_DISPLAY &&
                             pixels_left > 10'd0 &&
                             sram_ready) begin
                    // FIFO low and pixels remaining — issue burst
                    next_prefetch_state = PREFETCH_BURST;
                end
            end

            PREFETCH_BURST: begin
                if (sram_ack) begin
                    if (pixels_fetched + burst_pixels >= H_DISPLAY[9:0]) begin
                        // Scanline complete
                        next_prefetch_state = PREFETCH_DONE;
                    end else begin
                        // More pixels needed — return to idle for next burst
                        next_prefetch_state = PREFETCH_IDLE;
                    end
                end
            end

            PREFETCH_DONE: begin
                // Advance to next scanline
                next_prefetch_state = PREFETCH_IDLE;
            end

            default: begin
                next_prefetch_state = PREFETCH_IDLE;
            end
        endcase
    end

    // Prefetch FSM — datapath (always_ff)
    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            sram_req          <= 1'b0;
            sram_addr         <= 24'b0;
            sram_burst_len    <= 8'b0;
            pixels_fetched    <= 10'b0;
            fetch_y           <= 10'b0;
            burst_word_toggle <= 1'b0;

        end else begin
            case (prefetch_state)
                PREFETCH_IDLE: begin
                    sram_req       <= 1'b0;
                    sram_burst_len <= 8'b0;

                    if (frame_start_edge) begin
                        // New frame: reset scanline counter
                        fetch_y        <= 10'd0;
                        pixels_fetched <= 10'd0;

                    end else if (fifo_rd_count < PREFETCH_THRESHOLD &&
                                 fetch_y < V_DISPLAY &&
                                 pixels_left > 10'd0 &&
                                 sram_ready) begin
                        // Issue burst read request
                        // Convert 32-bit word addr to 16-bit SRAM addr (<<1)
                        sram_addr         <= {fetch_word_addr[22:0], 1'b0};
                        sram_burst_len    <= next_burst_len;
                        sram_req          <= 1'b1;
                        burst_word_toggle <= 1'b0;
                    end
                end

                PREFETCH_BURST: begin
                    // Toggle even/odd tracking on each burst data beat
                    if (sram_burst_data_valid) begin
                        burst_word_toggle <= ~burst_word_toggle;
                    end

                    // Burst complete (ack from arbiter)
                    if (sram_ack) begin
                        sram_req       <= 1'b0;
                        sram_burst_len <= 8'b0;

                        // Update pixel count for this scanline
                        pixels_fetched <= pixels_fetched + burst_pixels;
                    end
                end

                PREFETCH_DONE: begin
                    // Advance to next scanline
                    fetch_y        <= fetch_y + 10'd1;
                    pixels_fetched <= 10'd0;
                end

                default: begin
                    // No datapath updates in default state
                end
            endcase
        end
    end

    // FIFO write: push pixel data on even-addressed burst beats only
    // Even SRAM address = low 16 bits of 32-bit word = RGB565 pixel data
    // Odd SRAM address = high 16 bits of 32-bit word = unused padding
    assign fifo_wr_en = sram_burst_data_valid
                        && !burst_word_toggle
                        && (prefetch_state == PREFETCH_BURST)
                        && !fifo_wr_full;
    assign fifo_wr_data = sram_burst_rdata;

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

    // ========================================================================
    // LUT DMA Controller (future)
    // ========================================================================
    // When color_grade_lut.sv and LUT DMA are implemented (UNIT-008 v9.0+),
    // the DMA controller should issue burst reads with burst_len=192 for the
    // 384-byte (192 x 16-bit word) LUT transfer during vblank.  This replaces
    // 192 individual single-word SRAM requests with a single burst request,
    // reducing transfer time from ~1.92 us to ~1.0 us.
    // See UNIT-008 "LUT DMA Burst Support (v11.0)" for the full protocol.

endmodule

`default_nettype wire
