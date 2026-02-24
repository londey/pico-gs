// Testbench for texture format decoders and related pixel pipeline modules:
//   texture_rgb565, texture_rgba8888, texture_r8, texel_promote, stipple

`timescale 1ns/1ps

module texture_decoder_tb;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // ========================================================================
    // Check helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check18(input string name, input logic [17:0] actual, input logic [17:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%05x, got 0x%05x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04x, got 0x%04x", name, expected, actual);
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
    // texture_rgb565 DUT
    // ========================================================================

    reg  [255:0] rgb565_block_data;
    reg  [3:0]   rgb565_texel_idx;
    wire [17:0]  rgb565_rgba5652;

    texture_rgb565 uut_rgb565 (
        .block_data(rgb565_block_data),
        .texel_idx(rgb565_texel_idx),
        .rgba5652(rgb565_rgba5652)
    );

    // ========================================================================
    // texture_rgba8888 DUT
    // ========================================================================

    reg  [511:0] rgba8888_block_data;
    reg  [3:0]   rgba8888_texel_idx;
    wire [17:0]  rgba8888_rgba5652;

    texture_rgba8888 uut_rgba8888 (
        .block_data(rgba8888_block_data),
        .texel_idx(rgba8888_texel_idx),
        .rgba5652(rgba8888_rgba5652)
    );

    // ========================================================================
    // texture_r8 DUT
    // ========================================================================

    reg  [127:0] r8_block_data;
    reg  [3:0]   r8_texel_idx;
    wire [17:0]  r8_rgba5652;

    texture_r8 uut_r8 (
        .block_data(r8_block_data),
        .texel_idx(r8_texel_idx),
        .rgba5652(r8_rgba5652)
    );

    // ========================================================================
    // texel_promote DUT
    // ========================================================================

    reg  [17:0]  promote_rgba5652;
    wire [15:0]  promote_r_q412;
    wire [15:0]  promote_g_q412;
    wire [15:0]  promote_b_q412;
    wire [15:0]  promote_a_q412;

    texel_promote uut_promote (
        .rgba5652(promote_rgba5652),
        .r_q412(promote_r_q412),
        .g_q412(promote_g_q412),
        .b_q412(promote_b_q412),
        .a_q412(promote_a_q412)
    );

    // ========================================================================
    // stipple DUT
    // ========================================================================

    reg  [2:0]   stip_frag_x;
    reg  [2:0]   stip_frag_y;
    reg          stip_stipple_en;
    reg  [63:0]  stip_pattern;
    wire         stip_discard;

    stipple uut_stipple (
        .frag_x(stip_frag_x),
        .frag_y(stip_frag_y),
        .stipple_en(stip_stipple_en),
        .stipple_pattern(stip_pattern),
        .discard(stip_discard)
    );

    // ========================================================================
    // Test body
    // ========================================================================

    initial begin
        $dumpfile("texture_decoder.vcd");
        $dumpvars(0, texture_decoder_tb);

        $display("=== Texture Decoder Testbench ===\n");

        // ============================================================
        // Test 1: texture_rgb565
        // ============================================================
        $display("--- Test 1: texture_rgb565 ---");

        // Place a known RGB565 value at texel index 0:
        // RGB565: R5=11111(0x1F), G6=000000(0x00), B5=00000(0x00) = 0xF800
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = 16'hF800;  // texel 0
        rgb565_texel_idx = 4'd0;
        #10;

        // RGBA5652 = {R5(11111), G6(000000), B5(00000), A2(11)}
        // = {5'b11111, 6'b000000, 5'b00000, 2'b11} = 18'b11_1110_0000_0000_0011 = 18'h3E003
        check18("rgb565 red pixel", rgb565_rgba5652, 18'b11_1110_0000_0000_0011);

        // Test another texel: full green at index 1
        // G6=111111 = 0x07E0
        rgb565_block_data[31:16] = 16'h07E0;
        rgb565_texel_idx = 4'd1;
        #10;

        // RGBA5652 = {R5(00000), G6(111111), B5(00000), A2(11)}
        check18("rgb565 green pixel", rgb565_rgba5652, 18'b00_0001_1111_1000_0011);

        // ============================================================
        // Test 2: texture_rgba8888
        // ============================================================
        $display("--- Test 2: texture_rgba8888 ---");

        // RGBA8888 layout: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A
        // Place texel 0: R=0xFF, G=0x80, B=0x40, A=0xC0
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'hC0, 8'h40, 8'h80, 8'hFF};
        rgba8888_texel_idx = 4'd0;
        #10;

        // Truncation: R8[7:3]=5'b11111, G8[7:2]=6'b100000, B8[7:3]=5'b01000, A8[7:6]=2'b11
        // RGBA5652 = {R5, G6, B5, A2}
        check18("rgba8888 truncated", rgba8888_rgba5652,
                {5'b11111, 6'b100000, 5'b01000, 2'b11});

        // ============================================================
        // Test 3: texture_r8
        // ============================================================
        $display("--- Test 3: texture_r8 ---");

        // Feed byte 0xA0 at texel 0
        r8_block_data = 128'h0;
        r8_block_data[7:0] = 8'hA0;
        r8_texel_idx = 4'd0;
        #10;

        // R8=0xA0=10100000
        // R5 = R8[7:3] = 5'b10100 = 0x14
        // G6 = R8[7:2] = 6'b101000 = 0x28
        // B5 = R8[7:3] = 5'b10100 = 0x14
        // A2 = 11 (opaque)
        check18("r8 0xA0 decode", r8_rgba5652,
                {5'b10100, 6'b101000, 5'b10100, 2'b11});

        // ============================================================
        // Test 4: texel_promote
        // ============================================================
        $display("--- Test 4: texel_promote ---");

        // Test A2=2'b11 -> Q4.12 = 0x1000
        promote_rgba5652 = {5'd0, 6'd0, 5'd0, 2'b11};
        #10;
        check16("promote A2=11 -> 0x1000", promote_a_q412, 16'h1000);

        // Test A2=2'b00 -> Q4.12 = 0x0000
        promote_rgba5652 = {5'd0, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote A2=00 -> 0x0000", promote_a_q412, 16'h0000);

        // Test R5=5'b11111 (max)
        // {3'b000, 5'b11111, 5'b11111, 3'b111} = 0x1FFF
        // This maps to approximately 2.0 in Q4.12 but is the maximal
        // MSB-replication output for a 5-bit input.
        promote_rgba5652 = {5'b11111, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote R5=31 -> 0x1FFF", promote_r_q412, 16'h1FFF);

        // Test R5=0 -> 0x0000
        promote_rgba5652 = {5'b00000, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote R5=0 -> 0x0000", promote_r_q412, 16'h0000);

        // ============================================================
        // Test 5: stipple
        // ============================================================
        $display("--- Test 5: stipple ---");

        // Pattern: alternating bits 0xAAAA_AAAA_AAAA_AAAA
        // bit 0 (x=0,y=0) = 0 -> discard=1 (when stipple_en=1)
        // bit 1 (x=1,y=0) = 1 -> discard=0
        stip_pattern = 64'hAAAA_AAAA_AAAA_AAAA;
        stip_stipple_en = 1'b1;

        stip_frag_x = 3'd0;
        stip_frag_y = 3'd0;
        #10;
        check_bit("stipple x=0,y=0 discard", stip_discard, 1'b1);

        stip_frag_x = 3'd1;
        stip_frag_y = 3'd0;
        #10;
        check_bit("stipple x=1,y=0 pass", stip_discard, 1'b0);

        // When stipple disabled, always pass
        stip_stipple_en = 1'b0;
        stip_frag_x = 3'd0;
        stip_frag_y = 3'd0;
        #10;
        check_bit("stipple disabled pass", stip_discard, 1'b0);

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
