// Spec-ref: ver_005_texture_decoder.md `0000000000000000` 1970-01-01
//
// Testbench for texture format decoders and related pixel pipeline modules:
//   texture_bc1, texture_bc2, texture_bc3, texture_bc4,
//   texture_rgb565, texture_rgba8888, texture_r8,
//   texel_promote, stipple, format-select mux

`timescale 1ns/1ps

module texture_decoder_tb
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
    // texture_bc1 DUT
    // ========================================================================

    reg          bc1_cache_mode;
    reg  [63:0]  bc1_data;
    reg  [3:0]   bc1_texel_idx;
    wire [35:0]  bc1_texel_out;
    wire [17:0]  bc1_rgba5652 = bc1_texel_out[17:0];

    texture_bc1 uut_bc1 (
        .bc1_data(bc1_data),
        .texel_idx(bc1_texel_idx),
        .cache_mode(bc1_cache_mode),
        .texel_out(bc1_texel_out)
    );

    // ========================================================================
    // texture_bc2 DUT
    // ========================================================================

    reg          bc2_cache_mode;
    reg  [127:0] bc2_block_data;
    reg  [3:0]   bc2_texel_idx;
    wire [35:0]  bc2_texel_out;
    wire [17:0]  bc2_rgba5652 = bc2_texel_out[17:0];

    texture_bc2 uut_bc2 (
        .block_data(bc2_block_data),
        .texel_idx(bc2_texel_idx),
        .cache_mode(bc2_cache_mode),
        .texel_out(bc2_texel_out)
    );

    // ========================================================================
    // texture_bc3 DUT
    // ========================================================================

    reg          bc3_cache_mode;
    reg  [127:0] bc3_block_data;
    reg  [3:0]   bc3_texel_idx;
    wire [35:0]  bc3_texel_out;
    wire [17:0]  bc3_rgba5652 = bc3_texel_out[17:0];

    texture_bc3 uut_bc3 (
        .block_data(bc3_block_data),
        .texel_idx(bc3_texel_idx),
        .cache_mode(bc3_cache_mode),
        .texel_out(bc3_texel_out)
    );

    // ========================================================================
    // texture_bc4 DUT
    // ========================================================================

    reg          bc4_cache_mode;
    reg  [63:0]  bc4_block_data;
    reg  [3:0]   bc4_texel_idx;
    wire [35:0]  bc4_texel_out;
    wire [17:0]  bc4_rgba5652 = bc4_texel_out[17:0];

    texture_bc4 uut_bc4 (
        .block_data(bc4_block_data),
        .texel_idx(bc4_texel_idx),
        .cache_mode(bc4_cache_mode),
        .texel_out(bc4_texel_out)
    );

    // ========================================================================
    // texture_rgb565 DUT
    // ========================================================================

    reg          rgb565_cache_mode;
    reg  [255:0] rgb565_block_data;
    reg  [3:0]   rgb565_texel_idx;
    wire [35:0]  rgb565_texel_out;
    wire [17:0]  rgb565_rgba5652 = rgb565_texel_out[17:0];

    texture_rgb565 uut_rgb565 (
        .block_data(rgb565_block_data),
        .texel_idx(rgb565_texel_idx),
        .cache_mode(rgb565_cache_mode),
        .texel_out(rgb565_texel_out)
    );

    // ========================================================================
    // texture_rgba8888 DUT
    // ========================================================================

    reg          rgba8888_cache_mode;
    reg  [511:0] rgba8888_block_data;
    reg  [3:0]   rgba8888_texel_idx;
    wire [35:0]  rgba8888_texel_out;
    wire [17:0]  rgba8888_rgba5652 = rgba8888_texel_out[17:0];

    texture_rgba8888 uut_rgba8888 (
        .block_data(rgba8888_block_data),
        .texel_idx(rgba8888_texel_idx),
        .cache_mode(rgba8888_cache_mode),
        .texel_out(rgba8888_texel_out)
    );

    // ========================================================================
    // texture_r8 DUT
    // ========================================================================

    reg          r8_cache_mode;
    reg  [127:0] r8_block_data;
    reg  [3:0]   r8_texel_idx;
    wire [35:0]  r8_texel_out;
    wire [17:0]  r8_rgba5652 = r8_texel_out[17:0];

    texture_r8 uut_r8 (
        .block_data(r8_block_data),
        .texel_idx(r8_texel_idx),
        .cache_mode(r8_cache_mode),
        .texel_out(r8_texel_out)
    );

    // ========================================================================
    // texel_promote DUT
    // ========================================================================

    reg          promote_cache_mode;
    reg  [35:0]  promote_texel_in;
    wire [15:0]  promote_r_q412;
    wire [15:0]  promote_g_q412;
    wire [15:0]  promote_b_q412;
    wire [15:0]  promote_a_q412;

    texel_promote uut_promote (
        .cache_mode(promote_cache_mode),
        .texel_in(promote_texel_in),
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
    // Format-Select Mux (3-bit tex_format, 7 decoder outputs)
    // ========================================================================

    reg  [2:0]   mux_tex_format;
    reg  [17:0]  mux_result;
    reg  [35:0]  mux_result_36;

    always_comb begin
        case (mux_tex_format)
            3'd0:    mux_result = bc1_rgba5652;
            3'd1:    mux_result = bc2_rgba5652;
            3'd2:    mux_result = bc3_rgba5652;
            3'd3:    mux_result = bc4_rgba5652;
            3'd4:    mux_result = rgb565_rgba5652;
            3'd5:    mux_result = rgba8888_rgba5652;
            3'd6:    mux_result = r8_rgba5652;
            default: mux_result = 18'b0;
        endcase
    end

    always_comb begin
        case (mux_tex_format)
            3'd0:    mux_result_36 = bc1_texel_out;
            3'd1:    mux_result_36 = bc2_texel_out;
            3'd2:    mux_result_36 = bc3_texel_out;
            3'd3:    mux_result_36 = bc4_texel_out;
            3'd4:    mux_result_36 = rgb565_texel_out;
            3'd5:    mux_result_36 = rgba8888_texel_out;
            3'd6:    mux_result_36 = r8_texel_out;
            default: mux_result_36 = 36'b0;
        endcase
    end

    // ========================================================================
    // Test body
    // ========================================================================

    initial begin
        $dumpfile("texture_decoder.vcd");
        $dumpvars(0, texture_decoder_tb);

        $display("=== Texture Decoder Testbench ===\n");

        // Initialize all cache_mode registers to 0 (RGBA5652)
        bc1_cache_mode     = 1'b0;
        bc2_cache_mode     = 1'b0;
        bc3_cache_mode     = 1'b0;
        bc4_cache_mode     = 1'b0;
        rgb565_cache_mode  = 1'b0;
        rgba8888_cache_mode = 1'b0;
        r8_cache_mode      = 1'b0;

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
        // Test 1b: texture_rgb565 CACHE_MODE=1 (UQ1.8)
        // ============================================================
        $display("--- Test 1b: texture_rgb565 CACHE_MODE=1 ---");

        rgb565_cache_mode = 1'b1;

        // Red pixel: R5=31, G6=0, B5=0 -> R9=0x100, G9=0, B9=0, A9=0x1FF
        // texture_rgb565 output order: {A9, B9, G9, R9}
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = 16'hF800;
        rgb565_texel_idx = 4'd0;
        #10;
        check36("rgb565 cm1 red pixel",
                rgb565_texel_out, {9'h1FF, 9'h000, 9'h000, 9'h100});

        // Green pixel: R5=0, G6=63, B5=0 -> R9=0, G9=0x100, B9=0, A9=0x1FF
        rgb565_block_data[31:16] = 16'h07E0;
        rgb565_texel_idx = 4'd1;
        #10;
        check36("rgb565 cm1 green pixel",
                rgb565_texel_out, {9'h1FF, 9'h000, 9'h100, 9'h000});

        // Blue pixel: R5=0, G6=0, B5=31 -> R9=0, G9=0, B9=0x100, A9=0x1FF
        rgb565_block_data[47:32] = 16'h001F;
        rgb565_texel_idx = 4'd2;
        #10;
        check36("rgb565 cm1 blue pixel",
                rgb565_texel_out, {9'h1FF, 9'h100, 9'h000, 9'h000});

        rgb565_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 2b: texture_rgba8888 CACHE_MODE=1 (UQ1.8)
        // ============================================================
        $display("--- Test 2b: texture_rgba8888 CACHE_MODE=1 ---");

        rgba8888_cache_mode = 1'b1;

        // R=0xFF, G=0x80, B=0x40, A=0xC0
        // R9={0xFF,1}=0x1FF, G9={0x80,1}=0x101, B9={0x40,0}=0x080, A9={0xC0,1}=0x181
        // texture_rgba8888 output order: {A9, B9, G9, R9}
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'hC0, 8'h40, 8'h80, 8'hFF};
        rgba8888_texel_idx = 4'd0;
        #10;
        check36("rgba8888 cm1 texel0",
                rgba8888_texel_out, {9'h181, 9'h080, 9'h101, 9'h1FF});

        // Full opaque white: R=G=B=A=0xFF -> all channels 9'h1FF
        rgba8888_block_data[63:32] = {8'hFF, 8'hFF, 8'hFF, 8'hFF};
        rgba8888_texel_idx = 4'd1;
        #10;
        check36("rgba8888 cm1 white opaque",
                rgba8888_texel_out, {9'h1FF, 9'h1FF, 9'h1FF, 9'h1FF});

        // All zero (transparent black): R=G=B=A=0x00
        rgba8888_block_data[95:64] = 32'h0;
        rgba8888_texel_idx = 4'd2;
        #10;
        check36("rgba8888 cm1 black transparent",
                rgba8888_texel_out, {9'h000, 9'h000, 9'h000, 9'h000});

        rgba8888_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 3b: texture_r8 CACHE_MODE=1 (UQ1.8)
        // ============================================================
        $display("--- Test 3b: texture_r8 CACHE_MODE=1 ---");

        r8_cache_mode = 1'b1;

        // R8=0xA0 -> ch9={0xA0, 1}=9'h141, A9=0x1FF
        // texture_r8 output order: {A9, ch9, ch9, ch9}
        r8_block_data = 128'h0;
        r8_block_data[7:0] = 8'hA0;
        r8_texel_idx = 4'd0;
        #10;
        check36("r8 cm1 0xA0",
                r8_texel_out, {9'h1FF, 9'h141, 9'h141, 9'h141});

        // R8=0xFF -> ch9={0xFF, 1}=9'h1FF, A9=0x1FF
        r8_block_data[15:8] = 8'hFF;
        r8_texel_idx = 4'd1;
        #10;
        check36("r8 cm1 0xFF",
                r8_texel_out, {9'h1FF, 9'h1FF, 9'h1FF, 9'h1FF});

        // R8=0x00 -> ch9=9'h000, A9=0x1FF
        r8_block_data[23:16] = 8'h00;
        r8_texel_idx = 4'd2;
        #10;
        check36("r8 cm1 0x00",
                r8_texel_out, {9'h1FF, 9'h000, 9'h000, 9'h000});

        r8_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 4: texel_promote
        // ============================================================
        $display("--- Test 4: texel_promote ---");

        // Step 4: texel_promote CACHE_MODE=0 (RGBA5652) acceptance test.
        // The RTL under test is texel_promote.sv, which delegates to the named functions
        // in fp_types_pkg.sv: promote_r5_to_q412, promote_g6_to_q412, promote_b5_to_q412,
        // promote_a2_to_q412. Expected output values are derived from the INT-032 formulas
        // and serve as the acceptance test for those package functions.
        // If any output differs from expected, verify fp_types_pkg.sv against INT-032
        // before modifying test vectors.

        promote_cache_mode = 1'b0;

        // Test A2=2'b11 -> Q4.12 = 0x1000
        promote_texel_in = {18'b0, 5'd0, 6'd0, 5'd0, 2'b11};
        #10;
        check16("promote A2=11 -> 0x1000", promote_a_q412, 16'h1000);

        // Test A2=2'b00 -> Q4.12 = 0x0000
        promote_texel_in = {18'b0, 5'd0, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote A2=00 -> 0x0000", promote_a_q412, 16'h0000);

        // Test R5=5'b11111 (max)
        // {3'b000, 5'b11111, 5'b11111, 3'b111} = 0x1FFF
        // This maps to approximately 2.0 in Q4.12 but is the maximal
        // MSB-replication output for a 5-bit input.
        promote_texel_in = {18'b0, 5'b11111, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote R5=31 -> 0x1FFF", promote_r_q412, 16'h1FFF);

        // Test R5=0 -> 0x0000
        promote_texel_in = {18'b0, 5'b00000, 6'd0, 5'd0, 2'b00};
        #10;
        check16("promote R5=0 -> 0x0000", promote_r_q412, 16'h0000);

        // Step 5: texel_promote CACHE_MODE=1 (UQ1.8) acceptance test.
        // UQ1.8 bit layout: texel_in[35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9.
        // promote_uq18_to_q412: {3'b000, channel[8:0], 4'b0000}
        $display("--- Test 4b: texel_promote CACHE_MODE=1 (UQ1.8) ---");

        promote_cache_mode = 1'b1;

        // UQ1.8 0x000 (0.0) -> Q4.12 0x0000
        promote_texel_in = {9'h000, 9'h000, 9'h000, 9'h000};
        #10;
        check16("promote UQ1.8 R=0x000 -> 0x0000", promote_r_q412, 16'h0000);
        check16("promote UQ1.8 G=0x000 -> 0x0000", promote_g_q412, 16'h0000);
        check16("promote UQ1.8 B=0x000 -> 0x0000", promote_b_q412, 16'h0000);
        check16("promote UQ1.8 A=0x000 -> 0x0000", promote_a_q412, 16'h0000);

        // UQ1.8 0x100 (1.0) -> Q4.12 0x1000
        promote_texel_in = {9'h100, 9'h100, 9'h100, 9'h100};
        #10;
        check16("promote UQ1.8 R=0x100 -> 0x1000", promote_r_q412, 16'h1000);
        check16("promote UQ1.8 G=0x100 -> 0x1000", promote_g_q412, 16'h1000);
        check16("promote UQ1.8 B=0x100 -> 0x1000", promote_b_q412, 16'h1000);
        check16("promote UQ1.8 A=0x100 -> 0x1000", promote_a_q412, 16'h1000);

        // UQ1.8 0x080 (0.5) -> Q4.12 0x0800
        promote_texel_in = {9'h080, 9'h080, 9'h080, 9'h080};
        #10;
        check16("promote UQ1.8 R=0x080 -> 0x0800", promote_r_q412, 16'h0800);
        check16("promote UQ1.8 G=0x080 -> 0x0800", promote_g_q412, 16'h0800);
        check16("promote UQ1.8 B=0x080 -> 0x0800", promote_b_q412, 16'h0800);
        check16("promote UQ1.8 A=0x080 -> 0x0800", promote_a_q412, 16'h0800);

        // UQ1.8 0x1FF (max ~1.996) -> Q4.12 0x1FF0
        promote_texel_in = {9'h1FF, 9'h1FF, 9'h1FF, 9'h1FF};
        #10;
        check16("promote UQ1.8 R=0x1FF -> 0x1FF0", promote_r_q412, 16'h1FF0);
        check16("promote UQ1.8 G=0x1FF -> 0x1FF0", promote_g_q412, 16'h1FF0);
        check16("promote UQ1.8 B=0x1FF -> 0x1FF0", promote_b_q412, 16'h1FF0);
        check16("promote UQ1.8 A=0x1FF -> 0x1FF0", promote_a_q412, 16'h1FF0);

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
        // Test 6: texture_bc1 — 4-color opaque mode
        // ============================================================
        $display("--- Test 6: texture_bc1 (4-color opaque) ---");

        // Construct a BC1 block:
        //   color0 = 0xF800 (pure red: R5=31, G6=0, B5=0)
        //   color1 = 0x001F (pure blue: R5=0, G6=0, B5=31)
        //   color0 > color1, so 4-color opaque mode
        //   Index word: texel 0 = index 0 (color0), texel 1 = index 1 (color1),
        //               texel 2 = index 2 (lerp 1/3), texel 3 = index 3 (lerp 2/3)
        //   indices = {texel3[1:0], texel2[1:0], texel1[1:0], texel0[1:0], ...}
        //   For texels 0-3: indices[7:0] = 8'b11_10_01_00 = 8'hE4
        //   Remaining texels all index 0.
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'hF800;  // color0 = red
        bc1_data[31:16] = 16'h001F;  // color1 = blue
        bc1_data[39:32] = 8'hE4;     // texels 0-3: indices 0,1,2,3
        bc1_data[63:40] = 24'h0;     // texels 4-15: index 0

        // texel 0: index 0 -> color0 = red, A2=11
        bc1_texel_idx = 4'd0;
        #10;
        check18("bc1 4c texel0 (color0=red)", bc1_rgba5652,
                {5'd31, 6'd0, 5'd0, 2'b11});

        // texel 1: index 1 -> color1 = blue, A2=11
        bc1_texel_idx = 4'd1;
        #10;
        check18("bc1 4c texel1 (color1=blue)", bc1_rgba5652,
                {5'd0, 6'd0, 5'd31, 2'b11});

        // texel 2: index 2 -> lerp(1/3) = (2*red + blue + 1)/3
        // R: (2*31 + 0 + 1)/3 = 63/3 = 21
        // G: (2*0 + 0 + 1)/3 = 1/3 = 0
        // B: (2*0 + 31 + 1)/3 = 32/3 = 10
        bc1_texel_idx = 4'd2;
        #10;
        check18("bc1 4c texel2 (lerp 1/3)", bc1_rgba5652,
                {5'd21, 6'd0, 5'd10, 2'b11});

        // texel 3: index 3 -> lerp(2/3) = (red + 2*blue + 1)/3
        // R: (31 + 0 + 1)/3 = 32/3 = 10
        // G: (0 + 0 + 1)/3 = 0
        // B: (0 + 62 + 1)/3 = 63/3 = 21
        bc1_texel_idx = 4'd3;
        #10;
        check18("bc1 4c texel3 (lerp 2/3)", bc1_rgba5652,
                {5'd10, 6'd0, 5'd21, 2'b11});

        // ============================================================
        // Test 7: texture_bc1 — 3-color + transparent mode
        // ============================================================
        $display("--- Test 7: texture_bc1 (3-color + transparent) ---");

        // color0 = 0x001F (blue), color1 = 0xF800 (red)
        // color0 < color1, so 3-color + transparent mode
        // texel 0: index 0 (color0=blue), texel 1: index 1 (color1=red)
        // texel 2: index 2 (lerp 1/2), texel 3: index 3 (transparent)
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'h001F;  // color0 = blue
        bc1_data[31:16] = 16'hF800;  // color1 = red
        bc1_data[39:32] = 8'hE4;     // texels 0-3: indices 0,1,2,3

        // texel 0: color0 = blue, opaque
        bc1_texel_idx = 4'd0;
        #10;
        check18("bc1 3c texel0 (blue)", bc1_rgba5652,
                {5'd0, 6'd0, 5'd31, 2'b11});

        // texel 1: color1 = red, opaque
        bc1_texel_idx = 4'd1;
        #10;
        check18("bc1 3c texel1 (red)", bc1_rgba5652,
                {5'd31, 6'd0, 5'd0, 2'b11});

        // texel 2: index 2 -> lerp(1/2) = (blue + red + 1)/2
        // R: (0 + 31 + 1)/2 = 16
        // G: (0 + 0 + 1)/2 = 0
        // B: (31 + 0 + 1)/2 = 16
        bc1_texel_idx = 4'd2;
        #10;
        check18("bc1 3c texel2 (lerp 1/2)", bc1_rgba5652,
                {5'd16, 6'd0, 5'd16, 2'b11});

        // texel 3: index 3 -> transparent (A2=00)
        bc1_texel_idx = 4'd3;
        #10;
        check18("bc1 3c texel3 (transparent)", bc1_rgba5652,
                {5'd0, 6'd0, 5'd0, 2'b00});

        // ============================================================
        // Test 8: texture_bc2 — explicit alpha + BC1 color
        // ============================================================
        $display("--- Test 8: texture_bc2 ---");

        // BC2 block: 128 bits
        //   [63:0]   = alpha data: 4 rows of u16, each row has 4 x 4-bit alpha
        //   [127:64] = BC1 color block (always 4-color opaque)
        // Set texel 0 alpha = 0xF (4'b1111 -> A2 = 2'b11)
        // Set texel 1 alpha = 0x0 (4'b0000 -> A2 = 2'b00)
        // Color: color0=0xFFFF (white), color1=0x0000 (black)
        //   All texels index 0 -> color0 (white)
        bc2_block_data = 128'h0;
        bc2_block_data[3:0]    = 4'hF;     // texel 0 alpha = 0xF
        bc2_block_data[7:4]    = 4'h0;     // texel 1 alpha = 0x0
        bc2_block_data[79:64]  = 16'hFFFF; // color0 = white
        bc2_block_data[95:80]  = 16'h0000; // color1 = black
        bc2_block_data[127:96] = 32'h0;    // all texels index 0

        bc2_texel_idx = 4'd0;
        #10;
        // White with full alpha: RGB565 white = {31,63,31}, A2=11
        check18("bc2 texel0 alpha=F", bc2_rgba5652,
                {5'd31, 6'd63, 5'd31, 2'b11});

        bc2_texel_idx = 4'd1;
        #10;
        // White with zero alpha: A4=0 -> A2=00
        check18("bc2 texel1 alpha=0", bc2_rgba5652,
                {5'd31, 6'd63, 5'd31, 2'b00});

        // ============================================================
        // Test 9: texture_bc4 — single channel
        // ============================================================
        $display("--- Test 9: texture_bc4 ---");

        // BC4 block: 64 bits
        //   [7:0]   = red0 = 0xFF (255)
        //   [15:8]  = red1 = 0x00 (0)
        //   [63:16] = 3-bit indices, texel 0 = index 0 -> red0 = 255
        bc4_block_data = 64'h0;
        bc4_block_data[7:0]  = 8'hFF;  // red0
        bc4_block_data[15:8] = 8'h00;  // red1
        // texel 0: index = bits [18:16] = 000 -> palette[0] = red0 = 255

        bc4_texel_idx = 4'd0;
        #10;
        // R8=0xFF: R5=11111, G6=111111, B5=11111, A2=11
        check18("bc4 texel0 red0=0xFF", bc4_rgba5652,
                {5'd31, 6'd63, 5'd31, 2'b11});

        // ============================================================
        // Test 6b: texture_bc1 CACHE_MODE=1 — 4-color opaque
        // ============================================================
        $display("--- Test 6b: texture_bc1 CACHE_MODE=1 (4-color opaque) ---");

        bc1_cache_mode = 1'b1;

        // Same block as Test 6: color0=0xF800 (red), color1=0x001F (blue)
        // color0 > color1 -> 4-color opaque mode
        // UQ1.8 endpoints:
        //   c0_r9 = {1'b0, 31, 31[4:2]} + 31[4] = 9'h0FF + 1 = 9'h100
        //   c0_g9 = {1'b0, 0, 0} + 0 = 9'h000
        //   c0_b9 = 9'h000
        //   c1_r9 = 9'h000, c1_g9 = 9'h000
        //   c1_b9 = 9'h100 (B5=31, same expansion as R5=31)
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'hF800;  // color0 = red
        bc1_data[31:16] = 16'h001F;  // color1 = blue
        bc1_data[39:32] = 8'hE4;     // texels 0-3: indices 0,1,2,3

        // texel 0: index 0 -> palette[0] = {c0_r9, c0_g9, c0_b9, 9'h100}
        // BC1 output order: {R9, G9, B9, A9}
        bc1_texel_idx = 4'd0;
        #10;
        check36("bc1 cm1 4c texel0 (red)",
                bc1_texel_out, {9'h100, 9'h000, 9'h000, 9'h100});

        // texel 1: index 1 -> palette[1] = {c1_r9, c1_g9, c1_b9, 9'h100}
        bc1_texel_idx = 4'd1;
        #10;
        check36("bc1 cm1 4c texel1 (blue)",
                bc1_texel_out, {9'h000, 9'h000, 9'h100, 9'h100});

        // texel 2: index 2 -> 1/3 interpolation at 9-bit
        // sum13_r9 = 2*0x100 + 0x000 + 1 = 0x201
        // prod13_r9 = 0x201 * 683 = 0x201 * 0x2AB = let me compute:
        //   0x201 = 513; 513 * 683 = 350379; 350379 >> 11 = 171 = 0xAB
        // sum13_g9 = 0 + 0 + 0 + 1 = 1; 1 * 683 >> 11 = 0
        // sum13_b9 = 0 + 0 + 0x100 + 1 = 0x101 = 257; 257 * 683 = 175531; >> 11 = 85 = 0x55
        bc1_texel_idx = 4'd2;
        #10;
        check36("bc1 cm1 4c texel2 (lerp 1/3)",
                bc1_texel_out, {9'h0AB, 9'h000, 9'h055, 9'h100});

        // texel 3: index 3 -> 2/3 interpolation
        // sum23_r9 = 0x100 + 0 + 0 + 1 = 0x101 = 257; 257*683>>11 = 85 = 0x55
        // sum23_b9 = 0 + 2*0x100 + 1 = 0x201 = 513; 513*683>>11 = 171 = 0xAB
        bc1_texel_idx = 4'd3;
        #10;
        check36("bc1 cm1 4c texel3 (lerp 2/3)",
                bc1_texel_out, {9'h055, 9'h000, 9'h0AB, 9'h100});

        bc1_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 8b: texture_bc2 CACHE_MODE=1
        // ============================================================
        $display("--- Test 8b: texture_bc2 CACHE_MODE=1 ---");

        bc2_cache_mode = 1'b1;

        // White color block (color0=0xFFFF, color1=0x0000), texel 0 index 0
        // Alpha: texel 0 alpha4 = 0xF
        // c0_r9 = expand(R5=31) = 0x100
        // c0_g9 = expand(G6=63) = 0x100
        // c0_b9 = expand(B5=31) = 0x100
        // alpha9 = {1'b0, 4'hF, 4'hF} + {8'b0, 1'b1} = 9'h0FF + 1 = 9'h100
        // BC2 output order: {R9, G9, B9, A9}
        bc2_block_data = 128'h0;
        bc2_block_data[3:0]    = 4'hF;     // texel 0 alpha = 0xF
        bc2_block_data[7:4]    = 4'h0;     // texel 1 alpha = 0x0
        bc2_block_data[79:64]  = 16'hFFFF; // color0 = white
        bc2_block_data[95:80]  = 16'h0000; // color1 = black
        bc2_block_data[127:96] = 32'h0;    // all texels index 0

        bc2_texel_idx = 4'd0;
        #10;
        check36("bc2 cm1 texel0 alpha=F",
                bc2_texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // texel 1: alpha4 = 0x0 -> alpha9 = {1'b0, 4'h0, 4'h0} + 0 = 9'h000
        bc2_texel_idx = 4'd1;
        #10;
        check36("bc2 cm1 texel1 alpha=0",
                bc2_texel_out, {9'h100, 9'h100, 9'h100, 9'h000});

        bc2_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 7b: texture_bc3 CACHE_MODE=1
        // ============================================================
        $display("--- Test 7b: texture_bc3 CACHE_MODE=1 ---");

        bc3_cache_mode = 1'b1;

        // Alpha: alpha0=0x80, alpha1=0x00, texel 0 idx=000 -> alpha0=0x80
        // alpha9 = {1'b0, 0x80} + 0x80[7] = 9'h080 + 1 = 9'h081
        // Color block: color0=0x07FF (cyan: R=0, G=63, B=31), color1=0x0000
        // c0_r9=0, c0_g9=0x100, c0_b9=0x100
        // Texel 0 index 0 -> palette[0] = {c0_r9, c0_g9, c0_b9, alpha9}
        bc3_block_data = 128'h0;
        bc3_block_data[7:0]    = 8'h80;    // alpha0 = 0x80
        bc3_block_data[15:8]   = 8'h00;    // alpha1 = 0x00
        bc3_block_data[63:16]  = 48'h0;    // all alpha indices = 0
        bc3_block_data[79:64]  = 16'h07FF; // color0 = cyan
        bc3_block_data[95:80]  = 16'h0000; // color1 = black
        bc3_block_data[127:96] = 32'h0;    // all texels index 0

        bc3_texel_idx = 4'd0;
        #10;
        check36("bc3 cm1 texel0 cyan alpha=0x80",
                bc3_texel_out, {9'h000, 9'h100, 9'h100, 9'h081});

        bc3_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 9b: texture_bc4 CACHE_MODE=1
        // ============================================================
        $display("--- Test 9b: texture_bc4 CACHE_MODE=1 ---");

        bc4_cache_mode = 1'b1;

        // red0=0xFF, red1=0x00, texel 0 idx=000 -> decoded_red=0xFF
        // red9 = {1'b0, 0xFF} + 1 = 9'h100
        // BC4 output: {red9, red9, red9, 9'h100}
        bc4_block_data = 64'h0;
        bc4_block_data[7:0]  = 8'hFF;
        bc4_block_data[15:8] = 8'h00;

        bc4_texel_idx = 4'd0;
        #10;
        check36("bc4 cm1 texel0 red0=0xFF",
                bc4_texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // red0=0x80, red1=0x00, texel 0 idx=000 -> decoded_red=0x80
        // red9 = {1'b0, 0x80} + 1 = 9'h081
        bc4_block_data[7:0] = 8'h80;
        bc4_texel_idx = 4'd0;
        #10;
        check36("bc4 cm1 texel0 red0=0x80",
                bc4_texel_out, {9'h081, 9'h081, 9'h081, 9'h100});

        bc4_cache_mode = 1'b0;  // restore

        // ============================================================
        // Test 10: Format-select mux wiring (VER-005 step 10)
        // ============================================================
        $display("--- Test 10: Format-select mux (7-format, 3-bit) ---");

        // Set up DISTINCTIVE data for each decoder so all 7 outputs are
        // provably unique.  This ensures the mux test can detect any
        // miswiring (two decoders producing identical output would mask a
        // mux routing error).
        //
        // Expected RGBA5652 outputs (texel 0 for all decoders):
        //   BC1  (0): green       -> {R5=0,  G6=63, B5=0,  A2=11}
        //   BC2  (1): white a=10  -> {R5=31, G6=63, B5=31, A2=10}
        //   BC3  (2): cyan  a=10  -> {R5=0,  G6=63, B5=31, A2=10}
        //   BC4  (3): grey  a=11  -> {R5=16, G6=32, B5=16, A2=11}
        //   RGB  (4): blue        -> {R5=0,  G6=0,  B5=31, A2=11}
        //   RGBA (5): custom      -> {R5=16, G6=16, B5=24, A2=11}
        //   R8   (6): grey 0x60   -> {R5=12, G6=24, B5=12, A2=11}

        // --- BC1 (format 0): pure green, 4-color opaque mode ---
        // color0 = 0x07E0 (R5=0, G6=63, B5=0), color1 = 0x0000
        // color0 > color1 -> 4-color mode; texel 0 index=0 -> color0
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'h07E0;  // color0 = green
        bc1_data[31:16] = 16'h0000;  // color1 = black
        bc1_data[63:32] = 32'h0;     // all texels index 0
        bc1_texel_idx = 4'd0;

        // --- BC2 (format 1): white with A4=0x8 -> A2=10 ---
        // Color block: color0=0xFFFF (white), color1=0x0, all indices=0
        // Alpha: texel 0 = 4'h8 (A4[3:2]=2'b10)
        bc2_block_data = 128'h0;
        bc2_block_data[3:0]    = 4'h8;     // texel 0 alpha = 0x8
        bc2_block_data[79:64]  = 16'hFFFF; // color0 = white
        bc2_block_data[95:80]  = 16'h0000; // color1 = black
        bc2_block_data[127:96] = 32'h0;    // all texels index 0
        bc2_texel_idx = 4'd0;

        // --- BC3 (format 2): cyan with alpha0=0x80 -> A8[7:6]=10 ---
        // Alpha: alpha0=0x80, alpha1=0x00, texel 0 alpha_index=000 -> alpha0=0x80
        // Color block: color0=0x07FF (R5=0, G6=63, B5=31=cyan), color1=0x0
        bc3_block_data = 128'h0;
        bc3_block_data[7:0]    = 8'h80;    // alpha0 = 0x80
        bc3_block_data[15:8]   = 8'h00;    // alpha1 = 0x00
        bc3_block_data[63:16]  = 48'h0;    // all alpha indices = 0 (-> alpha0)
        bc3_block_data[79:64]  = 16'h07FF; // color0 = cyan (R=0, G=63, B=31)
        bc3_block_data[95:80]  = 16'h0000; // color1 = black
        bc3_block_data[127:96] = 32'h0;    // all texels index 0
        bc3_texel_idx = 4'd0;

        // --- BC4 (format 3): red0=0x80, texel 0 idx=0 -> R8=0x80 ---
        // R5=0x80[7:3]=16, G6=0x80[7:2]=32, B5=16, A2=11
        bc4_block_data = 64'h0;
        bc4_block_data[7:0]  = 8'h80;  // red0 = 0x80
        bc4_block_data[15:8] = 8'h00;  // red1 = 0x00
        // texel 0: 3-bit index = 000 -> palette[0] = red0 = 0x80
        bc4_texel_idx = 4'd0;

        // --- RGB565 (format 4): pure blue = 0x001F ---
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = 16'h001F;  // R=0, G=0, B=31
        rgb565_texel_idx = 4'd0;

        // --- RGBA8888 (format 5): R=0x80, G=0x40, B=0xC0, A=0xFF ---
        // R5=0x80[7:3]=16, G6=0x40[7:2]=16, B5=0xC0[7:3]=24, A2=0xFF[7:6]=11
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'hFF, 8'hC0, 8'h40, 8'h80};
        rgba8888_texel_idx = 4'd0;

        // --- R8 (format 6): R8=0x60 ---
        // R5=0x60[7:3]=12, G6=0x60[7:2]=24, B5=12, A2=11
        r8_block_data = 128'h0;
        r8_block_data[7:0] = 8'h60;
        r8_texel_idx = 4'd0;

        #10;

        // Pre-computed expected RGBA5652 for each decoder (constants, not wires)
        // to double-check both mux routing AND decoder correctness.

        // Verify mux for format 0 (BC1): expect pure green, opaque
        mux_tex_format = 3'd0;
        #10;
        check18("mux fmt=0 (BC1) routes decoder", mux_result, bc1_rgba5652);
        check18("mux fmt=0 (BC1) expected value", mux_result,
                {5'd0, 6'd63, 5'd0, 2'b11});

        // Verify mux for format 1 (BC2): expect white, A2=10
        mux_tex_format = 3'd1;
        #10;
        check18("mux fmt=1 (BC2) routes decoder", mux_result, bc2_rgba5652);
        check18("mux fmt=1 (BC2) expected value", mux_result,
                {5'd31, 6'd63, 5'd31, 2'b10});

        // Verify mux for format 2 (BC3): expect cyan, A2=10
        mux_tex_format = 3'd2;
        #10;
        check18("mux fmt=2 (BC3) routes decoder", mux_result, bc3_rgba5652);
        check18("mux fmt=2 (BC3) expected value", mux_result,
                {5'd0, 6'd63, 5'd31, 2'b10});

        // Verify mux for format 3 (BC4): expect grey, A2=11
        mux_tex_format = 3'd3;
        #10;
        check18("mux fmt=3 (BC4) routes decoder", mux_result, bc4_rgba5652);
        check18("mux fmt=3 (BC4) expected value", mux_result,
                {5'd16, 6'd32, 5'd16, 2'b11});

        // Verify mux for format 4 (RGB565): expect pure blue, opaque
        mux_tex_format = 3'd4;
        #10;
        check18("mux fmt=4 (RGB565) routes decoder", mux_result, rgb565_rgba5652);
        check18("mux fmt=4 (RGB565) expected value", mux_result,
                {5'd0, 6'd0, 5'd31, 2'b11});

        // Verify mux for format 5 (RGBA8888): expect {16,16,24,11}
        mux_tex_format = 3'd5;
        #10;
        check18("mux fmt=5 (RGBA8888) routes decoder", mux_result, rgba8888_rgba5652);
        check18("mux fmt=5 (RGBA8888) expected value", mux_result,
                {5'd16, 6'd16, 5'd24, 2'b11});

        // Verify mux for format 6 (R8): expect {12,24,12,11}
        mux_tex_format = 3'd6;
        #10;
        check18("mux fmt=6 (R8) routes decoder", mux_result, r8_rgba5652);
        check18("mux fmt=6 (R8) expected value", mux_result,
                {5'd12, 6'd24, 5'd12, 2'b11});

        // Verify mux for format 7 (reserved -> zero)
        mux_tex_format = 3'd7;
        #10;
        check18("mux fmt=7 (reserved) -> zero", mux_result, 18'b0);

        // ============================================================
        // Test 10b: Format-select mux 36-bit routing with cache_mode
        // ============================================================
        $display("--- Test 10b: Format-select mux 36-bit (CACHE_MODE=1) ---");

        // Switch all decoders to CACHE_MODE=1 and verify the 36-bit mux
        // routes the correct full-width output for each format.
        bc1_cache_mode      = 1'b1;
        bc2_cache_mode      = 1'b1;
        bc3_cache_mode      = 1'b1;
        bc4_cache_mode      = 1'b1;
        rgb565_cache_mode   = 1'b1;
        rgba8888_cache_mode = 1'b1;
        r8_cache_mode       = 1'b1;

        #10;

        // Verify 36-bit mux routes each decoder's full output
        mux_tex_format = 3'd0;
        #10;
        check36("mux36 fmt=0 (BC1) routes decoder", mux_result_36, bc1_texel_out);

        mux_tex_format = 3'd1;
        #10;
        check36("mux36 fmt=1 (BC2) routes decoder", mux_result_36, bc2_texel_out);

        mux_tex_format = 3'd2;
        #10;
        check36("mux36 fmt=2 (BC3) routes decoder", mux_result_36, bc3_texel_out);

        mux_tex_format = 3'd3;
        #10;
        check36("mux36 fmt=3 (BC4) routes decoder", mux_result_36, bc4_texel_out);

        mux_tex_format = 3'd4;
        #10;
        check36("mux36 fmt=4 (RGB565) routes decoder", mux_result_36, rgb565_texel_out);

        mux_tex_format = 3'd5;
        #10;
        check36("mux36 fmt=5 (RGBA8888) routes decoder", mux_result_36, rgba8888_texel_out);

        mux_tex_format = 3'd6;
        #10;
        check36("mux36 fmt=6 (R8) routes decoder", mux_result_36, r8_texel_out);

        mux_tex_format = 3'd7;
        #10;
        check36("mux36 fmt=7 (reserved) -> zero", mux_result_36, 36'b0);

        // Restore all decoders to CACHE_MODE=0
        bc1_cache_mode      = 1'b0;
        bc2_cache_mode      = 1'b0;
        bc3_cache_mode      = 1'b0;
        bc4_cache_mode      = 1'b0;
        rgb565_cache_mode   = 1'b0;
        rgba8888_cache_mode = 1'b0;
        r8_cache_mode       = 1'b0;

        // ============================================================
        // Test 11: RGBA5652 bit layout verification (VER-005 step 11)
        // ============================================================
        $display("--- Test 11: RGBA5652 bit layout ---");

        // Confirm RGBA5652 = {R5[17:13], G6[12:7], B5[6:2], A2[1:0]}
        // per INT-032 specification.
        // Use the RGB565 decoder with a known pixel to verify bit positions.
        // Input: R5=5'b10101, G6=6'b101010, B5=5'b01010 -> 0xAA8A (RGB565)
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = {5'b10101, 6'b101010, 5'b01010}; // 0xAA8A
        rgb565_texel_idx = 4'd0;
        #10;

        // Verify each field position individually
        check18("rgba5652 R5 at [17:13]", {13'b0, rgb565_rgba5652[17:13]},
                {13'b0, 5'b10101});
        check18("rgba5652 G6 at [12:7]",  {12'b0, rgb565_rgba5652[12:7]},
                {12'b0, 6'b101010});
        check18("rgba5652 B5 at [6:2]",   {13'b0, rgb565_rgba5652[6:2]},
                {13'b0, 5'b01010});
        check18("rgba5652 A2 at [1:0]",   {16'b0, rgb565_rgba5652[1:0]},
                {16'b0, 2'b11});

        // Cross-check: full 18-bit value matches {R5, G6, B5, A2=11}
        check18("rgba5652 full layout", rgb565_rgba5652,
                {5'b10101, 6'b101010, 5'b01010, 2'b11});

        // ============================================================
        // Test 11b: UQ1.8 bit layout verification (VER-005 step 12, CACHE_MODE=1)
        // ============================================================
        $display("--- Test 11b: UQ1.8 bit layout (CACHE_MODE=1) ---");

        // Use RGBA8888 decoder with known per-channel values in CACHE_MODE=1
        // to verify the UQ1.8 bit field positions.
        // R=0x80(R9=0x101), G=0x40(G9=0x080), B=0xC0(B9=0x181), A=0x20(A9=0x040)
        // texture_rgba8888 output order: {A9, B9, G9, R9}
        // [35:27]=A9=0x040, [26:18]=B9=0x181, [17:9]=G9=0x080, [8:0]=R9=0x101
        rgba8888_cache_mode = 1'b1;
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'h20, 8'hC0, 8'h40, 8'h80};
        rgba8888_texel_idx = 4'd0;
        #10;

        // Verify each 9-bit field position independently.
        // RGBA8888 in CACHE_MODE=1 uses {A9, B9, G9, R9} ordering, so:
        //   [8:0] = R9, [17:9] = G9, [26:18] = B9, [35:27] = A9
        check18("uq18 R9 at [8:0]",   {9'b0, rgba8888_texel_out[8:0]},
                {9'b0, 9'h101});
        check18("uq18 G9 at [17:9]",  {9'b0, rgba8888_texel_out[17:9]},
                {9'b0, 9'h080});
        check18("uq18 B9 at [26:18]", {9'b0, rgba8888_texel_out[26:18]},
                {9'b0, 9'h181});
        check18("uq18 A9 at [35:27]", {9'b0, rgba8888_texel_out[35:27]},
                {9'b0, 9'h040});

        // Cross-check: full 36-bit value
        check36("uq18 full layout", rgba8888_texel_out,
                {9'h040, 9'h181, 9'h080, 9'h101});

        // Also verify BC1 layout (which uses {R9, G9, B9, A9} ordering) for Step 12.
        // BC1 CACHE_MODE=1 with color0=0xF800 (pure red), texel 0 = index 0.
        // Expected: R9=0x100, G9=0x000, B9=0x000, A9=0x100
        // {R9[35:27], G9[26:18], B9[17:9], A9[8:0]}
        bc1_cache_mode = 1'b1;
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'hF800;
        bc1_data[31:16] = 16'h001F;
        bc1_data[63:32] = 32'h0;
        bc1_texel_idx = 4'd0;
        #10;

        check18("bc1 uq18 R9 at [35:27]", {9'b0, bc1_texel_out[35:27]},
                {9'b0, 9'h100});
        check18("bc1 uq18 G9 at [26:18]", {9'b0, bc1_texel_out[26:18]},
                {9'b0, 9'h000});
        check18("bc1 uq18 B9 at [17:9]",  {9'b0, bc1_texel_out[17:9]},
                {9'b0, 9'h000});
        check18("bc1 uq18 A9 at [8:0]",   {9'b0, bc1_texel_out[8:0]},
                {9'b0, 9'h100});

        bc1_cache_mode = 1'b0;
        rgba8888_cache_mode = 1'b0;

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
