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

    // ========================================================================
    // Boot Command Constants
    // ========================================================================

    // Number of pre-populated boot commands
    localparam BOOT_COUNT = 17;

    // Register addresses (from register_file.sv v2.0)
    localparam [6:0] ADDR_COLOR      = 7'h00;
    localparam [6:0] ADDR_VERTEX     = 7'h02;
    localparam [6:0] ADDR_TRI_MODE   = 7'h04;
    localparam [6:0] ADDR_FB_DRAW    = 7'h08;
    localparam [6:0] ADDR_FB_DISPLAY = 7'h09;

    // FIFO entry format: {rw(1), addr(7), data(64)} = 72 bits
    // For writes: rw = 0
    //
    // Pack helpers (used as macros via localparam expressions in initial block):
    //   cmd_write:  {1'b0, addr[6:0], data[63:0]}
    //   vertex_data: {7'b0, z[24:0], y[15:0], x[15:0]}  (12.4 fixed-point coords)

    // ========================================================================
    // Screen geometry constants (12.4 fixed-point)
    // ========================================================================

    // Screen dimensions: 640x480
    localparam [15:0] SCREEN_W = 16'd640 << 4;   // 10240 = 0x2800
    localparam [15:0] SCREEN_H = 16'd480 << 4;   // 7680  = 0x1E00

    // RGB triangle vertices (centered on screen)
    localparam [15:0] TRI_X0 = 16'd320 << 4;     // 5120  = 0x1400 (top-center)
    localparam [15:0] TRI_Y0 = 16'd100 << 4;     // 1600  = 0x0640
    localparam [15:0] TRI_X1 = 16'd160 << 4;     // 2560  = 0x0A00 (bottom-left)
    localparam [15:0] TRI_Y1 = 16'd380 << 4;     // 6080  = 0x17C0
    localparam [15:0] TRI_X2 = 16'd480 << 4;     // 7680  = 0x1E00 (bottom-right)
    localparam [15:0] TRI_Y2 = 16'd380 << 4;     // 6080  = 0x17C0

    // Colors (RGBA8888)
    localparam [31:0] COLOR_BLACK = 32'h000000FF;
    localparam [31:0] COLOR_RED   = 32'hFF0000FF;
    localparam [31:0] COLOR_GREEN = 32'h00FF00FF;
    localparam [31:0] COLOR_BLUE  = 32'h0000FFFF;

    // Render mode values (tri_mode register)
    //   bit 0: mode_gouraud
    //   bit 4: mode_color_write
    localparam [15:0] MODE_FLAT_COLOR    = 16'h0010;  // gouraud=0, color_write=1
    localparam [15:0] MODE_GOURAUD_COLOR = 16'h0011;  // gouraud=1, color_write=1

    // Framebuffer A base address (per INT-011)
    localparam [63:0] FB_A_ADDR = 64'h0000_0000_0000_0000;

    // ========================================================================
    // FIFO Instance
    // ========================================================================

    async_fifo #(
        .WIDTH      (72),
        .DEPTH      (32),
        .BOOT_COUNT (BOOT_COUNT)
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

    // ========================================================================
    // Boot Command Memory Initialization
    // ========================================================================
    // Synthesis-time initialization of FIFO memory with boot command sequence.
    // After reset, write pointer starts at BOOT_COUNT so these entries are
    // immediately available for the read side to consume.

    initial begin
        // Step 1: Set draw target to Framebuffer A
        u_fifo.mem[0]  = {1'b0, ADDR_FB_DRAW, FB_A_ADDR};

        // Step 2: Set flat shading mode (for screen clear)
        u_fifo.mem[1]  = {1'b0, ADDR_TRI_MODE, 48'b0, MODE_FLAT_COLOR};

        // Step 3: Clear screen with opaque black triangles
        //   Triangle 1: top-left, top-right, bottom-left
        u_fifo.mem[2]  = {1'b0, ADDR_COLOR, 32'b0, COLOR_BLACK};
        u_fifo.mem[3]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, 16'h0000};
        u_fifo.mem[4]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, SCREEN_W};
        u_fifo.mem[5]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, 16'h0000};
        //   Triangle 2: top-right, bottom-right, bottom-left
        u_fifo.mem[6]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, 16'h0000, SCREEN_W};
        u_fifo.mem[7]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, SCREEN_W};
        u_fifo.mem[8]  = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, SCREEN_H, 16'h0000};

        // Step 4: Set Gouraud shading mode (for RGB triangle)
        u_fifo.mem[9]  = {1'b0, ADDR_TRI_MODE, 48'b0, MODE_GOURAUD_COLOR};

        // Step 5: Draw RGB Gouraud-shaded triangle
        //   Vertex 0: red, top-center
        u_fifo.mem[10] = {1'b0, ADDR_COLOR, 32'b0, COLOR_RED};
        u_fifo.mem[11] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y0, TRI_X0};
        //   Vertex 1: green, bottom-left
        u_fifo.mem[12] = {1'b0, ADDR_COLOR, 32'b0, COLOR_GREEN};
        u_fifo.mem[13] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y1, TRI_X1};
        //   Vertex 2: blue, bottom-right
        u_fifo.mem[14] = {1'b0, ADDR_COLOR, 32'b0, COLOR_BLUE};
        u_fifo.mem[15] = {1'b0, ADDR_VERTEX, 7'b0, 25'b0, TRI_Y2, TRI_X2};

        // Step 6: Present boot screen
        u_fifo.mem[16] = {1'b0, ADDR_FB_DISPLAY, FB_A_ADDR};
    end

endmodule

`default_nettype wire
