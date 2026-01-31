// ICEpi SPI GPU - Top Level Module
// Version 2.0 - Gouraud Shading Implementation (Texture support deferred)
//
// This module integrates all GPU subsystems:
// - Clock generation (PLL)
// - Reset synchronization
// - SPI interface
// - Memory subsystem (SRAM controller and arbiter)
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
    output wire         gpio_cmd_empty,     // Command buffer empty (safe to read STATUS)
    output wire         gpio_vsync,         // Vertical sync pulse

    // ==== SRAM Interface (32MB, 16-bit async) ====
    output wire [23:0]  sram_addr,          // Address bus
    inout  wire [15:0]  sram_data,          // Bidirectional data bus
    output wire         sram_we_n,          // Write enable (active-low)
    output wire         sram_oe_n,          // Output enable (active-low)
    output wire         sram_ce_n,          // Chip enable (active-low)

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
    wire clk_100;           // 100 MHz for SRAM controller
    wire clk_pixel;         // 25.175 MHz for display timing
    wire clk_tmds;          // 251.75 MHz for TMDS serializer
    wire pll_locked;        // PLL lock indicator

    // Synchronized reset signals for each clock domain
    wire rst_n_100;         // Reset synchronized to clk_100
    wire rst_n_pixel;       // Reset synchronized to clk_pixel
    wire rst_n_tmds;        // Reset synchronized to clk_tmds

    // PLL instantiation
    pll_core u_pll (
        .clk_50_in(clk_50),
        .rst_n(rst_n),
        .clk_100(clk_100),
        .clk_pixel(clk_pixel),
        .clk_tmds(clk_tmds),
        .pll_locked(pll_locked)
    );

    // Reset synchronizers for each clock domain
    reset_sync u_reset_sync_100 (
        .clk(clk_100),
        .rst_n_async(rst_n),
        .pll_locked(pll_locked),
        .rst_n_sync(rst_n_100)
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
    wire        fifo_wr_almost_full;
    wire        fifo_rd_en;
    wire [71:0] fifo_rd_data;
    wire        fifo_rd_empty;
    wire [4:0]  fifo_rd_count;

    // Register file signals
    wire        reg_cmd_valid;
    wire        reg_cmd_rw;
    wire [6:0]  reg_cmd_addr;
    wire [63:0] reg_cmd_wdata;
    wire [63:0] reg_cmd_rdata;

    // Triangle output signals
    wire        tri_valid;
    wire [2:0][15:0] tri_x;
    wire [2:0][15:0] tri_y;
    wire [2:0][24:0] tri_z;
    wire [2:0][31:0] tri_color;

    // Triangle mode signals
    wire mode_gouraud;
    wire mode_textured;
    wire mode_z_test;
    wire mode_z_write;

    // Framebuffer configuration
    wire [31:12] fb_draw;
    wire [31:12] fb_display;

    // Clear signals
    wire [31:0] clear_color;
    wire clear_trigger;

    // Status signals
    wire gpu_busy;
    wire vblank;

    // SPI Slave instantiation
    spi_slave u_spi_slave (
        .spi_sck(spi_sck),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .sys_clk(clk_100),
        .sys_rst_n(rst_n_100),
        .valid(spi_valid),
        .rw(spi_rw),
        .addr(spi_addr),
        .wdata(spi_wdata),
        .rdata(spi_rdata)
    );

    // Pack SPI transaction into FIFO format
    assign fifo_wr_en = spi_valid;
    assign fifo_wr_data = {spi_rw, spi_addr, spi_wdata};

    // Command FIFO instantiation
    async_fifo #(
        .WIDTH(72),     // {rw(1), addr(7), data(64)}
        .DEPTH(16)
    ) u_cmd_fifo (
        .wr_clk(clk_100),
        .wr_rst_n(rst_n_100),
        .wr_en(fifo_wr_en),
        .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full),
        .wr_almost_full(fifo_wr_almost_full),
        .rd_clk(clk_100),
        .rd_rst_n(rst_n_100),
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

    // Register File instantiation
    register_file u_register_file (
        .clk(clk_100),
        .rst_n(rst_n_100),
        .cmd_valid(reg_cmd_valid),
        .cmd_rw(reg_cmd_rw),
        .cmd_addr(reg_cmd_addr),
        .cmd_wdata(reg_cmd_wdata),
        .cmd_rdata(reg_cmd_rdata),
        .tri_valid(tri_valid),
        .tri_x(tri_x),
        .tri_y(tri_y),
        .tri_z(tri_z),
        .tri_color(tri_color),
        .mode_gouraud(mode_gouraud),
        .mode_textured(mode_textured),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .fb_draw(fb_draw),
        .fb_display(fb_display),
        .clear_color(clear_color),
        .clear_trigger(clear_trigger),
        .gpu_busy(gpu_busy),
        .vblank(vblank),
        .fifo_depth({3'b0, fifo_rd_count})
    );

    // GPIO outputs
    assign gpio_cmd_full = fifo_wr_almost_full;
    assign gpio_cmd_empty = fifo_rd_empty;

    // Temporary status assignments (will be connected to actual modules later)
    assign gpu_busy = 1'b0;    // No rendering pipeline yet
    assign vblank = 1'b0;      // No display controller yet

    // ========================================================================
    // Memory Subsystem (Phase 3 - To Be Implemented)
    // ========================================================================

    // TODO: Instantiate sram_controller module
    // TODO: Instantiate sram_arbiter module

    // Temporary assignments to prevent synthesis warnings
    assign sram_addr = 24'b0;
    assign sram_data = 16'bz;  // High-Z when not driving
    assign sram_we_n = 1'b1;   // Write disabled
    assign sram_oe_n = 1'b1;   // Output disabled
    assign sram_ce_n = 1'b1;   // Chip disabled

    // ========================================================================
    // Display Pipeline (Phase 4 - To Be Implemented)
    // ========================================================================

    // TODO: Instantiate timing_generator module
    // TODO: Instantiate scanline_fifo module
    // TODO: Instantiate display_controller module
    // TODO: Instantiate dvi_encoder module

    // Temporary assignments to prevent synthesis warnings
    assign tmds_data_p = 3'b0;
    assign tmds_data_n = 3'b0;
    assign tmds_clk_p = 1'b0;
    assign tmds_clk_n = 1'b0;
    assign gpio_vsync = 1'b0;

    // ========================================================================
    // Rendering Pipeline (Phases 5-7 - To Be Implemented)
    // ========================================================================

    // TODO: Instantiate clear_engine module
    // TODO: Instantiate triangle_setup module
    // TODO: Instantiate rasterizer module
    // TODO: Instantiate interpolator module
    // TODO: Instantiate z_buffer module

endmodule
