`default_nettype none

// Testbench for texture_bc4 — BC4 texture decoder (FORMAT=3)
//
// Tests:
//   - Red channel replicated to R=G=B
//   - A9 always 0x100 (opaque)
//   - 8-entry and 6-entry modes
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 3), DD-038

`timescale 1ns/1ps

module tb_texture_bc4
    import fp_types_pkg::*;
;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Check helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check9(input string name, input logic [8:0] actual, input logic [8:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%03h, got 0x%03h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check36(input string name, input logic [35:0] actual, input logic [35:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%09x, got 0x%09x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT signals
    // ========================================================================

    reg  [63:0]  block_data;
    reg  [3:0]   texel_idx;
    wire [35:0]  texel_out;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_bc4 dut (
        .block_data (block_data),
        .texel_idx  (texel_idx),
        .texel_out  (texel_out)
    );

    // Convenience channel extraction
    wire [8:0] r9 = texel_out[35:27];
    wire [8:0] g9 = texel_out[26:18];
    wire [8:0] b9 = texel_out[17:9];
    wire [8:0] a9 = texel_out[8:0];

    // ========================================================================
    // Tests
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/texture_bc4.fst");
        $dumpvars(0, tb_texture_bc4);

        $display("=== Testing texture_bc4 ===\n");

        // BC4 layout:
        //   [7:0]   = red0 (u8)
        //   [15:8]  = red1 (u8)
        //   [63:16] = 48-bit red index table

        // --------------------------------------------------------------------
        // Test 1: Full white (red0=255, index 0 -> palette[0]=255)
        // ch8_to_uq18(255) = 0x100
        // Output: R=G=B=0x100, A=0x100
        // --------------------------------------------------------------------
        block_data = {48'h000000000000, 8'd0, 8'd255};
        texel_idx = 4'd0;
        #1;

        check9("white_r9", r9, 9'h100);
        check9("white_g9", g9, 9'h100);  // R replicated to G
        check9("white_b9", b9, 9'h100);  // R replicated to B
        check9("white_a9", a9, 9'h100);  // Always opaque

        // --------------------------------------------------------------------
        // Test 2: Full black (red0=0, index 0 -> palette[0]=0)
        // ch8_to_uq18(0) = 0x000
        // Output: R=G=B=0, A=0x100
        // --------------------------------------------------------------------
        block_data = {48'h000000000000, 8'd255, 8'd0};
        texel_idx = 4'd0;
        #1;

        check9("black_r9", r9, 9'h000);
        check9("black_g9", g9, 9'h000);
        check9("black_b9", b9, 9'h000);
        check9("black_a9", a9, 9'h100);  // Still opaque!

        // --------------------------------------------------------------------
        // Test 3: R=G=B replication check
        // All three color channels must always be identical
        // red0=128, index 0 -> palette[0]=128
        // ch8_to_uq18(128) = {1'b0, 8'd128} + {8'b0, 1'b1} = 0x080 + 1 = 0x081
        // --------------------------------------------------------------------
        block_data = {48'h000000000000, 8'd0, 8'd128};
        texel_idx = 4'd0;
        #1;

        check9("mid_r9", r9, 9'h081);
        check9("mid_g9", g9, 9'h081);
        check9("mid_b9", b9, 9'h081);
        check9("mid_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 4: 8-entry mode interpolation
        // red0=200 > red1=50 -> 8-entry mode
        // index 2: palette[2] = (6*200 + 1*50 + 3) * 2341 >> 14
        // = (1200 + 50 + 3) * 2341 >> 14 = 1253 * 2341 >> 14
        // = 2,933,273 >> 14 = 179.02 -> 179
        // ch8_to_uq18(179) = {1'b0, 8'd179} + {8'b0, 1'b1} = 0x0B3 + 1 = 0x0B4
        // --------------------------------------------------------------------
        block_data = {48'h000000000002, 8'd50, 8'd200};
        texel_idx = 4'd0;
        #1;

        check9("8ent_interp_r9", r9, 9'h0B4);
        check9("8ent_interp_g9", g9, 9'h0B4);  // Same as R

        // --------------------------------------------------------------------
        // Test 5: 6-entry mode special values
        // red0=0 <= red1=255 -> 6-entry mode
        // index 6 -> palette[6] = 0
        // index 7 -> palette[7] = 255
        // --------------------------------------------------------------------
        block_data = {48'h000000000006, 8'd255, 8'd0};
        texel_idx = 4'd0;
        #1;
        check9("6ent_idx6_r9", r9, 9'h000);

        block_data = {48'h000000000007, 8'd255, 8'd0};
        texel_idx = 4'd0;
        #1;
        check9("6ent_idx7_r9", r9, 9'h100);

        // --------------------------------------------------------------------
        // Test 6: Full output format check
        // red0=255, index 0 -> R=G=B=0x100, A=0x100
        // {0x100, 0x100, 0x100, 0x100}
        // --------------------------------------------------------------------
        block_data = {48'h000000000000, 8'd0, 8'd255};
        texel_idx = 4'd0;
        #1;
        check36("full_white_output", texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_bc4 Test Results ===");
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
