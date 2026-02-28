`default_nettype none

// ICEpi SPI GPU - Top Level Module
// Version 2.0 - Gouraud Shading Implementation (Texture support deferred)
//
// This module integrates all GPU subsystems:
// - Clock generation (PLL)
// - Reset synchronization
// - SPI interface
// - Memory subsystem (SDRAM controller and arbiter)
// - Display pipeline (timing, scanline FIFO, DVI output)
// - Rendering pipeline (rasterizer, interpolator, Z-buffer)

module gpu_top (
    // ==== Clock and Reset ====
    input  wire         clk_50,             // 50 MHz board oscillator
    input  wire         rst_n,              // Active-low reset

    // ==== SPI Interface (from RP2350) ====
    input  wire         spi_sck,            // SPI clock (up to 40 MHz)
    input  wire         spi_mosi,           // SPI data in
    output wire         spi_miso,           // SPI data out
    input  wire         spi_cs_n,           // SPI chip select (active-low)

    // ==== GPIO Status Outputs (to RP2350) ====
    output wire         gpio_cmd_full,      // Command buffer near-full warning
    output wire         gpio_cmd_empty,     // Command buffer empty (safe to read registers)
    output wire         gpio_vsync,         // Vertical sync pulse

    // ==== SDRAM Interface (32MB W9825G6KH-6, 16-bit synchronous) ====
    output wire         sdram_clk,          // 100 MHz clock, 90-degree phase shift from clk_core
    output wire         sdram_cke,          // Clock enable (active high)
    output wire         sdram_csn,          // Chip select (active low)
    output wire         sdram_rasn,         // Row address strobe (active low)
    output wire         sdram_casn,         // Column address strobe (active low)
    output wire         sdram_wen,          // Write enable (active low)
    output wire [1:0]   sdram_ba,           // Bank address
    output wire [12:0]  sdram_a,            // Address bus (row: A[12:0], column: A[8:0])
    inout  wire [15:0]  sdram_dq,           // Bidirectional data bus
    output wire [1:0]   sdram_dqm,          // Data mask (upper/lower byte)

    // ==== DVI/HDMI Output (TMDS differential) ====
    output wire [2:0]   tmds_data_p,        // TMDS data channels (positive)
    output wire [2:0]   tmds_data_n,        // TMDS data channels (negative)
    output wire         tmds_clk_p,         // TMDS clock (positive)
    output wire         tmds_clk_n          // TMDS clock (negative)
);

    // ========================================================================
    // Clock and Reset Infrastructure
    // ========================================================================

    // Internal clock signals
    wire clk_core;          // 100 MHz unified GPU core/SDRAM clock
    wire clk_pixel;         // 25.000 MHz pixel clock (clk_core / 4)
    wire clk_tmds;          // 250.0 MHz TMDS bit clock (10x pixel clock)
    wire clk_sdram;         // 100 MHz SDRAM chip clock, 90-degree phase shift
    wire pll_locked;        // PLL lock indicator

    // Synchronized reset signals for each clock domain
    wire rst_n_core;        // Reset synchronized to clk_core
    wire rst_n_pixel;       // Reset synchronized to clk_pixel
    wire rst_n_tmds;        // Reset synchronized to clk_tmds

    // PLL instantiation
    pll_core u_pll (
        .clk_50_in(clk_50),
        .rst_n(rst_n),
        .clk_core(clk_core),
        .clk_pixel(clk_pixel),
        .clk_tmds(clk_tmds),
        .clk_sdram(clk_sdram),
        .pll_locked(pll_locked)
    );

    // Route SDRAM clock directly from PLL to top-level output
    assign sdram_clk = clk_sdram;

    // Reset synchronizers for each clock domain
    reset_sync u_reset_sync_core (
        .clk(clk_core),
        .rst_n_async(rst_n),
        .pll_locked(pll_locked),
        .rst_n_sync(rst_n_core)
    );

    reset_sync u_reset_sync_pixel (
        .clk(clk_pixel),
        .rst_n_async(rst_n),
        .pll_locked(pll_locked),
        .rst_n_sync(rst_n_pixel)
    );

    reset_sync u_reset_sync_tmds (
        .clk(clk_tmds),
        .rst_n_async(rst_n),
        .pll_locked(pll_locked),
        .rst_n_sync(rst_n_tmds)
    );

    // ========================================================================
    // SPI Interface (Phase 2 - Implemented)
    // ========================================================================

    // SPI slave interface signals
    wire        spi_valid;
    wire        spi_rw;
    wire [6:0]  spi_addr;
    wire [63:0] spi_wdata;
    wire [63:0] spi_rdata;

    // Command FIFO signals
    wire        fifo_wr_en;
    wire [71:0] fifo_wr_data;
    wire        fifo_wr_full;
    wire        fifo_wr_almost_full /* verilator public */;
    wire        fifo_rd_en;
    wire [71:0] fifo_rd_data;
    wire        fifo_rd_empty;
    wire [9:0]  fifo_rd_count;

    // Register file signals
    wire        reg_cmd_valid;
    wire        reg_cmd_rw;
    wire [6:0]  reg_cmd_addr;
    wire [63:0] reg_cmd_wdata;
    wire [63:0] reg_cmd_rdata;

    // Triangle output signals (from register_file vertex state machine)
    wire        tri_valid /* verilator public */;
    wire [2:0][15:0] tri_x;
    wire [2:0][15:0] tri_y;
    wire [2:0][15:0] tri_z;
    wire [2:0][15:0] tri_q;
    wire [2:0][31:0] tri_color0;    // Diffuse RGBA8888 per vertex
    wire [2:0][31:0] tri_color1;    // Specular RGBA8888 per vertex
    wire [2:0][31:0] tri_uv0;
    wire [2:0][31:0] tri_uv1;

    // Rectangle output
    wire rect_valid;

    // Rendering mode signals (from RENDER_MODE register)
    wire        mode_gouraud;
    wire        mode_z_test;
    wire        mode_z_write;
    wire        mode_color_write;
    wire [1:0]  mode_cull;
    wire [2:0]  mode_alpha_blend;
    wire        mode_dither_en;
    wire [1:0]  mode_dither_pattern;
    wire [2:0]  mode_z_compare;
    wire        mode_stipple_en;
    wire [1:0]  mode_alpha_test;
    wire [7:0]  mode_alpha_ref;

    // Depth range clipping
    wire [15:0] z_range_min;
    wire [15:0] z_range_max;

    // Stipple pattern
    wire [63:0] stipple_pattern;

    // Framebuffer configuration (FB_CONFIG)
    wire [15:0] fb_color_base;      // Color buffer base (x512 byte addr)
    wire [15:0] fb_z_base;          // Z buffer base (x512 byte addr)
    wire [3:0]  fb_width_log2;
    wire [3:0]  fb_height_log2;

    // Scissor rectangle (FB_CONTROL)
    wire [9:0]  scissor_x;
    wire [9:0]  scissor_y;
    wire [9:0]  scissor_width;
    wire [9:0]  scissor_height;

    // Memory fill (MEM_FILL)
    wire        mem_fill_trigger;
    wire [15:0] mem_fill_base;
    wire [15:0] mem_fill_value;
    wire [19:0] mem_fill_count;

    // Display configuration (FB_DISPLAY)
    wire [15:0] fb_lut_addr;
    wire [15:0] fb_display_addr;
    wire [3:0]  fb_display_width_log2;
    wire        fb_line_double;
    wire        color_grade_enable;

    // Color combiner
    wire [63:0] cc_mode;
    wire [63:0] const_color;

    // Barycentric area normalization (AREA_SETUP)
    wire [15:0] area_inv;
    wire [3:0]  area_shift;

    // Texture configuration
    wire [63:0] tex0_cfg;
    wire [63:0] tex1_cfg;
    wire        tex0_cache_inv;
    wire        tex1_cache_inv;

    // Memory access (MEM_ADDR / MEM_DATA)
    wire [63:0] mem_addr_out;
    wire [63:0] mem_data_out;
    wire        mem_data_wr;
    wire        mem_data_rd;

    // Timestamp SDRAM write signals (register_file → arbiter port 3)
    wire        ts_mem_wr;
    wire [22:0] ts_mem_addr;
    wire [31:0] ts_mem_data;

    // Status signals
    wire gpu_busy;
    wire vblank;

    // SPI Slave instantiation
    spi_slave u_spi_slave (
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .sys_clk(clk_core),
        .sys_rst_n(rst_n_core),
        .valid(spi_valid),
        .rw(spi_rw),
        .addr(spi_addr),
        .wdata(spi_wdata),
        .rdata(spi_rdata)
    );

    // Pack SPI transaction into FIFO format (synthesis) or sim injection (simulation)
    `ifdef SIM_DIRECT_CMD
        // Sim-only: direct command injection bypasses UNIT-001 (see UNIT-002, UNIT-037)
        // Signals driven by the Verilator C++ wrapper (gpu_sim.cpp)
        /* verilator lint_off UNDRIVEN */
        logic        sim_cmd_valid  /* verilator public */;  // Sim write enable
        logic        sim_cmd_rw     /* verilator public */;  // R/W flag (matches INT-012 bit 71)
        logic [6:0]  sim_cmd_addr   /* verilator public */;  // Register address (matches INT-012 bits 70:64)
        logic [63:0] sim_cmd_wdata  /* verilator public */;  // Write data (matches INT-012 bits 63:0)
        /* verilator lint_on UNDRIVEN */
        assign fifo_wr_en   = sim_cmd_valid;
        assign fifo_wr_data = {sim_cmd_rw, sim_cmd_addr, sim_cmd_wdata};
    `else
        assign fifo_wr_en   = spi_valid;
        assign fifo_wr_data = {spi_rw, spi_addr, spi_wdata};
    `endif

    // Command FIFO instantiation (with boot pre-population)
    command_fifo u_cmd_fifo (
        .wr_clk(clk_core),
        .wr_rst_n(rst_n_core),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .wr_almost_full(fifo_wr_almost_full),
        .rd_clk(clk_core),
        .rd_rst_n(rst_n_core),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data),
        .rd_empty(fifo_rd_empty),
        .rd_count(fifo_rd_count)
    );

    // Unpack FIFO data to register interface
    assign reg_cmd_valid = !fifo_rd_empty;
    assign reg_cmd_rw = fifo_rd_data[71];
    assign reg_cmd_addr = fifo_rd_data[70:64];
    assign reg_cmd_wdata = fifo_rd_data[63:0];
    assign fifo_rd_en = !fifo_rd_empty && !gpu_busy;  // Read when data available and GPU not busy

    // Register File instantiation (INT-010 v10.0)
    register_file u_register_file (
        .clk(clk_core),
        .rst_n(rst_n_core),

        // Register interface (from command FIFO)
        .cmd_valid(reg_cmd_valid),
        .cmd_rw(reg_cmd_rw),
        .cmd_addr(reg_cmd_addr),
        .cmd_wdata(reg_cmd_wdata),
        .cmd_rdata(reg_cmd_rdata),

        // Triangle output
        .tri_valid(tri_valid),
        .tri_x(tri_x),
        .tri_y(tri_y),
        .tri_z(tri_z),
        .tri_q(tri_q),
        .tri_color0(tri_color0),
        .tri_color1(tri_color1),
        .tri_uv0(tri_uv0),
        .tri_uv1(tri_uv1),

        // Barycentric area normalization
        .area_inv(area_inv),
        .area_shift(area_shift),

        // Rectangle output
        .rect_valid(rect_valid),

        // Rendering mode flags
        .mode_gouraud(mode_gouraud),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .mode_cull(mode_cull),
        .mode_alpha_blend(mode_alpha_blend),
        .mode_dither_en(mode_dither_en),
        .mode_dither_pattern(mode_dither_pattern),
        .mode_z_compare(mode_z_compare),
        .mode_stipple_en(mode_stipple_en),
        .mode_alpha_test(mode_alpha_test),
        .mode_alpha_ref(mode_alpha_ref),

        // Depth range
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),

        // Stipple
        .stipple_pattern(stipple_pattern),

        // Framebuffer configuration
        .fb_color_base(fb_color_base),
        .fb_z_base(fb_z_base),
        .fb_width_log2(fb_width_log2),
        .fb_height_log2(fb_height_log2),

        // Scissor rectangle
        .scissor_x(scissor_x),
        .scissor_y(scissor_y),
        .scissor_width(scissor_width),
        .scissor_height(scissor_height),

        // Memory fill
        .mem_fill_trigger(mem_fill_trigger),
        .mem_fill_base(mem_fill_base),
        .mem_fill_value(mem_fill_value),
        .mem_fill_count(mem_fill_count),

        // Display configuration
        .fb_lut_addr(fb_lut_addr),
        .fb_display_addr(fb_display_addr),
        .fb_display_width_log2(fb_display_width_log2),
        .fb_line_double(fb_line_double),
        .color_grade_enable(color_grade_enable),

        // Color combiner
        .cc_mode(cc_mode),
        .const_color(const_color),

        // Texture configuration
        .tex0_cfg(tex0_cfg),
        .tex1_cfg(tex1_cfg),
        .tex0_cache_inv(tex0_cache_inv),
        .tex1_cache_inv(tex1_cache_inv),

        // Memory access
        .mem_addr_out(mem_addr_out),
        .mem_data_out(mem_data_out),
        .mem_data_wr(mem_data_wr),
        .mem_data_rd(mem_data_rd),
        .mem_data_in(64'h0),           // TODO: connect to SDRAM read path

        // Timestamp SDRAM write
        .ts_mem_wr(ts_mem_wr),
        .ts_mem_addr(ts_mem_addr),
        .ts_mem_data(ts_mem_data),

        // Status inputs
        .gpu_busy(gpu_busy),
        .vblank(vblank),
        .vsync_edge(disp_frame_start), // Use frame_start as vsync edge proxy
        .fifo_depth(fifo_rd_count[7:0])
    );

    // Route register file read data back to SPI slave for read transactions
    assign spi_rdata = reg_cmd_rdata;

    // GPIO outputs
    assign gpio_cmd_full = fifo_wr_almost_full;
    assign gpio_cmd_empty = fifo_rd_empty;

    // Stall the command FIFO when the rasterizer cannot accept a new triangle.
    // This prevents VERTEX_KICK pulses from being lost while the rasterizer is
    // busy processing the previous triangle.
    assign gpu_busy = !rast_ready;
    // vblank is assigned from display timing generator (see display section)

    // ========================================================================
    // Memory Subsystem (Phase 3 - SDRAM)
    // ========================================================================

    // Arbiter port signals
    wire        arb_port0_req;
    wire        arb_port0_we;
    wire [23:0] arb_port0_addr;
    wire [31:0] arb_port0_wdata;
    wire [7:0]  arb_port0_burst_len;
    wire [31:0] arb_port0_rdata;
    wire [15:0] arb_port0_burst_rdata;
    wire        arb_port0_burst_data_valid;
    wire        arb_port0_burst_wdata_req;
    wire        arb_port0_ack;
    wire        arb_port0_ready;

    wire        arb_port1_req /* verilator public */;
    wire        arb_port1_we;
    wire [23:0] arb_port1_addr /* verilator public */;
    wire [31:0] arb_port1_wdata /* verilator public */;
    wire [7:0]  arb_port1_burst_len;
    wire [15:0] arb_port1_burst_wdata;
    wire [31:0] arb_port1_rdata;
    wire [15:0] arb_port1_burst_rdata;
    wire        arb_port1_burst_data_valid;
    wire        arb_port1_burst_wdata_req;
    wire        arb_port1_ack;
    wire        arb_port1_ready;

    wire        arb_port2_req;
    wire        arb_port2_we;
    wire [23:0] arb_port2_addr;
    wire [31:0] arb_port2_wdata;
    wire [7:0]  arb_port2_burst_len;
    wire [15:0] arb_port2_burst_wdata;
    wire [31:0] arb_port2_rdata;
    wire [15:0] arb_port2_burst_rdata;
    wire        arb_port2_burst_data_valid;
    wire        arb_port2_burst_wdata_req;
    wire        arb_port2_ack;
    wire        arb_port2_ready;

    wire        arb_port3_req;
    wire        arb_port3_we;
    wire [23:0] arb_port3_addr;
    wire [31:0] arb_port3_wdata;
    wire [7:0]  arb_port3_burst_len;
    wire [15:0] arb_port3_burst_wdata;
    wire [31:0] arb_port3_rdata;
    wire [15:0] arb_port3_burst_rdata;
    wire        arb_port3_burst_data_valid;
    wire        arb_port3_burst_wdata_req;
    wire        arb_port3_ack;
    wire        arb_port3_ready;

    // Memory controller signals (single-word)
    wire        mem_ctrl_req;
    wire        mem_ctrl_we;
    wire [23:0] mem_ctrl_addr;
    wire [31:0] mem_ctrl_wdata;
    wire [31:0] mem_ctrl_rdata;
    wire        mem_ctrl_ack;
    wire        mem_ctrl_ready;

    // Memory controller signals (burst)
    wire [7:0]  mem_ctrl_burst_len;
    wire [15:0] mem_ctrl_burst_wdata;
    wire        mem_ctrl_burst_cancel;
    wire        mem_ctrl_burst_data_valid;
    wire        mem_ctrl_burst_wdata_req;
    wire        mem_ctrl_burst_done;
    wire [15:0] mem_ctrl_rdata_16;

    // Memory Arbiter instantiation
    sram_arbiter u_sram_arbiter (
        .clk(clk_core),
        .rst_n(rst_n_core),

        // Port 0: Display Read
        .port0_req(arb_port0_req),
        .port0_we(arb_port0_we),
        .port0_addr(arb_port0_addr),
        .port0_wdata(arb_port0_wdata),
        .port0_burst_len(arb_port0_burst_len),
        .port0_rdata(arb_port0_rdata),
        .port0_burst_rdata(arb_port0_burst_rdata),
        .port0_burst_data_valid(arb_port0_burst_data_valid),
        .port0_burst_wdata_req(arb_port0_burst_wdata_req),
        .port0_ack(arb_port0_ack),
        .port0_ready(arb_port0_ready),

        // Port 1: Framebuffer Write
        .port1_req(arb_port1_req),
        .port1_we(arb_port1_we),
        .port1_addr(arb_port1_addr),
        .port1_wdata(arb_port1_wdata),
        .port1_burst_len(arb_port1_burst_len),
        .port1_burst_wdata(arb_port1_burst_wdata),
        .port1_rdata(arb_port1_rdata),
        .port1_burst_rdata(arb_port1_burst_rdata),
        .port1_burst_data_valid(arb_port1_burst_data_valid),
        .port1_burst_wdata_req(arb_port1_burst_wdata_req),
        .port1_ack(arb_port1_ack),
        .port1_ready(arb_port1_ready),

        // Port 2: Z-Buffer Read/Write
        .port2_req(arb_port2_req),
        .port2_we(arb_port2_we),
        .port2_addr(arb_port2_addr),
        .port2_wdata(arb_port2_wdata),
        .port2_burst_len(arb_port2_burst_len),
        .port2_burst_wdata(arb_port2_burst_wdata),
        .port2_rdata(arb_port2_rdata),
        .port2_burst_rdata(arb_port2_burst_rdata),
        .port2_burst_data_valid(arb_port2_burst_data_valid),
        .port2_burst_wdata_req(arb_port2_burst_wdata_req),
        .port2_ack(arb_port2_ack),
        .port2_ready(arb_port2_ready),

        // Port 3: Texture Read
        .port3_req(arb_port3_req),
        .port3_we(arb_port3_we),
        .port3_addr(arb_port3_addr),
        .port3_wdata(arb_port3_wdata),
        .port3_burst_len(arb_port3_burst_len),
        .port3_burst_wdata(arb_port3_burst_wdata),
        .port3_rdata(arb_port3_rdata),
        .port3_burst_rdata(arb_port3_burst_rdata),
        .port3_burst_data_valid(arb_port3_burst_data_valid),
        .port3_burst_wdata_req(arb_port3_burst_wdata_req),
        .port3_ack(arb_port3_ack),
        .port3_ready(arb_port3_ready),

        // To memory controller — single-word
        .mem_req(mem_ctrl_req),
        .mem_we(mem_ctrl_we),
        .mem_addr(mem_ctrl_addr),
        .mem_wdata(mem_ctrl_wdata),
        .mem_rdata(mem_ctrl_rdata),
        .mem_ack(mem_ctrl_ack),
        .mem_ready(mem_ctrl_ready),

        // To memory controller — burst
        .mem_burst_len(mem_ctrl_burst_len),
        .mem_burst_wdata(mem_ctrl_burst_wdata),
        .mem_burst_cancel(mem_ctrl_burst_cancel),
        .mem_burst_data_valid(mem_ctrl_burst_data_valid),
        .mem_burst_wdata_req(mem_ctrl_burst_wdata_req),
        .mem_burst_done(mem_ctrl_burst_done),
        .mem_rdata_16(mem_ctrl_rdata_16)
    );

    // SDRAM Controller instantiation
    sdram_controller u_sdram_controller (
        .clk(clk_core),
        .rst_n(rst_n_core),

        // From arbiter — single-word
        .req(mem_ctrl_req),
        .we(mem_ctrl_we),
        .addr(mem_ctrl_addr),
        .wdata(mem_ctrl_wdata),
        .rdata(mem_ctrl_rdata),
        .ack(mem_ctrl_ack),
        .ready(mem_ctrl_ready),

        // From arbiter — burst
        .burst_len(mem_ctrl_burst_len),
        .burst_wdata_16(mem_ctrl_burst_wdata),
        .burst_cancel(mem_ctrl_burst_cancel),
        .burst_data_valid(mem_ctrl_burst_data_valid),
        .burst_wdata_req(mem_ctrl_burst_wdata_req),
        .burst_done(mem_ctrl_burst_done),
        .rdata_16(mem_ctrl_rdata_16),

        // To external SDRAM (sdram_clk driven directly from PLL output)
        .sdram_cke(sdram_cke),
        .sdram_csn(sdram_csn),
        .sdram_rasn(sdram_rasn),
        .sdram_casn(sdram_casn),
        .sdram_wen(sdram_wen),
        .sdram_ba(sdram_ba),
        .sdram_a(sdram_a),
        .sdram_dq(sdram_dq),
        .sdram_dqm(sdram_dqm)
    );

    // Temporary port assignments
    // Port 0: Display controller burst signals now driven by u_display_ctrl

    // Port 1: Rasterizer framebuffer (connected, burst support deferred to Task 4)
    assign arb_port1_burst_len = 8'b0;
    assign arb_port1_burst_wdata = 16'b0;

    // Port 2: Rasterizer Z-buffer (connected, burst support deferred to Task 4)
    assign arb_port2_burst_len = 8'b0;
    assign arb_port2_burst_wdata = 16'b0;

    // Port 3: Timestamp SDRAM write (shared with future texture reads)
    //
    // Simple FSM: latch ts_mem_wr pulse from register_file, hold arbiter
    // request until acknowledged.  Single-word write, no burst.
    reg         ts_pending;
    reg  [23:0] ts_arb_addr;
    reg  [31:0] ts_arb_wdata;

    always_ff @(posedge clk_core or negedge rst_n_core) begin
        if (!rst_n_core) begin
            ts_pending  <= 1'b0;
            ts_arb_addr <= 24'd0;
            ts_arb_wdata <= 32'd0;
        end else begin
            if (ts_mem_wr) begin
                // Latch new timestamp write request
                ts_pending  <= 1'b1;
                ts_arb_addr <= {ts_mem_addr, 1'b0};  // 23-bit word addr → 24-bit half-word addr
                ts_arb_wdata <= ts_mem_data;
            end else if (ts_pending && arb_port3_ack) begin
                // Arbiter accepted the write
                ts_pending <= 1'b0;
            end
        end
    end

    assign arb_port3_req = ts_pending;
    assign arb_port3_we = 1'b1;
    assign arb_port3_addr = ts_arb_addr;
    assign arb_port3_wdata = ts_arb_wdata;
    assign arb_port3_burst_len = 8'b0;
    assign arb_port3_burst_wdata = 16'b0;

    // ========================================================================
    // Display Pipeline (Phase 4 - Implemented)
    // ========================================================================

    // Timing generator signals
    wire        disp_hsync;
    wire        disp_vsync;
    wire        disp_enable /* verilator public */;
    wire [9:0]  disp_pixel_x;
    wire [9:0]  disp_pixel_y;
    wire        disp_frame_start;

    // Display controller signals
    wire [7:0]  disp_pixel_red /* verilator public */;
    wire [7:0]  disp_pixel_green /* verilator public */;
    wire [7:0]  disp_pixel_blue /* verilator public */;
    wire        disp_vsync_out /* verilator public */;

    // Timing Generator instantiation
    timing_generator u_timing_gen (
        .clk_pixel(clk_pixel),
        .rst_n(rst_n_pixel),
        .hsync(disp_hsync),
        .vsync(disp_vsync),
        .display_enable(disp_enable),
        .pixel_x(disp_pixel_x),
        .pixel_y(disp_pixel_y),
        .frame_start(disp_frame_start)
    );

    // Display Controller instantiation
    // Operates entirely in clk_core domain; timing inputs from the
    // timing generator (clk_pixel domain) are synchronized internally.
    display_controller u_display_ctrl (
        .clk_sram(clk_core),
        .rst_n_sram(rst_n_core),
        .display_enable(disp_enable),
        .pixel_x(disp_pixel_x),
        .pixel_y(disp_pixel_y),
        .frame_start(disp_frame_start),
        // x512 byte addr → [31:12] (4KB-aligned base address)
        .fb_display_base({7'b0, fb_display_addr[15:3]}),
        // Memory interface — single-word (display controller port names preserved)
        .sram_req(arb_port0_req),
        .sram_we(arb_port0_we),
        .sram_addr(arb_port0_addr),
        .sram_wdata(arb_port0_wdata),
        .sram_rdata(arb_port0_rdata),
        .sram_ack(arb_port0_ack),
        .sram_ready(arb_port0_ready),
        // Memory interface — burst (display controller port names preserved)
        .sram_burst_len(arb_port0_burst_len),
        .sram_burst_rdata(arb_port0_burst_rdata),
        .sram_burst_data_valid(arb_port0_burst_data_valid),
        // Pixel output
        .pixel_red(disp_pixel_red),
        .pixel_green(disp_pixel_green),
        .pixel_blue(disp_pixel_blue),
        .vsync_out(disp_vsync_out)
    );

    // DVI Output instantiation (excluded in sim mode; see UNIT-037)
    `ifndef SIM_DIRECT_CMD
    dvi_output u_dvi_out (
        .clk_pixel(clk_pixel),
        .clk_tmds(clk_tmds),
        .rst_n(rst_n_pixel),
        .red(disp_pixel_red),
        .green(disp_pixel_green),
        .blue(disp_pixel_blue),
        .hsync(disp_hsync),
        .vsync(disp_vsync),
        .display_enable(disp_enable),
        .tmds_red_p(tmds_data_p[2]),
        .tmds_red_n(tmds_data_n[2]),
        .tmds_green_p(tmds_data_p[1]),
        .tmds_green_n(tmds_data_n[1]),
        .tmds_blue_p(tmds_data_p[0]),
        .tmds_blue_n(tmds_data_n[0]),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n)
    );
    `else
    // In SIM_DIRECT_CMD mode, UNIT-009 (DVI TMDS Encoder) is not
    // instantiated. The SDL3 display window reads pixel tap signals
    // (disp_pixel_red/green/blue, disp_enable, disp_vsync_out) directly.
    // Tie off TMDS outputs to avoid undriven warnings.
    assign tmds_data_p = 3'b0;
    assign tmds_data_n = 3'b0;
    assign tmds_clk_p  = 1'b0;
    assign tmds_clk_n  = 1'b0;
    `endif

    // GPIO VSYNC output
    assign gpio_vsync = disp_vsync_out;

    // Update vblank status signal
    assign vblank = disp_vsync;

    // ========================================================================
    // Rendering Pipeline (Phase 6 - Rasterizer)
    // ========================================================================

    wire rast_ready;

    rasterizer u_rasterizer (
        .clk(clk_core),
        .rst_n(rst_n_core),

        // Triangle input from register file
        .tri_valid(tri_valid),
        .tri_ready(rast_ready),

        // Vertex 0
        .v0_x(tri_x[0]),
        .v0_y(tri_y[0]),
        .v0_z(tri_z[0]),
        .v0_color(tri_color0[0][23:0]),  // Diffuse RGB

        // Vertex 1
        .v1_x(tri_x[1]),
        .v1_y(tri_y[1]),
        .v1_z(tri_z[1]),
        .v1_color(tri_color0[1][23:0]),

        // Vertex 2
        .v2_x(tri_x[2]),
        .v2_y(tri_y[2]),
        .v2_z(tri_z[2]),
        .v2_color(tri_color0[2][23:0]),

        // Barycentric interpolation (from AREA_SETUP register)
        .inv_area(area_inv),
        .area_shift(area_shift),

        // Framebuffer write (memory arbiter port 1)
        .fb_req(arb_port1_req),
        .fb_we(arb_port1_we),
        .fb_addr(arb_port1_addr),
        .fb_wdata(arb_port1_wdata),
        .fb_rdata(arb_port1_rdata),
        .fb_ack(arb_port1_ack),
        .fb_ready(arb_port1_ready),

        // Z-buffer (memory arbiter port 2)
        .zb_req(arb_port2_req),
        .zb_we(arb_port2_we),
        .zb_addr(arb_port2_addr),
        .zb_wdata(arb_port2_wdata),
        .zb_rdata(arb_port2_rdata),
        .zb_ack(arb_port2_ack),
        .zb_ready(arb_port2_ready),

        // Configuration — x512 byte addr → [31:12] (4KB-aligned base address)
        .fb_base_addr({7'b0, fb_color_base[15:3]}),
        .zb_base_addr({7'b0, fb_z_base[15:3]}),

        // Rendering mode
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .z_compare(mode_z_compare),

        // Depth range clipping
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),

        // Framebuffer surface dimensions (from FB_CONFIG via register file)
        .fb_width_log2(fb_width_log2),
        .fb_height_log2(fb_height_log2)
    );

endmodule

`default_nettype wire
