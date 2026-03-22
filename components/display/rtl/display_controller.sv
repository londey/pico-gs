`default_nettype none

// Spec-ref: unit_008_display_controller.md `11beeabcaf509200` 2026-02-28

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
//
// Horizontal scaling: a Bresenham nearest-neighbor accumulator maps
// source_width (1 << fb_display_width_log2) source pixels to 640 DVI output
// pixels (UNIT-008, REQ-006.01).
//
// Line doubling: when fb_line_double=1, each source row is output twice
// without re-reading SDRAM for the repeated row (UNIT-008, REQ-006.01).

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

    // Display framebuffer surface dimensions (from FB_DISPLAY register via UNIT-003)
    input  wire [3:0]   fb_display_width_log2, // log2(source width), e.g. 9 for 512
    input  wire         fb_line_double,         // 1 = repeat each source row for 2 output rows

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

    // H_DISPLAY is the DVI output width (always 640 pixels); used only in
    // the timing/scaler domain, NOT in the prefetch word count.
    localparam H_DISPLAY = 640;
    localparam V_DISPLAY = 480;
    localparam PREFETCH_THRESHOLD = 32;     // Start prefetch when FIFO has <32 words
    localparam [7:0] BURST_MAX = 8'd128;   // 16-bit SRAM words per burst (yields 64 pixels)

    // ========================================================================
    // Source Width Derivation
    // ========================================================================

    // Source framebuffer width = 1 << fb_display_width_log2 (e.g. 512 for log2=9)
    wire [9:0] source_width = 10'd1 << fb_display_width_log2;

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
    // Display Enable Edge Detector (for scanline start)
    // ========================================================================

    // Detect rising edge of display_enable_sync to initialize scaler at
    // the start of each output scanline.
    reg display_enable_prev;
    wire display_enable_rise = display_enable_sync && !display_enable_prev;

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            display_enable_prev <= 1'b0;
        end else if (pixel_tick) begin
            display_enable_prev <= display_enable_sync;
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
        .DEPTH(1024)        // ~2 scanlines at 512-wide source
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

    reg [9:0]  pixels_fetched;      // Pixels fetched on current scanline (0..source_width)
    reg [9:0]  fetch_y;             // Current Y line being fetched (0..479)
    reg        burst_word_toggle;   // 0=pixel data (even SRAM addr), 1=padding (odd)

    // LINE_DOUBLE state: tracks whether current output row is the second
    // (repeated) emission of the same source row
    reg        line_double_second;

    // Display controller never writes to SRAM
    assign sram_we = 1'b0;

    // Tie wdata to rdata to avoid Yosys constant driver error
    // (This value is never used since we is always 0)
    assign sram_wdata = sram_rdata;

    // Pixels remaining on current source scanline
    wire [9:0] pixels_left = source_width - pixels_fetched;

    // Burst length for next request: 128 (64 pixels) or 2*remaining if fewer left
    // burst_len is in 16-bit SRAM words; 2 words per pixel (low=data, high=padding)
    wire [7:0] next_burst_len = (pixels_left >= 10'd64)
                               ? BURST_MAX
                               : {pixels_left[6:0], 1'b0};

    // Number of pixels the current burst will produce (registered burst_len / 2)
    wire [9:0] burst_pixels = {3'b0, sram_burst_len[7:1]};

    // Source row index: when LINE_DOUBLE=1, use fetch_y >> 1
    wire [9:0] source_row = fb_line_double ? {1'b0, fetch_y[9:1]} : fetch_y;

    // 32-bit word address for the next burst start
    // base + source_row * source_width + pixels already fetched on this line
    // source_width = 1 << fb_display_width_log2, so source_row * source_width
    // is simply source_row << fb_display_width_log2 — avoids hardware multiplier
    wire [22:0] y_times_source_width = {13'b0, source_row} << fb_display_width_log2;
    wire [22:0] fetch_word_addr = {fb_display_base[22:12], 12'b0}
                                + y_times_source_width
                                + {13'b0, pixels_fetched};

    // Prefetch FSM — state register (always_ff)
    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            prefetch_state <= PREFETCH_IDLE;
        end else begin
            prefetch_state <= next_prefetch_state;
        end
    end

    // LINE_DOUBLE skip condition: reuse FIFO contents for second output row
    wire line_double_skip = fb_line_double && line_double_second;

    // Prefetch FSM — next-state logic (always_comb)
    always_comb begin
        // Default: hold current state
        next_prefetch_state = prefetch_state;

        case (prefetch_state)
            PREFETCH_IDLE: begin
                if (frame_start_edge) begin
                    // New frame: stay IDLE while counters reset
                    next_prefetch_state = PREFETCH_IDLE;
                end else if (line_double_skip &&
                             pixels_fetched == 10'd0 &&
                             fetch_y < V_DISPLAY) begin
                    // LINE_DOUBLE second row: skip SDRAM read, reuse FIFO
                    next_prefetch_state = PREFETCH_DONE;
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
                    if (pixels_fetched + burst_pixels >= source_width) begin
                        // Source scanline complete
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
            line_double_second <= 1'b0;

        end else begin
            case (prefetch_state)
                PREFETCH_IDLE: begin
                    sram_req       <= 1'b0;
                    sram_burst_len <= 8'b0;

                    if (frame_start_edge) begin
                        // New frame: reset scanline counter and line-double state
                        fetch_y            <= 10'd0;
                        pixels_fetched     <= 10'd0;
                        line_double_second <= 1'b0;

                    end else if (line_double_skip &&
                                 pixels_fetched == 10'd0 &&
                                 fetch_y < V_DISPLAY) begin
                        // LINE_DOUBLE second row: skip SDRAM read
                        // No SRAM request needed; transition to DONE handled
                        // by next-state logic above

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
                    // Advance to next output scanline
                    fetch_y        <= fetch_y + 10'd1;
                    pixels_fetched <= 10'd0;

                    // LINE_DOUBLE toggle: after a successful SDRAM read
                    // (first emission), set line_double_second=1 so the next
                    // output row reuses the FIFO contents. After the skip
                    // (second emission), clear it back to 0.
                    if (fb_line_double) begin
                        line_double_second <= ~line_double_second;
                    end else begin
                        line_double_second <= 1'b0;
                    end
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
    // Horizontal Bresenham Scaler + Pixel Output (pixel_tick domain)
    // ========================================================================
    //
    // Maps source_width source pixels to H_DISPLAY (640) output pixels using
    // a Bresenham nearest-neighbor accumulator (UNIT-008). The scaler controls
    // FIFO read advancement: the FIFO read pointer advances only when the
    // accumulator overflows, not on every output pixel.
    //
    // Pipeline: sync_fifo has 1-clock-cycle read latency (registered output).
    // Since pixel_tick occurs every 4 clk cycles, fifo_rd_data is stable and
    // valid by the next pixel_tick after rd_en was asserted.
    //
    // The original (pre-scaler) code always reads FIFO every pixel_tick, and
    // uses fifo_rd_data which reflects the *previous* tick's read (1-cycle
    // latency). This design preserves that pipeline: the Bresenham accumulator
    // decides at tick T whether the NEXT output pixel needs a new source pixel,
    // triggering the FIFO read at tick T so data is ready at tick T+1.

    reg [9:0]  h_accum;             // Bresenham accumulator
    reg [8:0]  h_src_pos;           // Current source pixel index (0..source_width-1)

    // The Bresenham accumulator determines whether to advance the FIFO read
    // pointer for the NEXT output pixel. fifo_rd_en is asserted when:
    //  (a) display_enable_rise: priming read for first source pixel
    //  (b) h_accum_overflow: scaler needs next source pixel for upcoming tick
    //
    // Next-state for Bresenham accumulator (combinational)
    wire [10:0] h_accum_next_wide = {1'b0, h_accum} + {1'b0, source_width};
    wire        h_accum_overflow  = (h_accum_next_wide >= H_DISPLAY[10:0]);
    wire [9:0]  h_accum_next      = h_accum_overflow
                                   ? (h_accum_next_wide[9:0] - H_DISPLAY[9:0])
                                   : h_accum_next_wide[9:0];

    // FIFO read control:
    // - At scanline start (display_enable_rise): prime first pixel read
    // - During active display: read when accumulator overflows (need next pixel)
    //   The read triggered NOW provides data for the NEXT pixel_tick.
    assign fifo_rd_en = pixel_tick && display_enable_sync && !fifo_rd_empty
                        && (display_enable_rise || h_accum_overflow);

    always_ff @(posedge clk_sram or negedge rst_n_sram) begin
        if (!rst_n_sram) begin
            h_accum        <= 10'd0;
            h_src_pos      <= 9'd0;
            pixel_red      <= 8'd0;
            pixel_green    <= 8'd0;
            pixel_blue     <= 8'd0;
        end else if (pixel_tick) begin
            if (display_enable_rise) begin
                // Scanline start: initialize Bresenham accumulator with
                // mid-point bias for symmetric rounding (UNIT-008)
                h_accum   <= source_width >> 1;
                h_src_pos <= 9'd0;
                // First FIFO read is primed by fifo_rd_en (display_enable_rise
                // term). fifo_rd_data will contain src[0] at next pixel_tick.
                // Output black during this priming tick (same as original code).
                pixel_red   <= 8'd0;
                pixel_green <= 8'd0;
                pixel_blue  <= 8'd0;

            end else if (display_enable_sync && !fifo_rd_empty) begin
                // Active display: output fifo_rd_data as the current pixel.
                //
                // fifo_rd_data contains the result of the FIFO read triggered
                // at the PREVIOUS pixel_tick (1-clk latency, already settled).
                // When the FIFO was NOT read (scaler repeating a pixel),
                // fifo_rd_data holds its previous value (FIFO output register
                // only changes on rd_en). This gives us implicit pixel hold
                // for the scaler repeat case without a separate register.

                // RGB565 to RGB888 expansion
                pixel_red   <= {fifo_rd_data[15:11], fifo_rd_data[15:13]};
                pixel_green <= {fifo_rd_data[10:5],  fifo_rd_data[10:9]};
                pixel_blue  <= {fifo_rd_data[4:0],   fifo_rd_data[4:2]};

                // Advance Bresenham accumulator for the next output pixel.
                // If overflow, the fifo_rd_en combinational logic triggers a
                // FIFO read THIS tick, providing data for the NEXT tick.
                h_accum <= h_accum_next;
                if (h_accum_overflow) begin
                    h_src_pos <= h_src_pos + 9'd1;
                end

            end else begin
                // Outside active display area or FIFO empty: output black
                pixel_red   <= 8'd0;
                pixel_green <= 8'd0;
                pixel_blue  <= 8'd0;
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
