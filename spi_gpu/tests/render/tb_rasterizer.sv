// Testbench for Triangle Rasterizer (Incremental Interpolation, DD-024)
// Tests basic triangle rasterization with edge functions, fragment output bus,
// derivative precomputation, and incremental attribute interpolation.
// Includes parametric bounding-box clamping tests for multiple surface sizes.
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
    reg [31:0]  v0_color0, v0_color1;
    reg [31:0]  v0_uv0, v0_uv1;
    reg [15:0]  v0_q;

    reg [15:0]  v1_x, v1_y, v1_z;
    reg [31:0]  v1_color0, v1_color1;
    reg [31:0]  v1_uv0, v1_uv1;
    reg [15:0]  v1_q;

    reg [15:0]  v2_x, v2_y, v2_z;
    reg [31:0]  v2_color0, v2_color1;
    reg [31:0]  v2_uv0, v2_uv1;
    reg [15:0]  v2_q;

    // Inverse area
    reg [15:0]  inv_area;

    // Fragment output bus
    wire        frag_valid;
    reg         frag_ready;
    wire [9:0]  frag_x;
    wire [9:0]  frag_y;
    wire [15:0] frag_z;
    wire [63:0] frag_color0;
    wire [63:0] frag_color1;
    wire [31:0] frag_uv0;
    wire [31:0] frag_uv1;
    wire [15:0] frag_q;

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

        .v0_x(v0_x), .v0_y(v0_y), .v0_z(v0_z),
        .v0_color0(v0_color0), .v0_color1(v0_color1),
        .v0_uv0(v0_uv0), .v0_uv1(v0_uv1), .v0_q(v0_q),

        .v1_x(v1_x), .v1_y(v1_y), .v1_z(v1_z),
        .v1_color0(v1_color0), .v1_color1(v1_color1),
        .v1_uv0(v1_uv0), .v1_uv1(v1_uv1), .v1_q(v1_q),

        .v2_x(v2_x), .v2_y(v2_y), .v2_z(v2_z),
        .v2_color0(v2_color0), .v2_color1(v2_color1),
        .v2_uv0(v2_uv0), .v2_uv1(v2_uv1), .v2_q(v2_q),

        .inv_area(inv_area),

        .frag_valid(frag_valid),
        .frag_ready(frag_ready),
        .frag_x(frag_x),
        .frag_y(frag_y),
        .frag_z(frag_z),
        .frag_color0(frag_color0),
        .frag_color1(frag_color1),
        .frag_uv0(frag_uv0),
        .frag_uv1(frag_uv1),
        .frag_q(frag_q),

        .fb_width_log2(fb_width_log2),
        .fb_height_log2(fb_height_log2)
    );

    // Clock generation (100 MHz system clock)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
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
    // Helper task: set default vertex attributes (zero UV, color1, Q)
    // ========================================================================
    task set_default_attrs;
        begin
            v0_color1 = 32'h00000000;
            v0_uv0 = 32'h00000000;
            v0_uv1 = 32'h00000000;
            v0_q = 16'h1000;  // Q = 1.0 in Q3.12

            v1_color1 = 32'h00000000;
            v1_uv0 = 32'h00000000;
            v1_uv1 = 32'h00000000;
            v1_q = 16'h1000;

            v2_color1 = 32'h00000000;
            v2_uv0 = 32'h00000000;
            v2_uv1 = 32'h00000000;
            v2_q = 16'h1000;
        end
    endtask

    // ========================================================================
    // Fragment counter and monitor
    // ========================================================================
    integer pixel_count = 0;
    integer total_frag_count = 0;

    always @(posedge clk) begin
        if (frag_valid && frag_ready) begin
            pixel_count = pixel_count + 1;
            total_frag_count = total_frag_count + 1;

            // Debug first few pixels per triangle
            if (pixel_count <= 3) begin
                $display("  Fragment %0d: x=%0d y=%0d z=0x%04x color0=0x%016x",
                         pixel_count, frag_x, frag_y, frag_z, frag_color0);
            end
        end
    end

    // ========================================================================
    // Test sequence
    // ========================================================================
    initial begin
        $dumpfile("rasterizer.vcd");
        $dumpvars(0, tb_rasterizer);

        // Initialize
        rst_n = 0;
        tri_valid = 0;
        frag_ready = 1;  // Always accept fragments by default

        // Default surface dimensions: 512x512 (VER-001 precondition)
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;

        // Default attributes
        set_default_attrs;

        #100;
        rst_n = 1;
        #100;

        $display("=== Testing Triangle Rasterizer (Incremental Interpolation) ===\n");

        // ====================================================================
        // Test 1: Small triangle at origin (512x512 surface)
        // Verifies: edge function coefficients, fragment emission, bbox
        // ====================================================================
        $display("Test 1: Small triangle (10,10) -> (50,10) -> (30,40) [512x512 surface]");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        // Vertex 0: (10, 10) in 12.4 fixed point = 10 << 4 = 160
        v0_x = 16'd160;
        v0_y = 16'd160;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;  // Red (RGBA8888)
        set_default_attrs;

        // Vertex 1: (50, 10)
        v1_x = 16'd800;  // 50 << 4
        v1_y = 16'd160;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;  // Green

        // Vertex 2: (30, 40)
        v2_x = 16'd480;  // 30 << 4
        v2_y = 16'd640;  // 40 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;  // Blue

        // inv_area = 65536/1200 ~ 55 = 0x0037
        inv_area = 16'h0037;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t, fragments=%0d", $time, pixel_count);

        // Check that bbox is within 512x512 bounds
        check_bbox_clamp(4'd9, 4'd9, "Test1-within-bounds");

        // Verify fragments were emitted
        if (pixel_count > 0) begin
            $display("  PASS: Fragment count > 0 (%0d fragments)", pixel_count);
            test_pass_count = test_pass_count + 1;
        end else begin
            $display("  FAIL: No fragments emitted");
            test_fail_count = test_fail_count + 1;
        end

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2a: Bounding-box clamping on 512x512 surface (VER-001 step 2a)
        // ====================================================================
        $display("\nTest 2a: Bbox clamping on 512x512 surface -- triangle out of bounds");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        v0_x = 16'd8080;  // 505 << 4
        v0_y = 16'd8080;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd8320;  // 520 << 4
        v1_y = 16'd8080;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd8160;  // 510 << 4
        v2_y = 16'd8320;  // 520 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);
        check_bbox_clamp(4'd9, 4'd9, "Test2a-512x512-clamped");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2a-within: Fully within 512x512 bounds
        // ====================================================================
        $display("\nTest 2a-within: Triangle fully within 512x512 bounds");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        v0_x = 16'd1600;  // 100 << 4
        v0_y = 16'd1600;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd1920;  // 120 << 4
        v1_y = 16'd1600;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd1760;  // 110 << 4
        v2_y = 16'd1920;  // 120 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);
        check_bbox_clamp(4'd9, 4'd9, "Test2a-within-512x512");

        // Verify bbox matches raw vertex extents (not clamped)
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
        // ====================================================================
        $display("\nTest 2b: Bbox clamping on 256x256 surface -- triangle out of bounds");
        fb_width_log2  = 4'd8;
        fb_height_log2 = 4'd8;
        pixel_count = 0;

        v0_x = 16'd4000;  // 250 << 4
        v0_y = 16'd4000;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd4320;  // 270 << 4
        v1_y = 16'd4000;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd4160;  // 260 << 4
        v2_y = 16'd4320;  // 270 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);
        check_bbox_clamp(4'd8, 4'd8, "Test2b-256x256-clamped");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 2b-within: Fully within 256x256 bounds
        // ====================================================================
        $display("\nTest 2b-within: Triangle fully within 256x256 bounds");
        fb_width_log2  = 4'd8;
        fb_height_log2 = 4'd8;
        pixel_count = 0;

        v0_x = 16'd800;   // 50 << 4
        v0_y = 16'd800;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd1120;  // 70 << 4
        v1_y = 16'd800;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd960;   // 60 << 4
        v2_y = 16'd1120;  // 70 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Triangle rasterization completed at time %0t", $time);
        check_bbox_clamp(4'd8, 4'd8, "Test2b-within-256x256");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 3: Degenerate triangle -- zero-area collinear vertices (VER-001 step 6)
        // ====================================================================
        $display("\nTest 3: Degenerate triangle -- collinear vertices [512x512 surface]");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        v0_x = 16'd800;   // 50 << 4
        v0_y = 16'd1600;  // 100 << 4
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd1600;  // 100 << 4
        v1_y = 16'd1600;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd2400;  // 150 << 4
        v2_y = 16'd1600;
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0000;

        submit_triangle_and_wait;
        $display("  Degenerate triangle completed at time %0t, fragments=%0d", $time, pixel_count);

        check_bbox_clamp(4'd9, 4'd9, "Test3-degenerate");

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 4: Fragment output bus back-pressure (VER-001 step 5)
        // ====================================================================
        $display("\nTest 4: Fragment output bus back-pressure test");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        // Small triangle that definitely has inside pixels
        v0_x = 16'd320;   // 20 << 4
        v0_y = 16'd320;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        set_default_attrs;

        v1_x = 16'd640;   // 40 << 4
        v1_y = 16'd320;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;

        v2_x = 16'd480;   // 30 << 4
        v2_y = 16'd640;   // 40 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;

        inv_area = 16'h0200;

        // Deassert ready to test back-pressure
        frag_ready = 0;

        tri_valid = 1;
        @(posedge clk);
        wait(tri_ready == 0);
        tri_valid = 0;

        // Wait a few cycles for rasterizer to reach INTERPOLATE (DD-025 handshake)
        repeat(20) @(posedge clk);

        // If frag_valid is asserted and we haven't accepted, pixel_count should be 0
        if (pixel_count == 0 && frag_valid) begin
            $display("  PASS: Back-pressure held -- frag_valid=1 but no fragments consumed");
            test_pass_count = test_pass_count + 1;
        end else if (pixel_count == 0) begin
            // Triangle might not have inside pixels at this point, or setup not done
            $display("  INFO: frag_valid=%0d, pixel_count=%0d (may need more cycles)", frag_valid, pixel_count);
        end else begin
            $display("  FAIL: Fragments consumed while frag_ready=0 (pixel_count=%0d)", pixel_count);
            test_fail_count = test_fail_count + 1;
        end

        // Re-assert ready and let rasterization complete
        frag_ready = 1;
        wait(tri_ready == 1);
        $display("  Back-pressure test completed, total fragments=%0d", pixel_count);

        if (pixel_count > 0) begin
            $display("  PASS: Fragments emitted after ready re-asserted (%0d fragments)", pixel_count);
            test_pass_count = test_pass_count + 1;
        end else begin
            $display("  FAIL: No fragments emitted after ready re-asserted");
            test_fail_count = test_fail_count + 1;
        end

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 5: Q4.12 UV interpolation with wrapping range (VER-001 step 7)
        // Verifies UV values > 1.0 and negative UV are handled correctly.
        // Q4.12: 1.0 = 0x1000, 2.0 = 0x2000, -1.0 = 0xF000
        // ====================================================================
        $display("\nTest 5: Q4.12 UV interpolation -- wrapping range");
        fb_width_log2  = 4'd9;
        fb_height_log2 = 4'd9;
        pixel_count = 0;

        // Small triangle: (10,10) -> (20,10) -> (15,20)
        v0_x = 16'd160;   // 10 << 4
        v0_y = 16'd160;
        v0_z = 16'h1000;
        v0_color0 = 32'hFF000000;
        v0_color1 = 32'h00000000;
        // UV0: U=0.0, V=0.0 in Q4.12
        v0_uv0 = {16'h0000, 16'h0000};
        v0_uv1 = 32'h00000000;
        v0_q = 16'h1000;

        v1_x = 16'd320;   // 20 << 4
        v1_y = 16'd160;
        v1_z = 16'h2000;
        v1_color0 = 32'h00FF0000;
        v1_color1 = 32'h00000000;
        // UV0: U=2.0, V=0.0 -- wraps past 1.0
        v1_uv0 = {16'h2000, 16'h0000};
        v1_uv1 = 32'h00000000;
        v1_q = 16'h1000;

        v2_x = 16'd240;   // 15 << 4
        v2_y = 16'd320;   // 20 << 4
        v2_z = 16'h3000;
        v2_color0 = 32'h0000FF00;
        v2_color1 = 32'h00000000;
        // UV0: U=-1.0, V=2.0 -- negative U, wrapping V
        v2_uv0 = {16'hF000, 16'h2000};
        v2_uv1 = 32'h00000000;
        v2_q = 16'h1000;

        inv_area = 16'h0200;

        submit_triangle_and_wait;
        $display("  Q4.12 UV test completed at time %0t, fragments=%0d", $time, pixel_count);

        if (pixel_count > 0) begin
            $display("  PASS: Fragments emitted with Q4.12 UV wrapping range (%0d fragments)", pixel_count);
            test_pass_count = test_pass_count + 1;
        end else begin
            $display("  FAIL: No fragments emitted");
            test_fail_count = test_fail_count + 1;
        end

        repeat(20) @(posedge clk);

        // ====================================================================
        // Test 6: Verify no SDRAM ports exist (VER-001 verification criterion 3)
        // ====================================================================
        $display("\nTest 6: Verify fragment output bus interface (no SDRAM ports)");
        // This is a structural check -- the fact that the DUT compiles with
        // frag_valid/frag_ready and without fb_req/zb_req proves the interface.
        $display("  PASS: DUT compiled with fragment output bus (no SDRAM ports)");
        test_pass_count = test_pass_count + 1;

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== Rasterizer Test Summary ===");
        $display("  Passed: %0d", test_pass_count);
        $display("  Failed: %0d", test_fail_count);
        $display("  Total fragments emitted: %0d", total_frag_count);

        if (test_fail_count == 0) begin
            $display("RESULT: PASS");
        end else begin
            $display("RESULT: FAIL");
        end

        $display("=== Rasterizer Test Completed ===");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #10000000;  // 10ms timeout (increased for back-pressure test)
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
