// Testbench for dither module
// Tests ordered dithering with 16x16 Bayer matrix (tiled 4x4)
//
// The dither module adds a position-dependent offset to Q4.12 color channels
// before truncation to RGB565. The offset is scaled to the quantization step:
//   R5/B5: step ~ 132 in Q4.12, offset = dither_val * 132 >> 8
//   G6:    step ~ 65  in Q4.12, offset = dither_val * 65  >> 8
//
// See: UNIT-006 (Pixel Pipeline, Ordered Dithering), REQ-005.10

`timescale 1ns/1ps

module tb_dither;

    // DUT signals
    reg         clk;
    reg         rst_n;
    reg  [3:0]  frag_x;
    reg  [3:0]  frag_y;
    reg  [47:0] color_in;
    reg         dither_en;
    wire [47:0] color_out;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    dither dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .frag_x    (frag_x),
        .frag_y    (frag_y),
        .color_in  (color_in),
        .dither_en (dither_en),
        .color_out (color_out)
    );

    // Extract output channels
    wire [15:0] out_r = color_out[47:32];
    wire [15:0] out_g = color_out[31:16];
    wire [15:0] out_b = color_out[15:0];

    // 4x4 Bayer matrix (tiled to 16x16) — same values as the DUT
    // Row-major order:
    //   [  0, 128,  32, 160 ]
    //   [192,  64, 224,  96 ]
    //   [ 48, 176,  16, 144 ]
    //   [240, 112, 208,  80 ]
    reg [7:0] bayer [0:15];

    initial begin
        bayer[0]  = 8'd0;   bayer[1]  = 8'd128; bayer[2]  = 8'd32;  bayer[3]  = 8'd160;
        bayer[4]  = 8'd192; bayer[5]  = 8'd64;  bayer[6]  = 8'd224; bayer[7]  = 8'd96;
        bayer[8]  = 8'd48;  bayer[9]  = 8'd176; bayer[10] = 8'd16;  bayer[11] = 8'd144;
        bayer[12] = 8'd240; bayer[13] = 8'd112; bayer[14] = 8'd208; bayer[15] = 8'd80;
    end

    // Compute expected dither offset for R5/B5 channel
    function automatic [15:0] expected_offset_r5(input [7:0] dval);
        expected_offset_r5 = ({8'b0, dval} * 16'd132) >> 8;
    endfunction

    // Compute expected dither offset for G6 channel
    function automatic [15:0] expected_offset_g6(input [7:0] dval);
        expected_offset_g6 = ({8'b0, dval} * 16'd65) >> 8;
    endfunction

    // Clock generation (not needed for combinational, but module has clk port)
    initial clk = 0;
    always #5 clk = ~clk;

    // Check helper
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

    // Check helper for 48-bit
    /* verilator lint_off UNUSEDSIGNAL */
    task check48(input string name, input [47:0] actual, input [47:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%012h, got 0x%012h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Variables for loop tests
    integer ix, iy;
    reg [7:0] dval;
    reg [15:0] exp_r, exp_g, exp_b;
    reg [15:0] in_r, in_g, in_b;

    initial begin
        $dumpfile("dither.vcd");
        $dumpvars(0, tb_dither);

        rst_n = 0;
        dither_en = 0;
        frag_x = 0;
        frag_y = 0;
        color_in = 48'h0000_0000_0000;
        #10;
        rst_n = 1;
        #10;

        $display("=== Testing dither Module ===\n");

        // ============================================================
        // Bypass Mode (dither_en = 0): output = input
        // ============================================================
        $display("--- Bypass Mode (dither_en=0) ---");

        dither_en = 1'b0;

        // Black input
        color_in = 48'h0000_0000_0000;
        frag_x = 4'd5;
        frag_y = 4'd7;
        #1;
        check48("bypass: black", color_out, 48'h0000_0000_0000);

        // White input (Q4.12 = 0x1000 per channel)
        color_in = {16'h1000, 16'h1000, 16'h1000};
        #1;
        check48("bypass: white", color_out, {16'h1000, 16'h1000, 16'h1000});

        // Arbitrary input
        color_in = {16'h0800, 16'h0400, 16'h0C00};
        frag_x = 4'd15;
        frag_y = 4'd15;
        #1;
        check48("bypass: arbitrary", color_out, {16'h0800, 16'h0400, 16'h0C00});

        // ============================================================
        // Zero dither value: position (0,0) has bayer[0] = 0
        // All offsets should be zero.
        // ============================================================
        $display("--- Zero Dither Value at (0,0) ---");

        dither_en = 1'b1;
        frag_x = 4'd0;
        frag_y = 4'd0;
        color_in = {16'h0800, 16'h0800, 16'h0800};
        #1;
        // bayer[(0&3)*4 + (0&3)] = bayer[0] = 0
        // offset_r5 = 0*132/256 = 0
        // offset_g6 = 0*65/256  = 0
        check16("dither(0,0): R unchanged", out_r, 16'h0800);
        check16("dither(0,0): G unchanged", out_g, 16'h0800);
        check16("dither(0,0): B unchanged", out_b, 16'h0800);

        // ============================================================
        // Maximum dither value: position (0,3) in 4x4 -> bayer[12] = 240
        // The 16x16 matrix tiles the 4x4, so (0,3), (4,3), (8,3), (12,3)
        // all have value 240.
        // ============================================================
        $display("--- Maximum Dither Value at (0,3) [bayer=240] ---");

        frag_x = 4'd0;
        frag_y = 4'd3;
        color_in = {16'h0800, 16'h0800, 16'h0800};
        #1;
        // bayer[(3&3)*4 + (0&3)] = bayer[12] = 240
        // offset_r5 = 240 * 132 >> 8 = 31680 >> 8 = 123 = 0x007B
        // offset_g6 = 240 * 65  >> 8 = 15600 >> 8 = 60  = 0x003C
        check16("dither(0,3): R with max offset", out_r, 16'h0800 + 16'h007B);
        check16("dither(0,3): G with max offset", out_g, 16'h0800 + 16'h003C);
        check16("dither(0,3): B with max offset", out_b, 16'h0800 + 16'h007B);

        // ============================================================
        // Known positions: verify specific Bayer matrix values
        // ============================================================
        $display("--- Known Bayer Positions ---");

        // Position (1,0): bayer[(0&3)*4 + (1&3)] = bayer[1] = 128
        frag_x = 4'd1;
        frag_y = 4'd0;
        color_in = {16'h0400, 16'h0400, 16'h0400};
        #1;
        // offset_r5 = 128 * 132 >> 8 = 16896 >> 8 = 66 = 0x0042
        // offset_g6 = 128 * 65  >> 8 = 8320  >> 8 = 32 = 0x0020
        check16("dither(1,0): R", out_r, 16'h0400 + 16'h0042);
        check16("dither(1,0): G", out_g, 16'h0400 + 16'h0020);
        check16("dither(1,0): B", out_b, 16'h0400 + 16'h0042);

        // Position (2,1): bayer[(1&3)*4 + (2&3)] = bayer[6] = 224
        frag_x = 4'd2;
        frag_y = 4'd1;
        color_in = {16'h0200, 16'h0200, 16'h0200};
        #1;
        // offset_r5 = 224 * 132 >> 8 = 29568 >> 8 = 115 = 0x0073
        // offset_g6 = 224 * 65  >> 8 = 14560 >> 8 = 56  = 0x0038
        check16("dither(2,1): R", out_r, 16'h0200 + 16'h0073);
        check16("dither(2,1): G", out_g, 16'h0200 + 16'h0038);
        check16("dither(2,1): B", out_b, 16'h0200 + 16'h0073);

        // ============================================================
        // Tiling: (4,4) should equal (0,0) because 4x4 is tiled
        // ============================================================
        $display("--- 4x4 Tiling Verification ---");

        color_in = {16'h0600, 16'h0600, 16'h0600};

        frag_x = 4'd0;
        frag_y = 4'd0;
        #1;
        exp_r = out_r;
        exp_g = out_g;
        exp_b = out_b;

        frag_x = 4'd4;
        frag_y = 4'd4;
        #1;
        check16("tiling: (4,4)==(0,0) R", out_r, exp_r);
        check16("tiling: (4,4)==(0,0) G", out_g, exp_g);
        check16("tiling: (4,4)==(0,0) B", out_b, exp_b);

        frag_x = 4'd8;
        frag_y = 4'd8;
        #1;
        check16("tiling: (8,8)==(0,0) R", out_r, exp_r);
        check16("tiling: (8,8)==(0,0) G", out_g, exp_g);
        check16("tiling: (8,8)==(0,0) B", out_b, exp_b);

        frag_x = 4'd12;
        frag_y = 4'd12;
        #1;
        check16("tiling: (12,12)==(0,0) R", out_r, exp_r);
        check16("tiling: (12,12)==(0,0) G", out_g, exp_g);
        check16("tiling: (12,12)==(0,0) B", out_b, exp_b);

        // ============================================================
        // Position Sensitivity: adjacent pixels get different offsets
        // ============================================================
        $display("--- Position Sensitivity ---");

        color_in = {16'h0800, 16'h0800, 16'h0800};

        frag_x = 4'd0;
        frag_y = 4'd0;
        #1;
        exp_r = out_r;

        frag_x = 4'd1;
        frag_y = 4'd0;
        #1;
        if (out_r !== exp_r) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: adjacent pixels (0,0) and (1,0) should differ");
            fail_count = fail_count + 1;
        end

        // ============================================================
        // R/B symmetry: R and B channels get same offset (both 5-bit)
        // ============================================================
        $display("--- R/B Channel Symmetry ---");

        frag_x = 4'd3;
        frag_y = 4'd2;
        color_in = {16'h0500, 16'h0500, 16'h0500};
        #1;
        check16("R/B symmetry: same offset", out_r, out_b);

        // G channel gets different (smaller) offset
        // bayer[(2&3)*4 + (3&3)] = bayer[11] = 144
        // offset_r5 = 144 * 132 >> 8 = 19008 >> 8 = 74 = 0x004A
        // offset_g6 = 144 * 65  >> 8 = 9360  >> 8 = 36 = 0x0024
        check16("G offset differs from R", out_g, 16'h0500 + 16'h0024);
        check16("R offset value", out_r, 16'h0500 + 16'h004A);

        // ============================================================
        // Sweep all 16 4x4 positions: verify against reference model
        // ============================================================
        $display("--- Full 4x4 Position Sweep ---");

        color_in = {16'h0800, 16'h0800, 16'h0800};
        in_r = 16'h0800;
        in_g = 16'h0800;
        in_b = 16'h0800;

        for (iy = 0; iy < 4; iy = iy + 1) begin
            for (ix = 0; ix < 4; ix = ix + 1) begin
                frag_x = ix[3:0];
                frag_y = iy[3:0];
                #1;

                dval = bayer[iy * 4 + ix];
                exp_r = in_r + expected_offset_r5(dval);
                exp_g = in_g + expected_offset_g6(dval);
                exp_b = in_b + expected_offset_r5(dval);

                check16($sformatf("sweep(%0d,%0d) R", ix, iy), out_r, exp_r);
                check16($sformatf("sweep(%0d,%0d) G", ix, iy), out_g, exp_g);
                check16($sformatf("sweep(%0d,%0d) B", ix, iy), out_b, exp_b);
            end
        end

        // ============================================================
        // Black input with dither: verify offsets are purely additive
        // ============================================================
        $display("--- Black Input with Dither ---");

        color_in = 48'h0000_0000_0000;
        frag_x = 4'd1;
        frag_y = 4'd0;
        #1;
        // bayer[1] = 128
        // offset_r5 = 128*132>>8 = 66 = 0x0042
        // offset_g6 = 128*65>>8  = 32 = 0x0020
        check16("black+dither(1,0): R", out_r, 16'h0042);
        check16("black+dither(1,0): G", out_g, 16'h0020);
        check16("black+dither(1,0): B", out_b, 16'h0042);

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
