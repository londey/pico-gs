`default_nettype none

// Testbench for texture_block_decode — top-level format dispatcher
//
// Tests:
//   - Each format code (0-3, 5-7) routes to correct decoder
//   - Reserved format 4 returns transparent black (36'd0)
//   - Block word assembly for BC1, RGB565, RGBA8888
//
// See: UNIT-011.04 (Block Decompressor), INT-014, INT-032

`timescale 1ns/1ps

module tb_texture_block_decode
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

    reg [15:0] bw [0:31];  // Block words (convenience array)
    reg [3:0]  texel_idx;
    reg [3:0]  tex_format;
    wire [35:0] texel_out;

    // Convenience channel extraction
    wire [8:0] r9 = texel_out[35:27];
    wire [8:0] g9 = texel_out[26:18];
    wire [8:0] b9 = texel_out[17:9];
    wire [8:0] a9 = texel_out[8:0];

    // ========================================================================
    // DUT instantiation
    // ========================================================================

    texture_block_decode dut (
        .block_word_0  (bw[0]),
        .block_word_1  (bw[1]),
        .block_word_2  (bw[2]),
        .block_word_3  (bw[3]),
        .block_word_4  (bw[4]),
        .block_word_5  (bw[5]),
        .block_word_6  (bw[6]),
        .block_word_7  (bw[7]),
        .block_word_8  (bw[8]),
        .block_word_9  (bw[9]),
        .block_word_10 (bw[10]),
        .block_word_11 (bw[11]),
        .block_word_12 (bw[12]),
        .block_word_13 (bw[13]),
        .block_word_14 (bw[14]),
        .block_word_15 (bw[15]),
        .block_word_16 (bw[16]),
        .block_word_17 (bw[17]),
        .block_word_18 (bw[18]),
        .block_word_19 (bw[19]),
        .block_word_20 (bw[20]),
        .block_word_21 (bw[21]),
        .block_word_22 (bw[22]),
        .block_word_23 (bw[23]),
        .block_word_24 (bw[24]),
        .block_word_25 (bw[25]),
        .block_word_26 (bw[26]),
        .block_word_27 (bw[27]),
        .block_word_28 (bw[28]),
        .block_word_29 (bw[29]),
        .block_word_30 (bw[30]),
        .block_word_31 (bw[31]),
        .texel_idx     (texel_idx),
        .tex_format    (tex_format),
        .texel_out     (texel_out)
    );

    // ========================================================================
    // Helper task to clear all block words
    // ========================================================================

    task clear_words;
        integer i;
        for (i = 0; i < 32; i = i + 1) begin
            bw[i] = 16'h0000;
        end
    endtask

    // ========================================================================
    // Tests
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/texture_block_decode.fst");
        $dumpvars(0, tb_texture_block_decode);

        $display("=== Testing texture_block_decode ===\n");

        clear_words();
        texel_idx = 4'd0;

        // --------------------------------------------------------------------
        // Test 1: Format 0 (BC1) — white block
        // BC1: words 0-3 = {color0, color1, indices_lo, indices_hi}
        // color0 = 0xFFFF (word 0), color1 = 0xFFFF (word 1), indices = 0 (words 2-3)
        // Expected: all white, opaque
        // --------------------------------------------------------------------
        bw[0] = 16'hFFFF;  // color0
        bw[1] = 16'hFFFF;  // color1
        bw[2] = 16'h0000;  // indices [15:0]
        bw[3] = 16'h0000;  // indices [31:16]
        tex_format = 4'd0;
        #1;

        check9("bc1_white_r9", r9, 9'h100);
        check9("bc1_white_g9", g9, 9'h100);
        check9("bc1_white_b9", b9, 9'h100);
        check9("bc1_white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 2: Format 4 (reserved) — transparent black
        // --------------------------------------------------------------------
        tex_format = 4'd4;
        #1;

        check36("reserved_fmt4", texel_out, 36'd0);

        // --------------------------------------------------------------------
        // Test 3: Format 5 (RGB565) — pure red at texel 0
        // RGB565: words 0-15 = 16 texels
        // word 0 = 0xF800 (pure red)
        // --------------------------------------------------------------------
        clear_words();
        bw[0] = 16'hF800;
        tex_format = 4'd5;
        texel_idx = 4'd0;
        #1;

        check9("rgb565_red_r9", r9, 9'h100);
        check9("rgb565_red_g9", g9, 9'h000);
        check9("rgb565_red_b9", b9, 9'h000);
        check9("rgb565_red_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 4: Format 6 (RGBA8888) — pure green half-transparent
        // RGBA8888: words 0-31 = 16 texels (2 words each)
        // texel 0: word 0 (lo) = R8_G8, word 1 (hi) = B8_A8
        // Pixel = {A=128, B=0, G=255, R=0} = 0x8000FF00
        // word 0 = 0xFF00 (lo 16: G8=FF, R8=00)
        // word 1 = 0x8000 (hi 16: A8=80, B8=00)
        // --------------------------------------------------------------------
        clear_words();
        bw[0] = 16'hFF00;  // texel 0 lo: {G8=0xFF, R8=0x00}
        bw[1] = 16'h8000;  // texel 0 hi: {A8=0x80, B8=0x00}
        tex_format = 4'd6;
        texel_idx = 4'd0;
        #1;

        check9("rgba8888_green_r9", r9, 9'h000);
        check9("rgba8888_green_g9", g9, 9'h100);
        check9("rgba8888_green_b9", b9, 9'h000);
        check9("rgba8888_green_a9", a9, 9'h081);  // ch8(128) = 0x081

        // --------------------------------------------------------------------
        // Test 5: Format 7 (R8) — mid-gray
        // R8: words 0-7 = 16 texels (2 per word)
        // word 0 = {texel1, texel0} = {8'd0, 8'd128} = 0x0080
        // ch8_to_uq18(128) = 0x081
        // --------------------------------------------------------------------
        clear_words();
        bw[0] = 16'h0080;  // texel 0 = 128, texel 1 = 0
        tex_format = 4'd7;
        texel_idx = 4'd0;
        #1;

        check9("r8_mid_r9", r9, 9'h081);
        check9("r8_mid_g9", g9, 9'h081);
        check9("r8_mid_b9", b9, 9'h081);
        check9("r8_mid_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 6: Format 3 (BC4) — full white
        // BC4: words 0-3, same as BC3 alpha block
        // word 0 = {red1=0, red0=255} = 0x00FF
        // word 1..3 = 0 (all index 0 -> palette[0] = 255)
        // --------------------------------------------------------------------
        clear_words();
        bw[0] = 16'h00FF;  // {red1=0x00, red0=0xFF}
        tex_format = 4'd3;
        texel_idx = 4'd0;
        #1;

        check9("bc4_white_r9", r9, 9'h100);
        check9("bc4_white_a9", a9, 9'h100);

        // --------------------------------------------------------------------
        // Test 7: Format 8+ (out of range) — transparent black
        // --------------------------------------------------------------------
        tex_format = 4'd8;
        #1;
        check36("out_of_range_fmt8", texel_out, 36'd0);

        tex_format = 4'd15;
        #1;
        check36("out_of_range_fmt15", texel_out, 36'd0);

        // ====================================================================
        // Summary
        // ====================================================================
        $display("\n=== texture_block_decode Test Results ===");
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
