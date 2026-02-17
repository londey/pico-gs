// Command FIFO - Boot-Populated Async FIFO Wrapper
// Wraps async_fifo (WIDTH=72, DEPTH=32) with synthesis-time memory
// initialization containing the GPU boot command sequence.
//
// Boot sequence renders:
//   1. Black background (two screen-covering flat-shaded triangles)
//   2. Centered RGB Gouraud-shaded triangle
//   3. FB_DISPLAY present to show the result
//
// After reset, BOOT_COUNT entries are immediately available for reading.
// Once consumed, the FIFO operates as a normal async FIFO for SPI commands.
//
// See DD-019 and UNIT-002 for design rationale.

`default_nettype none

module command_fifo (
    // Write clock domain
    input  wire        wr_clk,
    input  wire        wr_rst_n,
    input  wire        wr_en,
    input  wire [71:0] wr_data,
    output wire        wr_full,
    output wire        wr_almost_full,

    // Read clock domain
    input  wire        rd_clk,
    input  wire        rd_rst_n,
    input  wire        rd_en,
    output wire [71:0] rd_data,
    output wire        rd_empty,
    output wire [5:0]  rd_count
);

    // Number of pre-populated boot commands (must match boot_commands.hex)
    localparam BOOT_COUNT = 17;

    // ========================================================================
    // FIFO Instance
    // ========================================================================

    async_fifo #(
        .WIDTH      (72),
        .DEPTH      (32),
        .BOOT_COUNT (BOOT_COUNT),
        .INIT_FILE  ("src/spi/boot_commands.hex")
    ) u_fifo (
        .wr_clk        (wr_clk),
        .wr_rst_n      (wr_rst_n),
        .wr_en         (wr_en),
        .wr_data       (wr_data),
        .wr_full       (wr_full),
        .wr_almost_full(wr_almost_full),
        .rd_clk        (rd_clk),
        .rd_rst_n      (rd_rst_n),
        .rd_en         (rd_en),
        .rd_data       (rd_data),
        .rd_empty      (rd_empty),
        .rd_count      (rd_count)
    );

    // Boot command memory initialization is handled by async_fifo's INIT_FILE
    // parameter, which loads src/spi/boot_commands.hex via $readmemh.
    // See boot_commands.hex for the boot sequence definition.

endmodule

`default_nettype wire
