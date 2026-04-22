`default_nettype none

// Testbench for bc_color_block — shared BC1/BC2/BC3 color palette + interpolation
//
// Tests:
//   - 4-color opaque mode: all 4 palette entries with known endpoints
//   - 3-color + transparent mode: index 3 yields transparent flag
//   - Boundary values: all-black, all-white endpoints
//   - Interpolation accuracy against digital twin reference values
//
// See: UNIT-011.04 (Block Decompressor), DD-038, DD-039

`timescale 1ns/1ps

module tb_bc_color_block
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

    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT signals
    // ========================================================================

    reg  [15:0] color0;
    reg  [15:0] color1;
    reg  [31:0] indices;
    reg  [3:0]  texel_idx;
    reg         four_color_mode;
    wire [8:0]  r9;
    wire [8:0]  g9;
    wire [8:0]  b9;
    wire        transparent;

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    bc_color_block dut (
        .color0          (color0),
        .color1          (color1),
        .indices         (indices),
        .texel_idx       (texel_idx),
        .four_color_mode (four_color_mode),
        .r9              (r9),
        .g9              (g9),
        .b9              (b9),
        .transparent     (transparent)
    );

    // ========================================================================
    // Tests
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/bc_color_block.fst");
        $dumpvars(0, tb_bc_color_block);

        $display("=== Testing bc_color_block ===\n");

        // --------------------------------------------------------------------
        // Test 1: All-white endpoints (0xFFFF = R5=31, G6=63, B5=31)
        // 4-color mode, index 0 -> C0 = white
        // ch5_to_uq18(31) = 0x100, ch6_to_uq18(63) = 0x100
        // --------------------------------------------------------------------
        color0 = 16'hFFFF;
        color1 = 16'hFFFF;
        indices = 32'h00000000;  // All texels use index 0
        texel_idx = 4'd0;
        four_color_mode = 1'b1;
        #1;

        check9("white_c0_r9", r9, 9'h100);
        check9("white_c0_g9", g9, 9'h100);
        check9("white_c0_b9", b9, 9'h100);
        check_bit("white_c0_transparent", transparent, 1'b0);

        // --------------------------------------------------------------------
        // Test 2: All-black endpoints (0x0000)
        // 4-color mode, index 0 -> C0 = black
        // ch5_to_uq18(0) = 0x000, ch6_to_uq18(0) = 0x000
        // --------------------------------------------------------------------
        color0 = 16'h0000;
        color1 = 16'h0000;
        indices = 32'h00000000;
        texel_idx = 4'd0;
        four_color_mode = 1'b1;
        #1;

        check9("black_c0_r9", r9, 9'h000);
        check9("black_c0_g9", g9, 9'h000);
        check9("black_c0_b9", b9, 9'h000);
        check_bit("black_c0_transparent", transparent, 1'b0);

        // --------------------------------------------------------------------
        // Test 3: 4-color mode — index 1 selects C1
        // color0 = pure red (R5=31, G6=0, B5=0) = 0xF800
        // color1 = pure blue (R5=0, G6=0, B5=31) = 0x001F
        // indices: texel 0 = index 1 (bits [1:0] = 2'b01)
        // --------------------------------------------------------------------
        color0 = 16'hF800;  // R=31,G=0,B=0
        color1 = 16'h001F;  // R=0,G=0,B=31
        indices = 32'h00000001;  // Texel 0 = index 1
        texel_idx = 4'd0;
        four_color_mode = 1'b1;
        #1;

        check9("4c_idx1_r9", r9, 9'h000);  // C1.R = ch5(0) = 0
        check9("4c_idx1_g9", g9, 9'h000);  // C1.G = ch6(0) = 0
        check9("4c_idx1_b9", b9, 9'h100);  // C1.B = ch5(31) = 0x100
        check_bit("4c_idx1_transparent", transparent, 1'b0);

        // --------------------------------------------------------------------
        // Test 4: 4-color mode — index 2 selects 1/3 interpolation
        // color0 = white (0xFFFF), color1 = black (0x0000)
        // lerp(1/3): (2*0x100 + 0x000 + 1) * 683 >> 11 = (0x201) * 683 >> 11
        // = 0x201 * 683 = 352443 = 0x560EB >> 11 = 0x0AC = 172
        // = 0x0AC
        // --------------------------------------------------------------------
        color0 = 16'hFFFF;  // white
        color1 = 16'h0000;  // black
        indices = 32'h00000002;  // Texel 0 = index 2
        texel_idx = 4'd0;
        four_color_mode = 1'b1;
        #1;

        // (2*256 + 0 + 1) * 683 >> 11 = 513 * 683 = 350379 >> 11 = 171 = 0x0AB
        check9("4c_interp13_r9", r9, 9'h0AB);
        check9("4c_interp13_g9", g9, 9'h0AB);
        check9("4c_interp13_b9", b9, 9'h0AB);

        // --------------------------------------------------------------------
        // Test 5: 4-color mode — index 3 selects 2/3 interpolation
        // (0x100 + 2*0x000 + 1) * 683 >> 11 = 257 * 683 = 175531 >> 11 = 85
        // = 0x055
        // --------------------------------------------------------------------
        indices = 32'h00000003;  // Texel 0 = index 3
        #1;

        check9("4c_interp23_r9", r9, 9'h055);
        check9("4c_interp23_g9", g9, 9'h055);
        check9("4c_interp23_b9", b9, 9'h055);
        check_bit("4c_interp23_transparent", transparent, 1'b0);

        // --------------------------------------------------------------------
        // Test 6: 3-color mode — index 2 selects 1/2 interpolation
        // color0 = white (0xFFFF), color1 = black (0x0000)
        // Note: three_color_mode requires four_color_mode=0
        // lerp(1/2): (0x100 + 0x000 + 1) >> 1 = 257 >> 1 = 128 = 0x080
        // --------------------------------------------------------------------
        color0 = 16'hFFFF;
        color1 = 16'h0000;
        indices = 32'h00000002;  // Texel 0 = index 2
        texel_idx = 4'd0;
        four_color_mode = 1'b0;
        #1;

        check9("3c_interp12_r9", r9, 9'h080);
        check9("3c_interp12_g9", g9, 9'h080);
        check9("3c_interp12_b9", b9, 9'h080);
        check_bit("3c_interp12_transparent", transparent, 1'b0);

        // --------------------------------------------------------------------
        // Test 7: 3-color mode — index 3 selects transparent black
        // --------------------------------------------------------------------
        indices = 32'h00000003;  // Texel 0 = index 3
        #1;

        check9("3c_transparent_r9", r9, 9'h000);
        check9("3c_transparent_g9", g9, 9'h000);
        check9("3c_transparent_b9", b9, 9'h000);
        check_bit("3c_transparent_flag", transparent, 1'b1);

        // --------------------------------------------------------------------
        // Test 8: Texel index selection — verify different texels select
        // different 2-bit sub-indices from the index word.
        // indices = 0xE4 = 0b_11_10_01_00 in bits [7:0]
        // texel 0 -> index 0 (bits [1:0]=00)
        // texel 1 -> index 1 (bits [3:2]=01)
        // texel 2 -> index 2 (bits [5:4]=10)
        // texel 3 -> index 3 (bits [7:6]=11)
        // Using 4-color mode with red/blue endpoints for easy identification.
        // --------------------------------------------------------------------
        color0 = 16'hF800;  // pure red
        color1 = 16'h001F;  // pure blue
        indices = 32'h000000E4;
        four_color_mode = 1'b1;

        // Texel 0 -> index 0 -> C0 (red)
        texel_idx = 4'd0;
        #1;
        check9("idx_sel_t0_r9", r9, 9'h100);  // ch5(31) = 0x100
        check9("idx_sel_t0_b9", b9, 9'h000);  // ch5(0) = 0

        // Texel 1 -> index 1 -> C1 (blue)
        texel_idx = 4'd1;
        #1;
        check9("idx_sel_t1_r9", r9, 9'h000);
        check9("idx_sel_t1_b9", b9, 9'h100);

        // Texel 2 -> index 2 -> 1/3 interp
        texel_idx = 4'd2;
        #1;
        // (2*0x100 + 0x000 + 1) * 683 >> 11 = 0x0AB for R
        check9("idx_sel_t2_r9", r9, 9'h0AB);
        // (2*0x000 + 0x100 + 1) * 683 >> 11 = 0x055 for B
        check9("idx_sel_t2_b9", b9, 9'h055);

        // Texel 3 -> index 3 -> 2/3 interp
        texel_idx = 4'd3;
        #1;
        // (0x100 + 2*0x000 + 1) * 683 >> 11 = 0x055 for R
        check9("idx_sel_t3_r9", r9, 9'h055);
        // (0x000 + 2*0x100 + 1) * 683 >> 11 = 0x0AB for B
        check9("idx_sel_t3_b9", b9, 9'h0AB);

        // --------------------------------------------------------------------
        // Test 9: Pure green endpoint verification
        // color0 = pure green (0x07E0 = R5=0, G6=63, B5=0)
        // index 0 -> C0
        // --------------------------------------------------------------------
        color0 = 16'h07E0;
        color1 = 16'h0000;
        indices = 32'h00000000;
        texel_idx = 4'd0;
        four_color_mode = 1'b1;
        #1;

        check9("green_c0_r9", r9, 9'h000);
        check9("green_c0_g9", g9, 9'h100);
        check9("green_c0_b9", b9, 9'h000);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== bc_color_block Test Results ===");
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
