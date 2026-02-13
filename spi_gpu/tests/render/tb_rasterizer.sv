// Testbench for Triangle Rasterizer
// Tests basic triangle rasterization with edge functions

`timescale 1ns/1ps

module tb_rasterizer;

    // Clock and reset
    reg clk;
    reg rst_n;

    // Triangle input
    reg         tri_valid;
    wire        tri_ready;

    reg [15:0]  v0_x, v0_y, v0_z;
    reg [23:0]  v0_color;

    reg [15:0]  v1_x, v1_y, v1_z;
    reg [23:0]  v1_color;

    reg [15:0]  v2_x, v2_y, v2_z;
    reg [23:0]  v2_color;

    // Barycentric interpolation
    reg [15:0]  inv_area;

    // Framebuffer interface
    wire        fb_req;
    wire        fb_we;
    wire [23:0] fb_addr;
    wire [31:0] fb_wdata;
    reg  [31:0] fb_rdata;
    reg         fb_ack;
    reg         fb_ready;

    // Z-buffer interface
    wire        zb_req;
    wire        zb_we;
    wire [23:0] zb_addr;
    wire [31:0] zb_wdata;
    reg  [31:0] zb_rdata;
    reg         zb_ack;
    reg         zb_ready;

    // Configuration
    reg [31:12] fb_base_addr;
    reg [31:12] zb_base_addr;

    // Rendering mode
    reg         mode_z_test;
    reg         mode_z_write;
    reg         mode_color_write;
    reg  [2:0]  z_compare;
    reg  [15:0] z_range_min;
    reg  [15:0] z_range_max;

    // Instantiate DUT
    rasterizer dut (
        .clk(clk),
        .rst_n(rst_n),
        .tri_valid(tri_valid),
        .tri_ready(tri_ready),
        .v0_x(v0_x), .v0_y(v0_y), .v0_z(v0_z), .v0_color(v0_color),
        .v1_x(v1_x), .v1_y(v1_y), .v1_z(v1_z), .v1_color(v1_color),
        .v2_x(v2_x), .v2_y(v2_y), .v2_z(v2_z), .v2_color(v2_color),
        .inv_area(inv_area),
        .fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr),
        .fb_wdata(fb_wdata), .fb_rdata(fb_rdata),
        .fb_ack(fb_ack), .fb_ready(fb_ready),
        .zb_req(zb_req), .zb_we(zb_we), .zb_addr(zb_addr),
        .zb_wdata(zb_wdata), .zb_rdata(zb_rdata),
        .zb_ack(zb_ack), .zb_ready(zb_ready),
        .fb_base_addr(fb_base_addr),
        .zb_base_addr(zb_base_addr),
        .mode_z_test(mode_z_test),
        .mode_z_write(mode_z_write),
        .mode_color_write(mode_color_write),
        .z_compare(z_compare),
        .z_range_min(z_range_min),
        .z_range_max(z_range_max)
    );

    // Clock generation (100 MHz system clock)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Memory response simulation
    always @(posedge clk) begin
        // Simulate immediate memory response
        fb_ack <= fb_req;
        zb_ack <= zb_req;

        // Return cleared Z-buffer value (far depth)
        if (zb_req && !zb_we)
            zb_rdata <= 32'hFFFF_FFFF;
    end

    // Test sequence
    initial begin
        $dumpfile("rasterizer.vcd");
        $dumpvars(0, tb_rasterizer);

        // Initialize
        rst_n = 0;
        tri_valid = 0;
        fb_ready = 1;
        zb_ready = 1;
        fb_base_addr = 20'h00000;  // Framebuffer at 0x00000000
        zb_base_addr = 20'h10000;  // Z-buffer at 0x10000000
        mode_z_test = 1'b1;        // Enable Z-testing
        mode_z_write = 1'b1;       // Enable Z-writes
        mode_color_write = 1'b1;   // Enable color writes
        z_compare = 3'b000;        // LESS compare function
        z_range_min = 16'h0000;    // Full depth range (disabled)
        z_range_max = 16'hFFFF;

        #100;
        rst_n = 1;
        #100;

        $display("=== Testing Triangle Rasterizer ===\n");

        // Test 1: Small triangle at origin
        $display("Test 1: Small triangle (10,10) -> (50,10) -> (30,40)");

        // Vertex 0: (10, 10) in 12.4 fixed point = 10 << 4 = 160
        v0_x = 16'd160;
        v0_y = 16'd160;
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;  // Red

        // Vertex 1: (50, 10)
        v1_x = 16'd800;  // 50 << 4
        v1_y = 16'd160;
        v1_z = 16'h2000;  // Different depth for interpolation test
        v1_color = 24'h00FF00;  // Green

        // Vertex 2: (30, 40)
        v2_x = 16'd480;  // 30 << 4
        v2_y = 16'd640;  // 40 << 4
        v2_z = 16'h3000;  // Different depth for interpolation test
        v2_color = 24'h0000FF;  // Blue

        // Edge function area (2x geometric area):
        // edge0 at v0 = (y1-y2)*x0 + (x2-x1)*y0 + x1*y2 - x2*y1
        //             = (10-40)*10 + (30-50)*10 + 50*40 - 30*10
        //             = -300 - 200 + 2000 - 300 = 1200
        // inv_area = 65536/1200 = 54.613 ≈ 55 = 0x0037 (0.16 fixed-point)
        inv_area = 16'h0037;

        // Submit triangle
        tri_valid = 1;
        @(posedge clk);

        wait(tri_ready == 0);  // Wait for rasterizer to accept
        tri_valid = 0;
        $display("Triangle submitted at time %0t", $time);

        // Wait for rasterization to complete
        wait(tri_ready == 1);
        $display("Triangle rasterization completed at time %0t\n", $time);

        // Let simulation run a bit more
        repeat(100) @(posedge clk);

        $display("=== Rasterizer Test Completed ===");
        $finish;
    end

    // Monitor pixel writes
    integer pixel_count = 0;

    always @(posedge clk) begin
        if (fb_req && fb_ack) begin
            pixel_count = pixel_count + 1;
            $display("Pixel %0d: addr=0x%06x, color=0x%04x (R5G6B5)",
                     pixel_count, fb_addr, fb_wdata[15:0]);

            // Debug first few pixels
            if (pixel_count <= 3) begin
                $display("  w0=0x%04x, w1=0x%04x, w2=0x%04x (16-bit)",
                         dut.w0, dut.w1, dut.w2);
                $display("  e0[15:0]=%0d, inv_area=0x%04x",
                         dut.e0[15:0], dut.inv_area_reg);
                $display("  r0=%0d, r1=%0d, r2=%0d -> interp_r=%0d",
                         dut.r0, dut.r1, dut.r2, dut.interp_r);
            end
        end
    end

    // Timeout watchdog
    initial begin
        #1000000;  // 1ms timeout
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
