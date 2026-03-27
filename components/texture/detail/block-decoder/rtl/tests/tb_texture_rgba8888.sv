`default_nettype none

// Testbench for texture_rgba8888 — RGBA8888 texture decoder (FORMAT=6)
//
// Tests:
//   - ch8_to_uq18 on all 4 channels independently
//   - Fully transparent and fully opaque alpha
//   - Correct 32-bit texel extraction per index
//   - Known RGBA values
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 6), DD-038

`timescale 1ns/1ps

module tb_texture_rgba8888
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

    reg  [511:0] block_data;
    reg  [3:0]   texel_idx;
    wire [35:0]  texel_out;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_rgba8888 dut (
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
        $dumpfile("../build/sim_out/texture_rgba8888.fst");
        $dumpvars(0, tb_texture_rgba8888);

        $display("=== Testing texture_rgba8888 ===\n");

        // RGBA8888 pixel layout: [7:0]=R8, [15:8]=G8, [23:16]=B8, [31:24]=A8
        // Block: 16 texels x 32 bits = 512 bits
        // texel 0 at bits [31:0], texel 1 at bits [63:32], ...

        // --------------------------------------------------------------------
        // Test 1: Fully opaque white (R=G=B=A=255)
        // Pixel = 0xFF_FF_FF_FF (A=255, B=255, G=255, R=255)
        // ch8_to_uq18(255) = 0x100 for all channels
        // --------------------------------------------------------------------
        block_data = 512'd0;
        block_data[31:0] = 32'hFFFFFFFF;
        texel_idx = 4'd0;
        #1;

        check9("white_r9", r9, 9'h100);
        check9("white_g9", g9, 9'h100);
        check9("white_b9", b9, 9'h100);
        check9("white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: Fully transparent black (R=G=B=A=0)
        // ch8_to_uq18(0) = 0x000 for all channels
        // --------------------------------------------------------------------
        block_data = 512'd0;
        texel_idx = 4'd0;
        #1;

        check9("black_r9", r9, 9'h000);
        check9("black_g9", g9, 9'h000);
        check9("black_b9", b9, 9'h000);
        check9("black_a9", a9, 9'h000);

        // --------------------------------------------------------------------
        // Test 3: Pure red, fully opaque
        // Pixel = 0xFF_00_00_FF (A=255, B=0, G=0, R=255)
        // --------------------------------------------------------------------
        block_data = 512'd0;
        block_data[31:0] = 32'hFF0000FF;
        texel_idx = 4'd0;
        #1;

        check9("pure_red_r9", r9, 9'h100);
        check9("pure_red_g9", g9, 9'h000);
        check9("pure_red_b9", b9, 9'h000);
        check9("pure_red_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 4: Pure green, half-transparent
        // Pixel = 0x80_00_FF_00 (A=128, B=0, G=255, R=0)
        // ch8_to_uq18(128) = 0x081
        // --------------------------------------------------------------------
        block_data = 512'd0;
        block_data[31:0] = 32'h8000FF00;
        texel_idx = 4'd0;
        #1;

        check9("green_r9", r9, 9'h000);
        check9("green_g9", g9, 9'h100);
        check9("green_b9", b9, 9'h000);
        check9("green_a9", a9, 9'h081);

        // --------------------------------------------------------------------
        // Test 5: Each channel independent
        // R=64, G=128, B=192, A=255
        // ch8_to_uq18(64)  = {1'b0, 8'd64}  + {8'b0, 1'b0} = 0x040
        // ch8_to_uq18(128) = {1'b0, 8'd128} + {8'b0, 1'b1} = 0x081
        // ch8_to_uq18(192) = {1'b0, 8'd192} + {8'b0, 1'b1} = 0x0C1
        // ch8_to_uq18(255) = 0x100
        // Pixel = {A=255, B=192, G=128, R=64} = 0xFFC08040
        // --------------------------------------------------------------------
        block_data = 512'd0;
        block_data[31:0] = 32'hFFC08040;
        texel_idx = 4'd0;
        #1;

        check9("indep_r9", r9, 9'h040);
        check9("indep_g9", g9, 9'h081);
        check9("indep_b9", b9, 9'h0C1);
        check9("indep_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 6: Texel index extraction
        // texel 0 = red, texel 1 = green, texel 15 = blue
        // --------------------------------------------------------------------
        block_data = 512'd0;
        block_data[31:0]    = 32'hFF0000FF;   // texel 0 = red opaque
        block_data[63:32]   = 32'hFF00FF00;   // texel 1 = green opaque
        block_data[511:480] = 32'hFFFF0000;   // texel 15 = blue opaque

        texel_idx = 4'd0;
        #1;
        check9("idx_t0_r9", r9, 9'h100);

        texel_idx = 4'd1;
        #1;
        check9("idx_t1_g9", g9, 9'h100);

        texel_idx = 4'd15;
        #1;
        check9("idx_t15_b9", b9, 9'h100);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_rgba8888 Test Results ===");
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
