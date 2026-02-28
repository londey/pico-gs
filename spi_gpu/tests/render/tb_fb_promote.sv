// Testbench for fb_promote module
// Tests RGB565 to Q4.12 conversion via MSB-replication expansion
//
// See: UNIT-006 (Pixel Pipeline, Alpha Blending), REQ-005.03

`timescale 1ns/1ps

module tb_fb_promote;

    // DUT signals
    reg  [15:0] pixel_rgb565;
    wire [15:0] r_q412;
    wire [15:0] g_q412;
    wire [15:0] b_q412;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    fb_promote dut (
        .pixel_rgb565 (pixel_rgb565),
        .r_q412       (r_q412),
        .g_q412       (g_q412),
        .b_q412       (b_q412)
    );

    // Check helper: compare a 16-bit value against expected
    /* verilator lint_off UNUSEDSIGNAL */
    task check16(input string name, input [15:0] actual, input [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04h, got 0x%04h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        $dumpfile("fb_promote.vcd");
        $dumpvars(0, tb_fb_promote);

        $display("=== Testing fb_promote Module ===\n");

        // ============================================================
        // Black (all zeros): RGB565 = 0x0000
        // ============================================================
        $display("--- Black (0x0000) ---");

        pixel_rgb565 = 16'h0000;
        #1;
        // R5=0 -> {3'b0, 00000, 00000, 000} = 0x0000
        check16("black R", r_q412, 16'h0000);
        // G6=0 -> {3'b0, 000000, 000000, 0} = 0x0000
        check16("black G", g_q412, 16'h0000);
        // B5=0 -> {3'b0, 00000, 00000, 000} = 0x0000
        check16("black B", b_q412, 16'h0000);

        // ============================================================
        // White (all ones): RGB565 = 0xFFFF
        // ============================================================
        $display("--- White (0xFFFF) ---");

        pixel_rgb565 = 16'hFFFF;
        #1;
        // R5=31 -> {3'b0, 11111, 11111, 111} = 0x1FFF
        // Note: not exactly Q412_ONE (0x1000) because MSB replication
        // fills all fractional bits, producing the closest approximation
        // to 1.0 representable in the target range.
        // 31/31 = 1.0 -> Q4.12 should be close to 0x1000.
        // {000, 11111, 11111, 111} = 13'b1_1111_1111_1111 = 0x1FFF
        check16("white R", r_q412, 16'h1FFF);
        // G6=63 -> {000, 111111, 111111, 0} = 0x1FFE
        check16("white G", g_q412, 16'h1FFE);
        // B5=31 -> same as R5
        check16("white B", b_q412, 16'h1FFF);

        // ============================================================
        // Pure Red: RGB565 = 0xF800 (R5=31, G6=0, B5=0)
        // ============================================================
        $display("--- Pure Red (0xF800) ---");

        pixel_rgb565 = 16'hF800;
        #1;
        check16("red R", r_q412, 16'h1FFF);
        check16("red G", g_q412, 16'h0000);
        check16("red B", b_q412, 16'h0000);

        // ============================================================
        // Pure Green: RGB565 = 0x07E0 (R5=0, G6=63, B5=0)
        // ============================================================
        $display("--- Pure Green (0x07E0) ---");

        pixel_rgb565 = 16'h07E0;
        #1;
        check16("green R", r_q412, 16'h0000);
        check16("green G", g_q412, 16'h1FFE);
        check16("green B", b_q412, 16'h0000);

        // ============================================================
        // Pure Blue: RGB565 = 0x001F (R5=0, G6=0, B5=31)
        // ============================================================
        $display("--- Pure Blue (0x001F) ---");

        pixel_rgb565 = 16'h001F;
        #1;
        check16("blue R", r_q412, 16'h0000);
        check16("blue G", g_q412, 16'h0000);
        check16("blue B", b_q412, 16'h1FFF);

        // ============================================================
        // Mid-gray: R5=16, G6=32, B5=16
        // RGB565 = {10000, 100000, 10000} = 0x8410
        // ============================================================
        $display("--- Mid-gray (0x8410) ---");

        pixel_rgb565 = 16'h8410;
        #1;
        // R5=16 (10000) -> {000, 10000, 10000, 100} = 0x1084
        check16("mid-gray R", r_q412, 16'h1084);
        // G6=32 (100000) -> {000, 100000, 100000, 0} = 0x1040
        check16("mid-gray G", g_q412, 16'h1040);
        // B5=16 -> same as R5
        check16("mid-gray B", b_q412, 16'h1084);

        // ============================================================
        // Single-bit R: R5=1, G6=0, B5=0
        // RGB565 = {00001, 000000, 00000} = 0x0800
        // ============================================================
        $display("--- Minimum non-zero R (0x0800) ---");

        pixel_rgb565 = 16'h0800;
        #1;
        // R5=1 (00001) -> {000, 00001, 00001, 000} = 0x0108
        check16("min R", r_q412, 16'h0108);
        check16("min R, G=0", g_q412, 16'h0000);
        check16("min R, B=0", b_q412, 16'h0000);

        // ============================================================
        // Single-bit G: R5=0, G6=1, B5=0
        // RGB565 = {00000, 000001, 00000} = 0x0020
        // ============================================================
        $display("--- Minimum non-zero G (0x0020) ---");

        pixel_rgb565 = 16'h0020;
        #1;
        check16("min G, R=0", r_q412, 16'h0000);
        // G6=1 (000001) -> {000, 000001, 000001, 0} = 0x0082
        check16("min G", g_q412, 16'h0082);
        check16("min G, B=0", b_q412, 16'h0000);

        // ============================================================
        // Single-bit B: R5=0, G6=0, B5=1
        // RGB565 = 0x0001
        // ============================================================
        $display("--- Minimum non-zero B (0x0001) ---");

        pixel_rgb565 = 16'h0001;
        #1;
        check16("min B, R=0", r_q412, 16'h0000);
        check16("min B, G=0", g_q412, 16'h0000);
        // B5=1 -> same as R5=1 replication
        check16("min B", b_q412, 16'h0108);

        // ============================================================
        // Quarter intensity: R5=8, G6=16, B5=8
        // RGB565 = {01000, 010000, 01000} = 0x4208
        // ============================================================
        $display("--- Quarter intensity (0x4208) ---");

        pixel_rgb565 = 16'h4208;
        #1;
        // R5=8 (01000) -> {000, 01000, 01000, 010} = 0x0842
        check16("quarter R", r_q412, 16'h0842);
        // G6=16 (010000) -> {000, 010000, 010000, 0} = 0x0820
        check16("quarter G", g_q412, 16'h0820);
        // B5=8 -> same as R5=8
        check16("quarter B", b_q412, 16'h0842);

        // ============================================================
        // Three-quarter intensity: R5=24, G6=48, B5=24
        // RGB565 = {11000, 110000, 11000} = 0xC618
        // ============================================================
        $display("--- Three-quarter intensity (0xC618) ---");

        pixel_rgb565 = 16'hC618;
        #1;
        // R5=24 (11000) -> {000, 11000, 11000, 110} = 0x18C6
        check16("3/4 R", r_q412, 16'h18C6);
        // G6=48 (110000) -> {000, 110000, 110000, 0} = 0x1860
        check16("3/4 G", g_q412, 16'h1860);
        // B5=24 -> same as R5=24
        check16("3/4 B", b_q412, 16'h18C6);

        // ============================================================
        // Verify MSB replication pattern directly
        // R5=21 (10101) -> {000, 10101, 10101, 101} = 0x1555
        // ============================================================
        $display("--- MSB replication pattern R5=21 ---");

        // R5=21, G6=0, B5=0: {10101, 000000, 00000} = 0xA800
        // {000, 10101, 10101, 101} = 0x15AD
        pixel_rgb565 = 16'hA800;
        #1;
        check16("R5=21 replication", r_q412, 16'h15AD);

        // G6=42 (101010) -> {000, 101010, 101010, 0} = 0x1554
        // R5=0, G6=42, B5=0: {00000, 101010, 00000} = 0x0540
        $display("--- MSB replication pattern G6=42 ---");
        pixel_rgb565 = 16'h0540;
        #1;
        check16("G6=42 replication", g_q412, 16'h1554);

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        $finish;
    end

endmodule
