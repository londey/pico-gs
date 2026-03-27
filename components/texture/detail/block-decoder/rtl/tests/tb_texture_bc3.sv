`default_nettype none

// Testbench for texture_bc3 — BC3 texture decoder (FORMAT=2)
//
// Tests:
//   - Interpolated alpha (8-entry and 6-entry modes)
//   - Color block always 4-color opaque
//   - Known block data cross-checked with digital twin
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 2), DD-038

`timescale 1ns/1ps

module tb_texture_bc3
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

    texture_bc3 dut (
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
        $dumpfile("../build/sim_out/texture_bc3.fst");
        $dumpvars(0, tb_texture_bc3);

        $display("=== Testing texture_bc3 ===\n");

        // BC3 layout:
        //   [7:0]    = alpha0 (u8)
        //   [15:8]   = alpha1 (u8)
        //   [63:16]  = 48-bit alpha index table
        //   [127:64] = BC1 color block

        // --------------------------------------------------------------------
        // Test 1: 8-entry alpha (alpha0=255 > alpha1=0), all index 0
        // palette[0] = alpha0 = 255
        // ch8_to_uq18(255) = 0x100
        // Color: white, index 0
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,       // [127:96] color indices
            16'hFFFF,           // [95:80]  color1
            16'hFFFF,           // [79:64]  color0
            48'h000000000000,   // [63:16]  alpha indices (all 0)
            8'h00,              // [15:8]   alpha1
            8'hFF               // [7:0]    alpha0
        };
        texel_idx = 4'd0;
        #1;

        check9("8ent_a0_alpha", a9, 9'h100);  // ch8(255) = 0x100
        check9("8ent_a0_r9", r9, 9'h100);
        check9("8ent_a0_g9", g9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: 8-entry alpha, index 1 -> alpha1=0
        // ch8_to_uq18(0) = 0x000
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,
            16'hFFFF,
            16'hFFFF,
            48'h000000000001,   // texel 0 = alpha index 1
            8'h00,
            8'hFF
        };
        texel_idx = 4'd0;
        #1;

        check9("8ent_a1_alpha", a9, 9'h000);

        // --------------------------------------------------------------------
        // Test 3: 6-entry alpha (alpha0=0 <= alpha1=255), index 7 -> 255
        // palette[7] = 255 (special)
        // ch8_to_uq18(255) = 0x100
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,
            16'hFFFF,
            16'hFFFF,
            48'h000000000007,   // texel 0 = alpha index 7
            8'hFF,              // alpha1 = 255
            8'h00               // alpha0 = 0 (<= alpha1 -> 6-entry)
        };
        texel_idx = 4'd0;
        #1;

        check9("6ent_idx7_alpha", a9, 9'h100);  // palette[7] = 255

        // --------------------------------------------------------------------
        // Test 4: 6-entry alpha, index 6 -> 0 (special)
        // palette[6] = 0
        // ch8_to_uq18(0) = 0x000
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,
            16'hFFFF,
            16'hFFFF,
            48'h000000000006,   // texel 0 = alpha index 6
            8'hFF,
            8'h00
        };
        texel_idx = 4'd0;
        #1;

        check9("6ent_idx6_alpha", a9, 9'h000);  // palette[6] = 0

        // --------------------------------------------------------------------
        // Test 5: BC3 color always uses 4-color opaque mode
        // color0 = 0x001F (blue, < color1), color1 = 0xF800 (red)
        // Even though color0 < color1, BC3 forces 4-color mode
        // Index 3 -> 2/3 interpolation (not transparent)
        // --------------------------------------------------------------------
        block_data = {
            32'h00000003,       // color index 3 for texel 0
            16'hF800,           // color1 = red
            16'h001F,           // color0 = blue
            48'h000000000000,   // alpha indices (all 0)
            8'h00,
            8'hFF               // alpha0=255 > alpha1=0 -> 8-entry
        };
        texel_idx = 4'd0;
        #1;

        // In forced 4-color mode, index 3 = 2/3 interp
        // R: (0x000 + 2*0x100 + 1) * 683 >> 11 = 0x0AB
        check9("bc3_forced_4c_r9", r9, 9'h0AB);
        check9("bc3_forced_4c_alpha", a9, 9'h100);  // alpha0=255

        // --------------------------------------------------------------------
        // Test 6: Mid-range alpha with interpolation
        // alpha0=200, alpha1=100 -> 8-entry mode (200 > 100)
        // index 0 -> palette[0] = 200
        // ch8_to_uq18(200) = {1'b0, 8'd200} + {8'b0, 1'b1} = 0x0C8 + 1 = 0x0C9
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,
            16'hFFFF,
            16'hFFFF,
            48'h000000000000,
            8'd100,    // alpha1
            8'd200     // alpha0
        };
        texel_idx = 4'd0;
        #1;

        check9("mid_alpha_200", a9, 9'h0C9);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_bc3 Test Results ===");
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
