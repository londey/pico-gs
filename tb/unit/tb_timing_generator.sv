// Testbench for timing_generator module
// Verifies 640x480@60Hz VGA timing generation

`timescale 1ns/1ps

module tb_timing_generator;

    // Clock and reset
    reg clk_pixel;
    reg rst_n;

    // Outputs
    wire hsync;
    wire vsync;
    wire display_enable;
    wire [9:0] pixel_x;
    wire [9:0] pixel_y;
    wire frame_start;

    // VGA timing constants
    localparam H_DISPLAY = 640;
    localparam H_TOTAL = 800;
    localparam V_DISPLAY = 480;
    localparam V_TOTAL = 525;

    // Instantiate DUT
    timing_generator dut (
        .clk_pixel(clk_pixel),
        .rst_n(rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_enable(display_enable),
        .pixel_x(pixel_x),
        .pixel_y(pixel_y),
        .frame_start(frame_start)
    );

    // Generate 25 MHz pixel clock (40ns period)
    initial begin
        clk_pixel = 0;
        forever #20 clk_pixel = ~clk_pixel;
    end

    // Test sequence
    initial begin
        $dumpfile("timing_generator.vcd");
        $dumpvars(0, tb_timing_generator);

        // Reset
        rst_n = 0;
        #100;
        rst_n = 1;

        $display("=== Testing Timing Generator ===");
        $display("Reset released, waiting a few clocks for initialization...");

        // Wait a few clocks for initial state to settle
        repeat(5) @(posedge clk_pixel);

        $display("\nInitial state:");
        $display("  pixel_x = %0d, pixel_y = %0d", pixel_x, pixel_y);
        $display("  hsync = %0d, vsync = %0d", hsync, vsync);
        $display("  display_enable = %0d, frame_start = %0d", display_enable, frame_start);

        // Wait a bit more and check if counters are incrementing
        repeat(10) @(posedge clk_pixel);
        $display("\nAfter 10 more clocks:");
        $display("  pixel_x = %0d, pixel_y = %0d", pixel_x, pixel_y);
        $display("  hsync = %0d, vsync = %0d", hsync, vsync);

        $display("\nWaiting for frame_start pulse...");
        $display("(One complete frame = 800×525 = 420,000 clocks = ~17ms)");

        // Wait for frame start with timeout
        // Frame period = 800*525*40ns = 16.8ms, so use 20ms timeout
        fork
            @(posedge frame_start);
            begin
                #20000000;  // 20ms
                $display("ERROR: No frame_start within 20ms");
                $display("Final state: pixel_x=%0d, pixel_y=%0d", pixel_x, pixel_y);
                $finish;
            end
        join_any
        disable fork;
        $display("Frame start detected at time %0t", $time);
        $display("  pixel_x = %0d, pixel_y = %0d", pixel_x, pixel_y);

        if (pixel_x != 0 || pixel_y != 0) begin
            $display("ERROR: frame_start should occur at (0,0)");
            $finish;
        end

        // Monitor one complete horizontal line
        $display("\nMonitoring horizontal line 0...");
        $display("Starting at: pixel_x=%0d, pixel_y=%0d, h_count=%0d, v_count=%0d",
                 pixel_x, pixel_y, dut.h_count, dut.v_count);

        // Wait for h_count to reach different values to verify it's incrementing
        while (dut.h_count < 10'd10) @(posedge clk_pixel);
        $display("h_count reached 10+: h_count=%0d", dut.h_count);

        while (dut.h_count < 10'd100) @(posedge clk_pixel);
        $display("h_count reached 100+: h_count=%0d", dut.h_count);

        while (dut.h_count < 10'd798) @(posedge clk_pixel);
        $display("h_count reached 798+: h_count=%0d", dut.h_count);

        // Now wait for 799
        while (dut.h_count != 10'd799) @(posedge clk_pixel);
        $display("h_count is 799 after clock edge");

        // Wait for next clock - h_count should wrap to 0
        @(posedge clk_pixel);
        $display("After next clock: h_count=%0d, v_count=%0d", dut.h_count, dut.v_count);

        // Check the wrap happened correctly
        if (dut.h_count != 10'd0) begin
            $display("ERROR: h_count should have wrapped to 0, but got %0d", dut.h_count);
            $display("H_TOTAL constant check: comparing h_count(%0d) == H_TOTAL-1(%0d) should be %0b",
                     10'd799, H_TOTAL-1, 10'd799 == (H_TOTAL-1));
            $finish;
        end

        if (dut.v_count != 10'd1) begin
            $display("ERROR: v_count should be 1, but got %0d", dut.v_count);
            $finish;
        end

        $display("  Horizontal line timing verified - h_count wrapped and v_count incremented");

        // Monitor display_enable during active region
        $display("\nChecking display_enable pattern...");
        @(posedge frame_start);  // Wait for next frame

        repeat(10) begin
            @(posedge clk_pixel);
            if (pixel_x < H_DISPLAY && pixel_y < V_DISPLAY) begin
                if (!display_enable) begin
                    $display("ERROR: display_enable should be high at (%0d, %0d)", pixel_x, pixel_y);
                    $finish;
                end
            end
        end

        $display("  display_enable active during visible region (verified 10 samples)");

        // Check hsync toggles
        $display("\nWaiting for hsync to go low...");
        wait(hsync == 0);
        $display("  hsync went low at pixel_x = %0d", pixel_x);

        wait(hsync == 1);
        $display("  hsync went high again at pixel_x = %0d", pixel_x);

        // Check vsync toggles
        $display("\nWaiting for vsync to go low...");
        wait(vsync == 0);
        $display("  vsync went low at pixel_y = %0d", pixel_y);

        wait(vsync == 1);
        $display("  vsync went high again at pixel_y = %0d", pixel_y);

        $display("\n=== All Tests Passed ===");
        $display("The timing generator is working correctly!");
        $finish;
    end

    // Timeout watchdog
    initial begin
        #50000000;  // 50ms timeout (enough for multiple frames)
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
