`default_nettype none

// Testbench for texture_rgb565 — RGB565 texture decoder (FORMAT=5)
//
// Tests:
//   - Correct 16-bit word extraction for each texel index
//   - Channel expansion: white, black, pure red/green/blue
//   - A9 always 0x100 (opaque)
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 5), DD-038

`timescale 1ns/1ps

module tb_texture_rgb565
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

    reg  [255:0] block_data;
    reg  [3:0]   texel_idx;
    wire [35:0]  texel_out;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_rgb565 dut (
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
        $dumpfile("../build/sim_out/texture_rgb565.fst");
        $dumpvars(0, tb_texture_rgb565);

        $display("=== Testing texture_rgb565 ===\n");

        // Block data: 16 texels x 16 bits = 256 bits, row-major
        // texel 0 at bits [15:0], texel 1 at bits [31:16], ...

        // --------------------------------------------------------------------
        // Test 1: White (0xFFFF = R5=31, G6=63, B5=31)
        // ch5_to_uq18(31) = 0x100, ch6_to_uq18(63) = 0x100
        // --------------------------------------------------------------------
        block_data = {240'd0, 16'hFFFF};  // Texel 0 = white
        texel_idx = 4'd0;
        #1;

        check9("white_r9", r9, 9'h100);
        check9("white_g9", g9, 9'h100);
        check9("white_b9", b9, 9'h100);
        check9("white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: Black (0x0000)
        // ch5_to_uq18(0) = 0x000, ch6_to_uq18(0) = 0x000
        // --------------------------------------------------------------------
        block_data = 256'd0;
        texel_idx = 4'd0;
        #1;

        check9("black_r9", r9, 9'h000);
        check9("black_g9", g9, 9'h000);
        check9("black_b9", b9, 9'h000);
        check9("black_a9", a9, 9'h100);  // Always opaque

        // --------------------------------------------------------------------
        // Test 3: Pure red (0xF800 = R5=31, G6=0, B5=0)
        // --------------------------------------------------------------------
        block_data = {240'd0, 16'hF800};
        texel_idx = 4'd0;
        #1;

        check9("red_r9", r9, 9'h100);
        check9("red_g9", g9, 9'h000);
        check9("red_b9", b9, 9'h000);

        // --------------------------------------------------------------------
        // Test 4: Pure green (0x07E0 = R5=0, G6=63, B5=0)
        // --------------------------------------------------------------------
        block_data = {240'd0, 16'h07E0};
        texel_idx = 4'd0;
        #1;

        check9("green_r9", r9, 9'h000);
        check9("green_g9", g9, 9'h100);
        check9("green_b9", b9, 9'h000);

        // --------------------------------------------------------------------
        // Test 5: Pure blue (0x001F = R5=0, G6=0, B5=31)
        // --------------------------------------------------------------------
        block_data = {240'd0, 16'h001F};
        texel_idx = 4'd0;
        #1;

        check9("blue_r9", r9, 9'h000);
        check9("blue_g9", g9, 9'h000);
        check9("blue_b9", b9, 9'h100);

        // --------------------------------------------------------------------
        // Test 6: Texel index selection
        // Place different colors at different positions
        // texel 0 = red (0xF800), texel 1 = green (0x07E0),
        // texel 5 = blue (0x001F), texel 15 = white (0xFFFF)
        // --------------------------------------------------------------------
        block_data = 256'd0;
        block_data[15:0]    = 16'hF800;   // texel 0 = red
        block_data[31:16]   = 16'h07E0;   // texel 1 = green
        block_data[95:80]   = 16'h001F;   // texel 5 = blue
        block_data[255:240] = 16'hFFFF;   // texel 15 = white

        texel_idx = 4'd0;
        #1;
        check9("idx_t0_r9", r9, 9'h100);  // red

        texel_idx = 4'd1;
        #1;
        check9("idx_t1_g9", g9, 9'h100);  // green

        texel_idx = 4'd5;
        #1;
        check9("idx_t5_b9", b9, 9'h100);  // blue

        texel_idx = 4'd15;
        #1;
        check9("idx_t15_r9", r9, 9'h100);  // white
        check9("idx_t15_g9", g9, 9'h100);
        check9("idx_t15_b9", b9, 9'h100);

        // --------------------------------------------------------------------
        // Test 7: Mid-range channel values
        // R5=16, G6=32, B5=16 -> 0x8410
        // ch5_to_uq18(16) = {1'b0, 5'd16, 3'b100} + {8'b0, 1'b1} = 0x084 + 1 = 0x085
        // ch6_to_uq18(32) = {1'b0, 6'd32, 2'b10} + {8'b0, 1'b1} = 0x082 + 1 = 0x083
        // ch5_to_uq18(16) = 0x085
        // --------------------------------------------------------------------
        block_data = {240'd0, 16'h8410};
        texel_idx = 4'd0;
        #1;

        check9("mid_r9", r9, 9'h085);
        check9("mid_g9", g9, 9'h083);
        check9("mid_b9", b9, 9'h085);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_rgb565 Test Results ===");
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
