`default_nettype none

// Testbench for texture_bc2 — BC2 texture decoder (FORMAT=1)
//
// Tests:
//   - Explicit 4-bit alpha expansion via ch4_to_uq18
//   - Color block always uses 4-color opaque mode
//   - Alpha boundary values: 0, 15, mid-range
//
// See: UNIT-011.04 (Block Decompressor), INT-014 (Format 1), DD-038

`timescale 1ns/1ps

module tb_texture_bc2
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

    texture_bc2 dut (
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
        $dumpfile("../build/sim_out/texture_bc2.fst");
        $dumpvars(0, tb_texture_bc2);

        $display("=== Testing texture_bc2 ===\n");

        // BC2 layout: [63:0] = alpha data, [127:64] = BC1 color block
        // Alpha data: 4 u16 rows, each row has 4 texels at 4 bits each
        //   Row 0 = bits [15:0], Row 1 = bits [31:16], etc.
        //   Within row: col 0 = bits [3:0], col 1 = bits [7:4], etc.
        // Color block: [79:64]=color0, [95:80]=color1, [127:96]=indices

        // --------------------------------------------------------------------
        // Test 1: Full alpha (A4=15) with white color
        // Alpha for texel 0 (row 0, col 0): bits [3:0] = 4'hF
        // ch4_to_uq18(15) = {1'b0, 4'hF, 4'hF} + {8'b0, 1'b1} = 0x0FF + 1 = 0x100
        // Color: white endpoints, index 0 -> white
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,   // [127:96] indices (all 0 -> C0)
            16'hFFFF,       // [95:80]  color1
            16'hFFFF,       // [79:64]  color0
            16'hFFFF,       // [63:48]  alpha row 3
            16'hFFFF,       // [47:32]  alpha row 2
            16'hFFFF,       // [31:16]  alpha row 1
            16'hFFFF        // [15:0]   alpha row 0 (all 0xF)
        };
        texel_idx = 4'd0;
        #1;

        check9("full_alpha_a9", a9, 9'h100);
        check9("full_alpha_r9", r9, 9'h100);
        check9("full_alpha_g9", g9, 9'h100);
        check9("full_alpha_b9", b9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: Zero alpha (A4=0) with white color
        // ch4_to_uq18(0) = {1'b0, 4'h0, 4'h0} + {8'b0, 1'b0} = 0x000
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,   // indices
            16'hFFFF,       // color1
            16'hFFFF,       // color0
            16'h0000,       // alpha row 3
            16'h0000,       // alpha row 2
            16'h0000,       // alpha row 1
            16'h0000        // alpha row 0 (all 0)
        };
        texel_idx = 4'd0;
        #1;

        check9("zero_alpha_a9", a9, 9'h000);
        check9("zero_alpha_r9", r9, 9'h100);  // Color still white

        // --------------------------------------------------------------------
        // Test 3: Mid-range alpha (A4=8)
        // ch4_to_uq18(8) = {1'b0, 4'h8, 4'h8} + {8'b0, 1'b1} = 0x088 + 1 = 0x089
        // Alpha row 0: texel 0 col 0 = 4'h8 -> bits [3:0] = 0x8
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,   // indices
            16'hFFFF,       // color1
            16'hFFFF,       // color0
            16'h0000,       // alpha row 3
            16'h0000,       // alpha row 2
            16'h0000,       // alpha row 1
            16'h0008        // alpha row 0: col 0 = 8
        };
        texel_idx = 4'd0;
        #1;

        check9("mid_alpha_a9", a9, 9'h089);

        // --------------------------------------------------------------------
        // Test 4: Different alpha per texel
        // Row 0: col0=0, col1=5, col2=10, col3=15
        // Row 0 = {4'hF, 4'hA, 4'h5, 4'h0} = 16'hFA50
        // Texel 0 (row 0, col 0) -> A4=0x0
        // Texel 1 (row 0, col 1) -> A4=0x5
        // Texel 2 (row 0, col 2) -> A4=0xA
        // Texel 3 (row 0, col 3) -> A4=0xF
        // --------------------------------------------------------------------
        block_data = {
            32'h00000000,   // indices
            16'h0000,       // color1
            16'h0000,       // color0
            16'h0000,       // alpha row 3
            16'h0000,       // alpha row 2
            16'h0000,       // alpha row 1
            16'hFA50        // alpha row 0
        };

        texel_idx = 4'd0;
        #1;
        check9("varying_alpha_t0", a9, 9'h000);  // ch4(0) = 0

        texel_idx = 4'd1;
        #1;
        // ch4_to_uq18(5) = {1'b0, 4'h5, 4'h5} + {8'b0, 1'b0} = 0x055
        check9("varying_alpha_t1", a9, 9'h055);

        texel_idx = 4'd2;
        #1;
        // ch4_to_uq18(10) = {1'b0, 4'hA, 4'hA} + {8'b0, 1'b1} = 0x0AA + 1 = 0x0AB
        check9("varying_alpha_t2", a9, 9'h0AB);

        texel_idx = 4'd3;
        #1;
        check9("varying_alpha_t3", a9, 9'h100);  // ch4(15) = 0x100

        // --------------------------------------------------------------------
        // Test 5: BC2 always uses 4-color opaque mode for color block
        // Even when color0 <= color1, color block is 4-color (not 3-color)
        // color0 = 0x001F (blue), color1 = 0xF800 (red)
        // Normally this would be 3-color mode in BC1, but BC2 forces 4-color
        // Index 3 should give 2/3 interpolation, NOT transparent
        // --------------------------------------------------------------------
        block_data = {
            32'h00000003,   // indices: texel 0 = index 3
            16'hF800,       // color1 = red (> color0)
            16'h001F,       // color0 = blue (< color1)
            16'hFFFF,       // alpha row 3
            16'hFFFF,       // alpha row 2
            16'hFFFF,       // alpha row 1
            16'hFFFF        // alpha row 0
        };
        texel_idx = 4'd0;
        #1;

        // In 4-color mode, index 3 = 2/3 interp, not transparent
        // R: (0x000 + 2*0x100 + 1) * 683 >> 11 = 513*683>>11 = 350379>>11 = 171 = 0x0AB
        check9("bc2_forced_4c_r9", r9, 9'h0AB);
        check9("bc2_forced_4c_a9", a9, 9'h100);  // Alpha comes from explicit A4=15

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_bc2 Test Results ===");
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
