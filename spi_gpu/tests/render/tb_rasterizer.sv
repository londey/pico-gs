// Testbench for Triangle Rasterizer
// Tests basic triangle rasterization with edge functions
// Includes parametric bounding-box clamping tests for multiple surface sizes
//
// Verification reference: VER-001 (Rasterizer Unit Testbench)

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
    reg [3:0]   area_shift;

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

    // Framebuffer surface dimensions (from FB_CONFIG register)
    reg [3:0]   fb_width_log2;
    reg [3:0]   fb_height_log2;

    // Test result tracking
    integer test_pass_count = 0;
    integer test_fail_count = 0;

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
        .area_shift(area_shift),
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
        .z_range_max(z_range_max),
        .fb_width_log2(fb_width_log2),
        .fb_height_log2(fb_height_log2)
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
        if (zb_req && !zb_we) begin
            zb_rdata <= 32'hFFFF_FFFF;
        end
    end

    // ========================================================================
    // Helper task: submit a triangle and wait for rasterization to complete
    // ========================================================================
    task submit_triangle_and_wait;
        begin
            tri_valid = 1;
            @(posedge clk);
            wait(tri_ready == 0);  // Wait for rasterizer to accept
            tri_valid = 0;
            // Wait for rasterization to complete
            wait(tri_ready == 1);
        end
    endtask

    // ========================================================================
    // Helper task: check parametric bounding-box clamping
    // Asserts bbox_max_x <= (1 << width_log2) - 1 and
    //         bbox_max_y <= (1 << height_log2) - 1.
    // ========================================================================
    task check_bbox_clamp(
        input [3:0] width_log2,
        input [3:0] height_log2,
        input string test_label
    );
        reg [9:0] max_x_bound;
        reg [9:0] max_y_bound;
        begin
            max_x_bound = (10'd1 << width_log2) - 10'd1;
            max_y_bound = (10'd1 << height_log2) - 10'd1;

            if (dut.bbox_max_x <= max_x_bound) begin
                $display("  PASS: %s bbox_max_x=%0d <= %0d", test_label, dut.bbox_max_x, max_x_bound);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: %s bbox_max_x=%0d > %0d", test_label, dut.bbox_max_x, max_x_bound);
                test_fail_count = test_fail_count + 1;
            end

            if (dut.bbox_max_y <= max_y_bound) begin
                $display("  PASS: %s bbox_max_y=%0d <= %0d", test_label, dut.bbox_max_y, max_y_bound);
                test_pass_count = test_pass_count + 1;
            end else begin
                $display("  FAIL: %s bbox_max_y=%0d > %0d", test_label, dut.bbox_max_y, max_y_bound);
                test_fail_count = test_fail_count + 1;
            end
        end
    endtask

    // ========================================================================
    // Test sequence
    // ========================================================================
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
        area_shift = 4'd0;         // No barrel shift

        // Default surface dimensions: 512x512 (VER-001 precondition)
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

        #100;
        rst_n = 1;
        #100;

        $display("=== Testing Triangle Rasterizer ===\n");

        // ====================================================================
        // Test 1: Small triangle at origin (512x512 surface)
        // ====================================================================
        $display("Test 1: Small triangle (10,10) -> (50,10) -> (30,40) [512x512 surface]");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

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
        // inv_area = 65536/1200 = 54.613 ~ 55 = 0x0037 (0.16 fixed-point)
        inv_area = 16'h0037;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);

        // Check that bbox is within 512x512 bounds (fully within, so should match vertex extents)
        check_bbox_clamp(4'd9, 4'd9, "Test1-within-bounds");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2a: Bounding-box clamping on 512x512 surface (VER-001 step 2a)
        // Small triangle near boundary, extends beyond [0,511] x [0,511]
        // ====================================================================
        $display("\nTest 2a: Bbox clamping on 512x512 surface — triangle out of bounds");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

        // Vertex 0: (505, 505) — within bounds
        v0_x = 16'd8080;  // 505 << 4
        v0_y = 16'd8080;  // 505 << 4
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;

        // Vertex 1: (520, 505) — X > 511, out of bounds
        v1_x = 16'd8320;  // 520 << 4
        v1_y = 16'd8080;  // 505 << 4
        v1_z = 16'h2000;
        v1_color = 24'h00FF00;

        // Vertex 2: (510, 520) — Y > 511, out of bounds
        v2_x = 16'd8160;  // 510 << 4
        v2_y = 16'd8320;  // 520 << 4
        v2_z = 16'h3000;
        v2_color = 24'h0000FF;

        inv_area = 16'h0200;  // Approximate inv_area for small triangle

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);

        // Parametric bounding-box assertion: bbox_max_x <= 511, bbox_max_y <= 511
        check_bbox_clamp(4'd9, 4'd9, "Test2a-512x512-clamped");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2a-within: Fully within 512x512 bounds (bbox should match raw extents)
        // ====================================================================
        $display("\nTest 2a-within: Triangle fully within 512x512 bounds");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

        // Small triangle: (100, 100) -> (120, 100) -> (110, 120)
        v0_x = 16'd1600;  // 100 << 4
        v0_y = 16'd1600;  // 100 << 4
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;

        v1_x = 16'd1920;  // 120 << 4
        v1_y = 16'd1600;  // 100 << 4
        v1_z = 16'h2000;
        v1_color = 24'h00FF00;

        v2_x = 16'd1760;  // 110 << 4
        v2_y = 16'd1920;  // 120 << 4
        v2_z = 16'h3000;
        v2_color = 24'h0000FF;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);

        // Bounding box should still be within 512x512 bounds
        check_bbox_clamp(4'd9, 4'd9, "Test2a-within-512x512");

        // Additionally verify bbox matches raw vertex extents (not clamped)
        if (dut.bbox_min_x == 10'd100 && dut.bbox_max_x == 10'd120 &&
            dut.bbox_min_y == 10'd100 && dut.bbox_max_y == 10'd120) begin
            $display("  PASS: bbox matches raw vertex extents [100,120] x [100,120]");
            test_pass_count = test_pass_count + 1;
        end else begin
            $display("  FAIL: bbox does not match expected raw extents");
            $display("        got [%0d,%0d] x [%0d,%0d], expected [100,120] x [100,120]",
                     dut.bbox_min_x, dut.bbox_max_x, dut.bbox_min_y, dut.bbox_max_y);
            test_fail_count = test_fail_count + 1;
        end

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2b: Bounding-box clamping on 256x256 surface (VER-001 step 2b)
        // Small triangle near boundary, extends beyond [0,255] x [0,255]
        // ====================================================================
        $display("\nTest 2b: Bbox clamping on 256x256 surface — triangle out of bounds");
        fb_width_log2  = 4'd8;
        fb_height_log2 = 4'd8;

        // Vertex 0: (250, 250) — within bounds
        v0_x = 16'd4000;  // 250 << 4
        v0_y = 16'd4000;  // 250 << 4
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;

        // Vertex 1: (270, 250) — X > 255, out of bounds
        v1_x = 16'd4320;  // 270 << 4
        v1_y = 16'd4000;  // 250 << 4
        v1_z = 16'h2000;
        v1_color = 24'h00FF00;

        // Vertex 2: (260, 270) — Y > 255, out of bounds
        v2_x = 16'd4160;  // 260 << 4
        v2_y = 16'd4320;  // 270 << 4
        v2_z = 16'h3000;
        v2_color = 24'h0000FF;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);

        // Parametric bounding-box assertion: bbox_max_x <= 255, bbox_max_y <= 255
        check_bbox_clamp(4'd8, 4'd8, "Test2b-256x256-clamped");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2b-within: Fully within 256x256 bounds
        // ====================================================================
        $display("\nTest 2b-within: Triangle fully within 256x256 bounds");
        fb_width_log2  = 4'd8;
        fb_height_log2 = 4'd8;

        // Small triangle: (50, 50) -> (70, 50) -> (60, 70)
        v0_x = 16'd800;   // 50 << 4
        v0_y = 16'd800;   // 50 << 4
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;

        v1_x = 16'd1120;  // 70 << 4
        v1_y = 16'd800;   // 50 << 4
        v1_z = 16'h2000;
        v1_color = 24'h00FF00;

        v2_x = 16'd960;   // 60 << 4
        v2_y = 16'd1120;  // 70 << 4
        v2_z = 16'h3000;
        v2_color = 24'h0000FF;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);

        // Bounding box should still be within 256x256 bounds
        check_bbox_clamp(4'd8, 4'd8, "Test2b-within-256x256");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 3: Degenerate triangle — zero-area collinear vertices (VER-001 step 5)
        // Uses 512x512 surface (matching spec reference to "configured surface bounds")
        // ====================================================================
        $display("\nTest 3: Degenerate triangle — collinear vertices [512x512 surface]");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

        // Three collinear vertices along Y=100: (50,100), (100,100), (150,100)
        v0_x = 16'd800;   // 50 << 4
        v0_y = 16'd1600;  // 100 << 4
        v0_z = 16'h1000;
        v0_color = 24'hFF0000;

        v1_x = 16'd1600;  // 100 << 4
        v1_y = 16'd1600;  // 100 << 4
        v1_z = 16'h2000;
        v1_color = 24'h00FF00;

        v2_x = 16'd2400;  // 150 << 4
        v2_y = 16'd1600;  // 100 << 4
        v2_z = 16'h3000;
        v2_color = 24'h0000FF;

        // Zero area -> inv_area is irrelevant (rasterizer should emit zero fragments)
        inv_area = 16'h0000;

        submit_triangle_and_wait;
        $display("  Degenerate triangle completed at time %0t", $time);

        // Bounding box should still be within configured surface bounds
        check_bbox_clamp(4'd9, 4'd9, "Test3-degenerate");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== Rasterizer Test Summary ===");
        $display("  Passed: %0d", test_pass_count);
        $display("  Failed: %0d", test_fail_count);

        if (test_fail_count == 0) begin
            $display("RESULT: PASS");
        end else begin
            $display("RESULT: FAIL");
        end

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
        #5000000;  // 5ms timeout (increased for multiple test cases)
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
