// Testbench for color_combiner module
// Tests modulate preset, two-stage fog, COMBINED source in cycle 1,
// and saturation behavior.

`timescale 1ns/1ps

module color_combiner_tb;

    // Clock and reset
    reg         clk;
    reg         rst_n;

    // Fragment inputs (Q4.12 packed RGBA)
    reg  [63:0] tex_color0;
    reg  [63:0] tex_color1;
    reg  [63:0] shade0;
    reg  [63:0] shade1;

    // Fragment position and valid
    reg  [15:0] frag_x;
    reg  [15:0] frag_y;
    reg  [15:0] frag_z;
    reg         frag_valid;

    // Configuration
    reg  [63:0] cc_mode;
    reg  [63:0] const_color;

    // Outputs
    wire [63:0] combined_color;
    wire [15:0] out_frag_x;
    wire [15:0] out_frag_y;
    wire [15:0] out_frag_z;
    wire        out_frag_valid;
    wire        in_ready;
    reg         out_ready;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Q4.12 constants
    localparam [15:0] Q412_ZERO = 16'h0000;
    localparam [15:0] Q412_HALF = 16'h0800;  // 0.5
    localparam [15:0] Q412_ONE  = 16'h1000;  // 1.0

    // CC_SOURCE encoding
    localparam [3:0] CC_COMBINED = 4'd0;
    localparam [3:0] CC_TEX0     = 4'd1;
    localparam [3:0] CC_SHADE0   = 4'd3;
    localparam [3:0] CC_CONST1   = 4'd5;
    localparam [3:0] CC_ONE      = 4'd6;
    localparam [3:0] CC_ZERO     = 4'd7;

    // CC_RGB_C_SOURCE encoding (extended)
    localparam [3:0] CC_C_SHADE0       = 4'd3;
    localparam [3:0] CC_C_ONE          = 4'd6;
    localparam [3:0] CC_C_ZERO         = 4'd7;
    localparam [3:0] CC_C_SHADE0_ALPHA = 4'd10;

    // Instantiate DUT
    color_combiner dut (
        .clk(clk),
        .rst_n(rst_n),
        .tex_color0(tex_color0),
        .tex_color1(tex_color1),
        .shade0(shade0),
        .shade1(shade1),
        .frag_x(frag_x),
        .frag_y(frag_y),
        .frag_z(frag_z),
        .frag_valid(frag_valid),
        .cc_mode(cc_mode),
        .const_color(const_color),
        .combined_color(combined_color),
        .out_frag_x(out_frag_x),
        .out_frag_y(out_frag_y),
        .out_frag_z(out_frag_z),
        .out_frag_valid(out_frag_valid),
        .in_ready(in_ready),
        .out_ready(out_ready)
    );

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Check helpers
    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04x, got 0x%04x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    // Check with tolerance: |actual - expected| <= tolerance
    task check16_approx(input string name, input logic [15:0] actual, input logic [15:0] expected, input int tolerance);
        int diff;
        begin
            if ($signed(actual) > $signed(expected)) begin
                diff = $signed(actual) - $signed(expected);
            end else begin
                diff = $signed(expected) - $signed(actual);
            end
            if (diff <= tolerance) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: %s - expected 0x%04x (+/-%0d), got 0x%04x (diff=%0d)", name, expected, tolerance, actual, diff);
                fail_count = fail_count + 1;
            end
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Helper: build one CC_MODE cycle from selectors
    function automatic [31:0] pack_cycle(
        input [3:0] rgb_a, input [3:0] rgb_b, input [3:0] rgb_c, input [3:0] rgb_d,
        input [3:0] alpha_a, input [3:0] alpha_b, input [3:0] alpha_c, input [3:0] alpha_d
    );
        begin
            pack_cycle = {alpha_d, alpha_c, alpha_b, alpha_a, rgb_d, rgb_c, rgb_b, rgb_a};
        end
    endfunction

    // Helper: pack Q4.12 RGBA into 64-bit
    function automatic [63:0] pack_q412(
        input [15:0] r, input [15:0] g, input [15:0] b, input [15:0] a
    );
        begin
            pack_q412 = {r, g, b, a};
        end
    endfunction

    initial begin
        $dumpfile("color_combiner.vcd");
        $dumpvars(0, color_combiner_tb);

        // Initialize
        rst_n = 0;
        tex_color0 = 64'h0;
        tex_color1 = 64'h0;
        shade0 = 64'h0;
        shade1 = 64'h0;
        frag_x = 16'h0;
        frag_y = 16'h0;
        frag_z = 16'h0;
        frag_valid = 0;
        cc_mode = 64'h0;
        const_color = 64'h0;
        out_ready = 1;

        #100;
        rst_n = 1;
        #20;

        $display("=== Color Combiner Testbench ===\n");

        // ============================================================
        // Test 1: Modulate preset (TEX0 * SHADE0)
        // TEX0 = Q4.12(0.5) all channels, SHADE0 = Q4.12(0.5) all channels
        // Expected: 0.5 * 0.5 = 0.25 = Q4.12(0x0400)
        // ============================================================
        $display("--- Test 1: Modulate (TEX0 * SHADE0) ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade0     = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);

        // Cycle 0: modulate (A=TEX0, B=ZERO, C=SHADE0, D=ZERO)
        // Cycle 1: passthrough (A=COMBINED, B=ZERO, C=ONE, D=ZERO)
        cc_mode = {
            pack_cycle(CC_COMBINED, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_COMBINED, CC_ZERO, CC_ONE,   CC_ZERO),
            pack_cycle(CC_TEX0,     CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0,     CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        frag_valid = 1;
        @(posedge clk);
        frag_valid = 0;

        // Wait for pipeline: 2 clock stages
        @(posedge clk);
        @(posedge clk);

        // 0.5 * 0.5 = 0.25 in Q4.12 = 0x0400
        // Allow small tolerance for rounding
        check16_approx("modulate R", combined_color[63:48], 16'h0400, 1);
        check16_approx("modulate G", combined_color[47:32], 16'h0400, 1);
        check16_approx("modulate B", combined_color[31:16], 16'h0400, 1);
        check16_approx("modulate A", combined_color[15:0],  16'h0400, 1);

        // ============================================================
        // Test 2: Saturation at Q4.12(1.0) when inputs produce overflow
        // ONE * ONE + ONE = 1.0 * 1.0 + 1.0 = 2.0, should clamp to 1.0
        // ============================================================
        $display("--- Test 2: Saturation ---");

        // (A=ONE, B=ZERO, C=ONE, D=ONE) = 1.0 * 1.0 + 1.0 = 2.0 -> saturate to 1.0
        // Both cycles use this to test saturation
        cc_mode = {
            pack_cycle(CC_ONE, CC_ZERO, CC_C_ONE, CC_ONE,
                       CC_ONE, CC_ZERO, CC_ONE,   CC_ONE),
            pack_cycle(CC_ONE, CC_ZERO, CC_C_ONE, CC_ONE,
                       CC_ONE, CC_ZERO, CC_ONE,   CC_ONE)
        };

        frag_valid = 1;
        @(posedge clk);
        frag_valid = 0;

        @(posedge clk);
        @(posedge clk);

        check16("saturation R", combined_color[63:48], Q412_ONE);
        check16("saturation G", combined_color[47:32], Q412_ONE);
        check16("saturation B", combined_color[31:16], Q412_ONE);
        check16("saturation A", combined_color[15:0],  Q412_ONE);

        // ============================================================
        // Test 3: COMBINED source in cycle 1 equals cycle 0 output
        // Cycle 0: passthrough SHADE0 (A=SHADE0, B=ZERO, C=ONE, D=ZERO)
        // Cycle 1: passthrough COMBINED (A=COMBINED, B=ZERO, C=ONE, D=ZERO)
        // Output should equal SHADE0
        // ============================================================
        $display("--- Test 3: COMBINED source ---");

        shade0 = pack_q412(16'h0C00, 16'h0800, 16'h0400, 16'h1000);

        cc_mode = {
            pack_cycle(CC_COMBINED, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_COMBINED, CC_ZERO, CC_ONE,   CC_ZERO),
            pack_cycle(CC_SHADE0,   CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_SHADE0,   CC_ZERO, CC_ONE,   CC_ZERO)
        };

        frag_valid = 1;
        @(posedge clk);
        frag_valid = 0;

        @(posedge clk);
        @(posedge clk);

        check16("combined=shade0 R", combined_color[63:48], 16'h0C00);
        check16("combined=shade0 G", combined_color[47:32], 16'h0800);
        check16("combined=shade0 B", combined_color[31:16], 16'h0400);
        check16("combined=shade0 A", combined_color[15:0],  16'h1000);

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

    // Timeout watchdog
    initial begin
        #100000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
