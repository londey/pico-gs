`default_nettype none

// Testbench for texel_promote — UQ1.8 to Q4.12 conversion
//
// Tests:
//   - UQ1.8 0x100 (1.0) -> Q4.12 0x1000 (1.0) for each channel
//   - UQ1.8 0x000 -> Q4.12 0x0000
//   - Mid-range values
//   - All four channels independent
//
// See: UNIT-011.04 (Block Decompressor), UNIT-011.04, UNIT-006

`timescale 1ns/1ps

module tb_texel_promote
    import fp_types_pkg::*;
;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Check helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04h, got 0x%04h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT signals
    // ========================================================================

    reg  [35:0] texel_in;
    wire [15:0] r_q412;
    wire [15:0] g_q412;
    wire [15:0] b_q412;
    wire [15:0] a_q412;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texel_promote dut (
        .texel_in (texel_in),
        .r_q412   (r_q412),
        .g_q412   (g_q412),
        .b_q412   (b_q412),
        .a_q412   (a_q412)
    );

    // ========================================================================
    // Tests
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/texel_promote.fst");
        $dumpvars(0, tb_texel_promote);

        $display("=== Testing texel_promote ===\n");

        // Input layout: texel_in[35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9

        // --------------------------------------------------------------------
        // Test 1: Full scale (1.0 in UQ1.8 = 0x100 -> 1.0 in Q4.12 = 0x1000)
        // All channels at 1.0
        // --------------------------------------------------------------------
        texel_in = {9'h100, 9'h100, 9'h100, 9'h100};
        #1;

        check16("full_r", r_q412, 16'h1000);
        check16("full_g", g_q412, 16'h1000);
        check16("full_b", b_q412, 16'h1000);
        check16("full_a", a_q412, 16'h1000);

        // --------------------------------------------------------------------
        // Test 2: Zero (0.0 in UQ1.8 -> 0.0 in Q4.12)
        // All channels at 0
        // --------------------------------------------------------------------
        texel_in = {9'h000, 9'h000, 9'h000, 9'h000};
        #1;

        check16("zero_r", r_q412, 16'h0000);
        check16("zero_g", g_q412, 16'h0000);
        check16("zero_b", b_q412, 16'h0000);
        check16("zero_a", a_q412, 16'h0000);

        // --------------------------------------------------------------------
        // Test 3: Mid-range (0x080 in UQ1.8 -> 0x0800 in Q4.12)
        // 0x080 << 4 = 0x0800
        // --------------------------------------------------------------------
        texel_in = {9'h080, 9'h080, 9'h080, 9'h080};
        #1;

        check16("mid_r", r_q412, 16'h0800);
        check16("mid_g", g_q412, 16'h0800);
        check16("mid_b", b_q412, 16'h0800);
        check16("mid_a", a_q412, 16'h0800);

        // --------------------------------------------------------------------
        // Test 4: Each channel independent
        // R=0x100, G=0x080, B=0x040, A=0x000
        // Expected: R=0x1000, G=0x0800, B=0x0400, A=0x0000
        // --------------------------------------------------------------------
        texel_in = {9'h100, 9'h080, 9'h040, 9'h000};
        #1;

        check16("indep_r", r_q412, 16'h1000);
        check16("indep_g", g_q412, 16'h0800);
        check16("indep_b", b_q412, 16'h0400);
        check16("indep_a", a_q412, 16'h0000);

        // --------------------------------------------------------------------
        // Test 5: Arbitrary value (0x0AB -> 0x0AB0)
        // 0x0AB << 4 = 0x0AB0
        // --------------------------------------------------------------------
        texel_in = {9'h0AB, 9'h055, 9'h0FF, 9'h001};
        #1;

        check16("arb_r", r_q412, 16'h0AB0);
        check16("arb_g", g_q412, 16'h0550);
        check16("arb_b", b_q412, 16'h0FF0);
        check16("arb_a", a_q412, 16'h0010);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texel_promote Test Results ===");
        $display("PASS: %0d, FAIL: %0d", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("*** ALL TESTS PASSED ***");
            $finish(0);
        end else begin
            $display("*** SOME TESTS FAILED ***");
            $finish(1);
        end
    end

endmodule

`default_nettype wire
