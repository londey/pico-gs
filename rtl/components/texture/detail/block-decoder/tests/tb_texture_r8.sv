`default_nettype none

// Testbench for texture_r8 — R8 texture decoder (FORMAT=7)
//
// Tests:
//   - Correct byte extraction for each texel index
//   - ch8_to_uq18 expansion: 0->0, 128->0x081, 255->0x100
//   - R=G=B replication, A9=0x100
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 7), DD-038

`timescale 1ns/1ps

module tb_texture_r8
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

    reg  [127:0] block_data;
    reg  [3:0]   texel_idx;
    wire [35:0]  texel_out;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_r8 dut (
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
        $dumpfile("../build/sim_out/texture_r8.fst");
        $dumpvars(0, tb_texture_r8);

        $display("=== Testing texture_r8 ===\n");

        // Block data: 16 texels x 8 bits = 128 bits, row-major
        // texel 0 at bits [7:0], texel 1 at bits [15:8], ..., texel 15 at bits [127:120]

        // --------------------------------------------------------------------
        // Test 1: All-white block (all texels = 255)
        // ch8_to_uq18(255) = 0x100
        // --------------------------------------------------------------------
        block_data = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        texel_idx = 4'd0;
        #1;

        check9("white_r9", r9, 9'h100);
        check9("white_g9", g9, 9'h100);
        check9("white_b9", b9, 9'h100);
        check9("white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: All-black block (all texels = 0)
        // ch8_to_uq18(0) = 0x000
        // --------------------------------------------------------------------
        block_data = 128'h00000000000000000000000000000000;
        texel_idx = 4'd0;
        #1;

        check9("black_r9", r9, 9'h000);
        check9("black_g9", g9, 9'h000);
        check9("black_b9", b9, 9'h000);
        check9("black_a9", a9, 9'h100);  // Always opaque

        // --------------------------------------------------------------------
        // Test 3: Mid-gray (texel = 128)
        // ch8_to_uq18(128) = {1'b0, 8'd128} + {8'b0, 1'b1} = 0x080 + 1 = 0x081
        // --------------------------------------------------------------------
        block_data = {120'd0, 8'd128};  // Texel 0 = 128
        texel_idx = 4'd0;
        #1;

        check9("mid_gray_r9", r9, 9'h081);
        check9("mid_gray_g9", g9, 9'h081);
        check9("mid_gray_b9", b9, 9'h081);

        // --------------------------------------------------------------------
        // Test 4: Texel index selection
        // Each texel has a different value; verify correct extraction
        // texel 0 = 0, texel 1 = 16, texel 2 = 32, ..., texel 15 = 240
        // --------------------------------------------------------------------
        block_data = {8'd240, 8'd224, 8'd208, 8'd192,
                      8'd176, 8'd160, 8'd144, 8'd128,
                      8'd112, 8'd96,  8'd80,  8'd64,
                      8'd48,  8'd32,  8'd16,  8'd0};

        // Texel 0: value = 0
        texel_idx = 4'd0;
        #1;
        check9("idx_sel_t0", r9, 9'h000);

        // Texel 1: value = 16
        // ch8_to_uq18(16) = {1'b0, 8'd16} + {8'b0, 1'b0} = 0x010
        texel_idx = 4'd1;
        #1;
        check9("idx_sel_t1", r9, 9'h010);

        // Texel 8: value = 128
        texel_idx = 4'd8;
        #1;
        check9("idx_sel_t8", r9, 9'h081);

        // Texel 15: value = 240
        // ch8_to_uq18(240) = {1'b0, 8'd240} + {8'b0, 1'b1} = 0x0F0 + 1 = 0x0F1
        texel_idx = 4'd15;
        #1;
        check9("idx_sel_t15", r9, 9'h0F1);

        // --------------------------------------------------------------------
        // Test 5: Full output format: R=G=B, A=0x100
        // texel=255: {0x100, 0x100, 0x100, 0x100}
        // --------------------------------------------------------------------
        block_data = 128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        texel_idx = 4'd0;
        #1;
        check36("white_full_output", texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_r8 Test Results ===");
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
