`default_nettype none

// Testbench for texture_bc1 — BC1 (DXT1) texture decoder (FORMAT=0)
//
// Tests:
//   - 4-color opaque mode (color0 > color1): all indices, A9 = 0x100
//   - 3-color transparent mode (color0 <= color1): index 3 = transparent black
//   - Known white/black block data from digital twin
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 0), DD-038

`timescale 1ns/1ps

module tb_texture_bc1
    import fp_types_pkg::*;
;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Check helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check36(input string name, input logic [35:0] actual, input logic [35:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%09x, got 0x%09x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check9(input string name, input logic [8:0] actual, input logic [8:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%03h, got 0x%03h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT signals
    // ========================================================================

    reg  [63:0]  bc1_data;
    reg  [3:0]   texel_idx;
    wire [35:0]  texel_out;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_bc1 dut (
        .bc1_data  (bc1_data),
        .texel_idx (texel_idx),
        .texel_out (texel_out)
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
        $dumpfile("../build/sim_out/texture_bc1.fst");
        $dumpvars(0, tb_texture_bc1);

        $display("=== Testing texture_bc1 ===\n");

        // --------------------------------------------------------------------
        // Test 1: All-white BC1 block (4-color opaque)
        // color0 = 0xFFFF (> color1), color1 = 0xFFFF
        // All indices = 0 -> C0 = white
        // Expected: R9=0x100, G9=0x100, B9=0x100, A9=0x100
        // --------------------------------------------------------------------
        bc1_data = {32'h00000000, 16'hFFFF, 16'hFFFF};
        texel_idx = 4'd0;
        #1;

        check9("white_r9", r9, 9'h100);
        check9("white_g9", g9, 9'h100);
        check9("white_b9", b9, 9'h100);
        check9("white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: All-black BC1 block
        // color0 = 0x0000, color1 = 0x0000
        // Expected: R9=0, G9=0, B9=0, A9=0x100 (opaque black)
        // Note: color0 == color1 -> 3-color mode, but index 0 -> C0
        // --------------------------------------------------------------------
        bc1_data = {32'h00000000, 16'h0000, 16'h0000};
        texel_idx = 4'd0;
        #1;

        check9("black_r9", r9, 9'h000);
        check9("black_g9", g9, 9'h000);
        check9("black_b9", b9, 9'h000);
        check9("black_a9", a9, 9'h100);  // Even in 3-color mode, index 0 is opaque

        // --------------------------------------------------------------------
        // Test 3: 4-color opaque — verify A9 = 0x100 for all indices
        // color0 = 0xF800 (red, > 0x001F), color1 = 0x001F (blue)
        // This is 4-color mode since 0xF800 > 0x001F
        // --------------------------------------------------------------------
        bc1_data = {32'h000000FF, 16'h001F, 16'hF800};
        // indices bits [7:0] = 0xFF = 11_11_11_11
        // All 4 texels (0-3) use index 3

        texel_idx = 4'd0;
        #1;
        check9("4c_opaque_a9", a9, 9'h100);  // 4-color mode, always opaque

        // --------------------------------------------------------------------
        // Test 4: 3-color transparent — index 3 yields transparent black
        // color0 = 0x001F (blue, <= 0xF800), color1 = 0xF800 (red)
        // This is 3-color mode since 0x001F < 0xF800
        // Texel with index 3 -> transparent black
        // --------------------------------------------------------------------
        bc1_data = {32'h00000003, 16'hF800, 16'h001F};
        // Texel 0 = index 3 (bits [1:0] = 2'b11)

        texel_idx = 4'd0;
        #1;
        check9("3c_transparent_r9", r9, 9'h000);
        check9("3c_transparent_g9", g9, 9'h000);
        check9("3c_transparent_b9", b9, 9'h000);
        check9("3c_transparent_a9", a9, 9'h000);  // Transparent!

        // --------------------------------------------------------------------
        // Test 5: 3-color mode — index 0 and 1 are still opaque
        // color0 = 0x001F (blue), color1 = 0xF800 (red)
        // Texel 0 = index 0 -> C0 (blue, opaque)
        // --------------------------------------------------------------------
        bc1_data = {32'h00000000, 16'hF800, 16'h001F};
        texel_idx = 4'd0;
        #1;
        check9("3c_idx0_r9", r9, 9'h000);   // blue has R=0
        check9("3c_idx0_b9", b9, 9'h100);   // blue has B=31 -> 0x100
        check9("3c_idx0_a9", a9, 9'h100);   // opaque

        // Texel 0 = index 1 -> C1 (red, opaque)
        bc1_data = {32'h00000001, 16'hF800, 16'h001F};
        texel_idx = 4'd0;
        #1;
        check9("3c_idx1_r9", r9, 9'h100);   // red has R=31 -> 0x100
        check9("3c_idx1_b9", b9, 9'h000);   // red has B=0
        check9("3c_idx1_a9", a9, 9'h100);   // opaque

        // --------------------------------------------------------------------
        // Test 6: Full 36-bit output format check {R9, G9, B9, A9}
        // Pure red fully opaque: R9=0x100, G9=0, B9=0, A9=0x100
        // = {9'h100, 9'h000, 9'h000, 9'h100}
        // = 36'h100_000_000_100  -- but let's compute properly
        // R9 at [35:27] = 0x100, G9 at [26:18] = 0x000, B9 at [17:9] = 0x000, A9 at [8:0] = 0x100
        // {9'h100, 9'h000, 9'h000, 9'h100} = 36 bits
        // Bit 35 = 1, bits 34:27 = 0000_0000, bits 26:18 = 0_0000_0000, bits 17:9 = 0_0000_0000, bits 8:0 = 1_0000_0000
        // = 0x800000100
        // --------------------------------------------------------------------
        bc1_data = {32'h00000000, 16'h0000, 16'hF800};  // color0=red>color1=black, idx0->C0
        texel_idx = 4'd0;
        #1;
        check36("red_full_output", texel_out, {9'h100, 9'h000, 9'h000, 9'h100});

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_bc1 Test Results ===");
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
