`default_nettype none

// Spec-ref: ver_005_texture_decoder.md `0000000000000000` 1970-01-01
//
// Testbench for texture format decoders and related pixel pipeline modules:
//   texture_bc1, texture_bc2, texture_bc3, texture_bc4, texture_bc5,
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

    reg  [63:0]  bc1_data;       // BC1 block data
    reg  [3:0]   bc1_texel_idx;  // Texel index within 4x4 block
    wire [35:0]  bc1_texel_out;  // 36-bit UQ1.8 output {R9, G9, B9, A9}

    texture_bc1 uut_bc1 (
        .bc1_data(bc1_data),
        .texel_idx(bc1_texel_idx),
        .texel_out(bc1_texel_out)
    );

    // ========================================================================
    // texture_bc2 DUT
    // ========================================================================

    reg  [127:0] bc2_block_data;  // BC2 block data
    reg  [3:0]   bc2_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  bc2_texel_out;   // 36-bit UQ1.8 output {R9, G9, B9, A9}

    texture_bc2 uut_bc2 (
        .block_data(bc2_block_data),
        .texel_idx(bc2_texel_idx),
        .texel_out(bc2_texel_out)
    );

    // ========================================================================
    // texture_bc3 DUT
    // ========================================================================

    reg  [127:0] bc3_block_data;  // BC3 block data
    reg  [3:0]   bc3_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  bc3_texel_out;   // 36-bit UQ1.8 output {R9, G9, B9, A9}

    texture_bc3 uut_bc3 (
        .block_data(bc3_block_data),
        .texel_idx(bc3_texel_idx),
        .texel_out(bc3_texel_out)
    );

    // ========================================================================
    // texture_bc4 DUT
    // ========================================================================

    reg  [63:0]  bc4_block_data;  // BC4 block data
    reg  [3:0]   bc4_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  bc4_texel_out;   // 36-bit UQ1.8 output {R9, G9, B9, A9}

    texture_bc4 uut_bc4 (
        .block_data(bc4_block_data),
        .texel_idx(bc4_texel_idx),
        .texel_out(bc4_texel_out)
    );

    // ========================================================================
    // texture_bc5 DUT
    // ========================================================================

    reg  [127:0] bc5_block_data;  // BC5 block data
    reg  [3:0]   bc5_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  bc5_texel_out;   // 36-bit UQ1.8 output {R9, G9, B9, A9}

    texture_bc5 uut_bc5 (
        .block_data(bc5_block_data),
        .texel_idx(bc5_texel_idx),
        .texel_out(bc5_texel_out)
    );

    // ========================================================================
    // texture_rgb565 DUT
    // ========================================================================

    reg  [255:0] rgb565_block_data;  // RGB565 block data
    reg  [3:0]   rgb565_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  rgb565_texel_out;   // 36-bit UQ1.8 output {A9, B9, G9, R9}

    texture_rgb565 uut_rgb565 (
        .block_data(rgb565_block_data),
        .texel_idx(rgb565_texel_idx),
        .texel_out(rgb565_texel_out)
    );

    // ========================================================================
    // texture_rgba8888 DUT
    // ========================================================================

    reg  [511:0] rgba8888_block_data;  // RGBA8888 block data
    reg  [3:0]   rgba8888_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  rgba8888_texel_out;   // 36-bit UQ1.8 output {A9, B9, G9, R9}

    texture_rgba8888 uut_rgba8888 (
        .block_data(rgba8888_block_data),
        .texel_idx(rgba8888_texel_idx),
        .texel_out(rgba8888_texel_out)
    );

    // ========================================================================
    // texture_r8 DUT
    // ========================================================================

    reg  [127:0] r8_block_data;  // R8 block data
    reg  [3:0]   r8_texel_idx;   // Texel index within 4x4 block
    wire [35:0]  r8_texel_out;   // 36-bit UQ1.8 output {A9, B9, G9, R9}

    texture_r8 uut_r8 (
        .block_data(r8_block_data),
        .texel_idx(r8_texel_idx),
        .texel_out(r8_texel_out)
    );

    // ========================================================================
    // texel_promote DUT
    // ========================================================================

    reg  [35:0]  promote_texel_in;  // 36-bit UQ1.8 input
    wire [15:0]  promote_r_q412;    // Q4.12 red output
    wire [15:0]  promote_g_q412;    // Q4.12 green output
    wire [15:0]  promote_b_q412;    // Q4.12 blue output
    wire [15:0]  promote_a_q412;    // Q4.12 alpha output

    texel_promote uut_promote (
        .texel_in(promote_texel_in),
        .r_q412(promote_r_q412),
        .g_q412(promote_g_q412),
        .b_q412(promote_b_q412),
        .a_q412(promote_a_q412)
    );

    // ========================================================================
    // stipple DUT
    // ========================================================================

    reg  [2:0]   stip_frag_x;     // Fragment x coordinate (3-bit)
    reg  [2:0]   stip_frag_y;     // Fragment y coordinate (3-bit)
    reg          stip_stipple_en;  // Stipple enable
    reg  [63:0]  stip_pattern;    // 8x8 stipple pattern
    wire         stip_discard;    // Discard output

    stipple uut_stipple (
        .frag_x(stip_frag_x),
        .frag_y(stip_frag_y),
        .stipple_en(stip_stipple_en),
        .stipple_pattern(stip_pattern),
        .discard(stip_discard)
    );

    // ========================================================================
    // Format-Select Mux (4-bit tex_format, 8 decoder outputs, 36-bit)
    // ========================================================================

    reg  [3:0]   mux_tex_format;  // Texture format selector (matches tex_format_e)
    reg  [35:0]  mux_result;      // Selected 36-bit UQ1.8 texel

    always_comb begin
        case (mux_tex_format)
            4'd0:    mux_result = bc1_texel_out;      // BC1
            4'd1:    mux_result = bc2_texel_out;      // BC2
            4'd2:    mux_result = bc3_texel_out;      // BC3
            4'd3:    mux_result = bc4_texel_out;      // BC4
            4'd4:    mux_result = bc5_texel_out;      // BC5
            4'd5:    mux_result = rgb565_texel_out;   // RGB565
            4'd6:    mux_result = rgba8888_texel_out; // RGBA8888
            4'd7:    mux_result = r8_texel_out;       // R8
            default: mux_result = 36'b0;
        endcase
    end

    // ========================================================================
    // Test body
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/texture_decoder.vcd");
        $dumpvars(0, texture_decoder_tb);

        $display("=== Texture Decoder Testbench ===\n");

        // ============================================================
        // Test 1: texture_rgb565 (UQ1.8 output)
        // ============================================================
        $display("--- Test 1: texture_rgb565 ---");

        // Place a known RGB565 value at texel index 0:
        // RGB565: R5=31, G6=0, B5=0 = 0xF800
        // R9 = {31, 31[4:2]} + 31[4] = {5'b11111, 3'b111} + 1 = 9'h0FF + 1 = 9'h100
        // G9 = {0, 0} + 0 = 9'h000
        // B9 = {0, 0} + 0 = 9'h000
        // A9 = 9'h1FF (opaque)
        // Output order: {A9, B9, G9, R9}
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = 16'hF800;
        rgb565_texel_idx = 4'd0;
        #10;
        check36("rgb565 red pixel",
                rgb565_texel_out, {9'h1FF, 9'h000, 9'h000, 9'h100});

        // Test another texel: full green at index 1
        // G6=63 -> G9 = {6'b111111, 2'b11} + 1 = 9'h0FF + 1 = 9'h100
        // R9=0, B9=0, A9=0x1FF
        rgb565_block_data[31:16] = 16'h07E0;
        rgb565_texel_idx = 4'd1;
        #10;
        check36("rgb565 green pixel",
                rgb565_texel_out, {9'h1FF, 9'h000, 9'h100, 9'h000});

        // Blue pixel: R5=0, G6=0, B5=31 -> B9=0x100, A9=0x1FF
        rgb565_block_data[47:32] = 16'h001F;
        rgb565_texel_idx = 4'd2;
        #10;
        check36("rgb565 blue pixel",
                rgb565_texel_out, {9'h1FF, 9'h100, 9'h000, 9'h000});

        // ============================================================
        // Test 2: texture_rgba8888 (UQ1.8 output)
        // ============================================================
        $display("--- Test 2: texture_rgba8888 ---");

        // RGBA8888 layout: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A
        // UQ1.8 expansion: ch9 = {ch8[7:0], ch8[7]}
        // R=0xFF -> R9 = {8'hFF, 1'b1} = 9'h1FF
        // G=0x80 -> G9 = {8'h80, 1'b1} = 9'h101
        // B=0x40 -> B9 = {8'h40, 1'b0} = 9'h080
        // A=0xC0 -> A9 = {8'hC0, 1'b1} = 9'h181
        // Output order: {A9, B9, G9, R9}

        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'hC0, 8'h40, 8'h80, 8'hFF};
        rgba8888_texel_idx = 4'd0;
        #10;
        check36("rgba8888 texel0",
                rgba8888_texel_out, {9'h181, 9'h080, 9'h101, 9'h1FF});

        // Full opaque white: R=G=B=A=0xFF -> all channels 9'h1FF
        rgba8888_block_data[63:32] = {8'hFF, 8'hFF, 8'hFF, 8'hFF};
        rgba8888_texel_idx = 4'd1;
        #10;
        check36("rgba8888 white opaque",
                rgba8888_texel_out, {9'h1FF, 9'h1FF, 9'h1FF, 9'h1FF});

        // All zero (transparent black): R=G=B=A=0x00
        rgba8888_block_data[95:64] = 32'h0;
        rgba8888_texel_idx = 4'd2;
        #10;
        check36("rgba8888 black transparent",
                rgba8888_texel_out, {9'h000, 9'h000, 9'h000, 9'h000});

        // ============================================================
        // Test 3: texture_r8 (UQ1.8 output)
        // ============================================================
        $display("--- Test 3: texture_r8 ---");

        // UQ1.8 expansion: ch9 = {R8[7:0], R8[7]}; replicated to R/G/B; A9=9'h1FF
        // R8=0xA0 -> ch9 = {8'hA0, 1'b1} = 9'h141
        // Output order: {A9, ch9, ch9, ch9}

        r8_block_data = 128'h0;
        r8_block_data[7:0] = 8'hA0;
        r8_texel_idx = 4'd0;
        #10;
        check36("r8 0xA0",
                r8_texel_out, {9'h1FF, 9'h141, 9'h141, 9'h141});

        // R8=0xFF -> ch9 = 9'h1FF, A9=0x1FF
        r8_block_data[15:8] = 8'hFF;
        r8_texel_idx = 4'd1;
        #10;
        check36("r8 0xFF",
                r8_texel_out, {9'h1FF, 9'h1FF, 9'h1FF, 9'h1FF});

        // R8=0x00 -> ch9 = 9'h000, A9=0x1FF
        r8_block_data[23:16] = 8'h00;
        r8_texel_idx = 4'd2;
        #10;
        check36("r8 0x00",
                r8_texel_out, {9'h1FF, 9'h000, 9'h000, 9'h000});

        // ============================================================
        // Test 4: texel_promote (UQ1.8 input)
        // ============================================================
        $display("--- Test 4: texel_promote ---");

        // UQ1.8 bit layout: texel_in[35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9.
        // promote_uq18_to_q412: {3'b000, channel[8:0], 4'b0000}

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
        //   indices: texel0=0, texel1=1, texel2=2, texel3=3
        //   indices[7:0] = 8'b11_10_01_00 = 8'hE4
        //
        // UQ1.8 endpoints:
        //   c0_r9 = expand(R5=31) = 9'h100
        //   c0_g9 = expand(G6=0) = 9'h000
        //   c0_b9 = expand(B5=0) = 9'h000
        //   c1_r9 = 9'h000, c1_g9 = 9'h000, c1_b9 = 9'h100
        // Output order: {R9, G9, B9, A9}
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'hF800;  // color0 = red
        bc1_data[31:16] = 16'h001F;  // color1 = blue
        bc1_data[39:32] = 8'hE4;     // texels 0-3: indices 0,1,2,3
        bc1_data[63:40] = 24'h0;     // texels 4-15: index 0

        // texel 0: index 0 -> color0 = red
        bc1_texel_idx = 4'd0;
        #10;
        check36("bc1 4c texel0 (color0=red)",
                bc1_texel_out, {9'h100, 9'h000, 9'h000, 9'h100});

        // texel 1: index 1 -> color1 = blue
        bc1_texel_idx = 4'd1;
        #10;
        check36("bc1 4c texel1 (color1=blue)",
                bc1_texel_out, {9'h000, 9'h000, 9'h100, 9'h100});

        // texel 2: index 2 -> 1/3 interpolation at UQ1.8
        // sum13_r9 = 2*0x100 + 0x000 + 1 = 0x201; 0x201*683>>11 = 171 = 0xAB
        // sum13_g9 = 0 + 0 + 1 = 1; 1*683>>11 = 0
        // sum13_b9 = 0 + 0 + 0x100 + 1 = 0x101 = 257; 257*683>>11 = 85 = 0x55
        bc1_texel_idx = 4'd2;
        #10;
        check36("bc1 4c texel2 (lerp 1/3)",
                bc1_texel_out, {9'h0AB, 9'h000, 9'h055, 9'h100});

        // texel 3: index 3 -> 2/3 interpolation
        // sum23_r9 = 0x100 + 0 + 1 = 0x101 = 257; 257*683>>11 = 85 = 0x55
        // sum23_b9 = 0 + 2*0x100 + 1 = 0x201 = 513; 513*683>>11 = 171 = 0xAB
        bc1_texel_idx = 4'd3;
        #10;
        check36("bc1 4c texel3 (lerp 2/3)",
                bc1_texel_out, {9'h055, 9'h000, 9'h0AB, 9'h100});

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
        // c0_b9 = expand(B5=31) = 9'h100, c0_r9=0, c0_g9=0, A9=0x100
        bc1_texel_idx = 4'd0;
        #10;
        check36("bc1 3c texel0 (blue)",
                bc1_texel_out, {9'h000, 9'h000, 9'h100, 9'h100});

        // texel 1: color1 = red, opaque
        // c1_r9 = expand(R5=31) = 9'h100
        bc1_texel_idx = 4'd1;
        #10;
        check36("bc1 3c texel1 (red)",
                bc1_texel_out, {9'h100, 9'h000, 9'h000, 9'h100});

        // texel 2: index 2 -> lerp(1/2) = (blue + red + 1)/2 at UQ1.8
        // R: (0 + 0x100 + 1)/2 = 0x101/2 = 0x80
        // G: (0 + 0 + 1)/2 = 0
        // B: (0x100 + 0 + 1)/2 = 0x101/2 = 0x80
        bc1_texel_idx = 4'd2;
        #10;
        check36("bc1 3c texel2 (lerp 1/2)",
                bc1_texel_out, {9'h080, 9'h000, 9'h080, 9'h100});

        // texel 3: index 3 -> transparent (A9=0)
        bc1_texel_idx = 4'd3;
        #10;
        check36("bc1 3c texel3 (transparent)",
                bc1_texel_out, {9'h000, 9'h000, 9'h000, 9'h000});

        // ============================================================
        // Test 8: texture_bc2 — explicit alpha + BC1 color
        // ============================================================
        $display("--- Test 8: texture_bc2 ---");

        // BC2 block: 128 bits
        //   [63:0]   = alpha data: 4 rows of u16, each row has 4 x 4-bit alpha
        //   [127:64] = BC1 color block (always 4-color opaque)
        // Color: color0=0xFFFF (white), color1=0x0000 (black)
        //   All texels index 0 -> color0 (white)
        // c0_r9 = expand(R5=31) = 9'h100
        // c0_g9 = expand(G6=63) = 9'h100
        // c0_b9 = expand(B5=31) = 9'h100
        bc2_block_data = 128'h0;
        bc2_block_data[3:0]    = 4'hF;     // texel 0 alpha = 0xF
        bc2_block_data[7:4]    = 4'h0;     // texel 1 alpha = 0x0
        bc2_block_data[79:64]  = 16'hFFFF; // color0 = white
        bc2_block_data[95:80]  = 16'h0000; // color1 = black
        bc2_block_data[127:96] = 32'h0;    // all texels index 0

        // texel 0: white with alpha4=0xF -> alpha9 = expand(4'hF) = 9'h100
        bc2_texel_idx = 4'd0;
        #10;
        check36("bc2 texel0 alpha=F",
                bc2_texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // texel 1: white with alpha4=0x0 -> alpha9 = 9'h000
        bc2_texel_idx = 4'd1;
        #10;
        check36("bc2 texel1 alpha=0",
                bc2_texel_out, {9'h100, 9'h100, 9'h100, 9'h000});

        // ============================================================
        // Test 8b: texture_bc3 — interpolated alpha + BC1 color
        // ============================================================
        $display("--- Test 8b: texture_bc3 ---");

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
        check36("bc3 texel0 cyan alpha=0x80",
                bc3_texel_out, {9'h000, 9'h100, 9'h100, 9'h081});

        // ============================================================
        // Test 9: texture_bc4 — single channel
        // ============================================================
        $display("--- Test 9: texture_bc4 ---");

        // BC4 block: 64 bits
        //   [7:0]   = red0 = 0xFF (255)
        //   [15:8]  = red1 = 0x00 (0)
        //   [63:16] = 3-bit indices, texel 0 = index 0 -> red0 = 255
        // red9 = {1'b0, 0xFF} + 1 = 9'h100
        // BC4 output: {red9, red9, red9, 9'h100}
        bc4_block_data = 64'h0;
        bc4_block_data[7:0]  = 8'hFF;  // red0
        bc4_block_data[15:8] = 8'h00;  // red1

        bc4_texel_idx = 4'd0;
        #10;
        check36("bc4 texel0 red0=0xFF",
                bc4_texel_out, {9'h100, 9'h100, 9'h100, 9'h100});

        // red0=0x80 -> red9 = {1'b0, 0x80} + 1 = 9'h081
        bc4_block_data[7:0] = 8'h80;
        bc4_texel_idx = 4'd0;
        #10;
        check36("bc4 texel0 red0=0x80",
                bc4_texel_out, {9'h081, 9'h081, 9'h081, 9'h100});

        // ============================================================
        // Test 10: texture_bc5 — two-channel (VER-005 step 10)
        // ============================================================
        $display("--- Test 10: texture_bc5 ---");

        // Block A: 8-value interpolation mode for both channels
        //   Red:   red0=200 (0xC8), red1=100 (0x64)  -> red0 > red1 -> 8-entry
        //   Green: green0=50 (0x32), green1=10 (0x0A) -> green0 > green1 -> 8-entry
        //   Red indices:   texel0=0, texel1=2, texel2=4, texel3=6
        //   Green indices: texel0=1, texel1=3, texel2=5, texel3=7
        //
        // Red palette (8-value, /7):
        //   [0]=200, [1]=100, [2]=186, [3]=171, [4]=157, [5]=143, [6]=129, [7]=114
        // Green palette (8-value, /7):
        //   [0]=50,  [1]=10,  [2]=44,  [3]=39,  [4]=33,  [5]=27,  [6]=21,  [7]=16
        //
        // UQ1.8 expansion: ch9 = {1'b0, ch8} + ch8[7]

        // Block A layout: [63:0]=red block, [127:64]=green block
        bc5_block_data = 128'h0;
        bc5_block_data[7:0]   = 8'hC8;    // red0 = 200
        bc5_block_data[15:8]  = 8'h64;    // red1 = 100
        // Red indices (48 bits at [63:16]):
        //   texel0=0(000), texel1=2(010), texel2=4(100), texel3=6(110), rest=0
        bc5_block_data[63:16] = 48'h000000000D10;
        bc5_block_data[71:64] = 8'h32;    // green0 = 50
        bc5_block_data[79:72] = 8'h0A;    // green1 = 10
        // Green indices (48 bits at [127:80]):
        //   texel0=1(001), texel1=3(011), texel2=5(101), texel3=7(111), rest=0
        bc5_block_data[127:80] = 48'h000000000F59;

        // texel 0: red_pal[0]=200 -> R9=0x0C9, green_pal[1]=10 -> G9=0x00A
        bc5_texel_idx = 4'd0;
        #10;
        check36("bc5 8v texel0 R=200 G=10",
                bc5_texel_out, {9'h0C9, 9'h00A, 9'h000, 9'h100});

        // texel 1: red_pal[2]=186 -> R9=0x0BB, green_pal[3]=39 -> G9=0x027
        bc5_texel_idx = 4'd1;
        #10;
        check36("bc5 8v texel1 R=186 G=39",
                bc5_texel_out, {9'h0BB, 9'h027, 9'h000, 9'h100});

        // texel 2: red_pal[4]=157 -> R9=0x09E, green_pal[5]=27 -> G9=0x01B
        bc5_texel_idx = 4'd2;
        #10;
        check36("bc5 8v texel2 R=157 G=27",
                bc5_texel_out, {9'h09E, 9'h01B, 9'h000, 9'h100});

        // texel 3: red_pal[6]=129 -> R9=0x082, green_pal[7]=16 -> G9=0x010
        bc5_texel_idx = 4'd3;
        #10;
        check36("bc5 8v texel3 R=129 G=16",
                bc5_texel_out, {9'h082, 9'h010, 9'h000, 9'h100});

        // Block B: 6-value interpolation mode (red0 <= red1)
        //   Red:   red0=50, red1=200  -> red0 <= red1 -> 6-entry + 0,255
        //   Green: green0=10, green1=50 -> green0 <= green1 -> 6-entry + 0,255
        //   Red indices:   texel0=0, texel1=6, texel2=2, texel3=4
        //   Green indices: texel0=1, texel1=7, texel2=3, texel3=5
        //
        // Red palette (6-value, /5):
        //   [0]=50, [1]=200, [2]=80, [3]=110, [4]=140, [5]=170, [6]=0, [7]=255
        // Green palette (6-value, /5):
        //   [0]=10, [1]=50, [2]=18, [3]=26, [4]=34, [5]=42, [6]=0, [7]=255

        bc5_block_data = 128'h0;
        bc5_block_data[7:0]   = 8'h32;    // red0 = 50
        bc5_block_data[15:8]  = 8'hC8;    // red1 = 200
        // Red indices (48 bits at [63:16]):
        //   texel0=0(000), texel1=6(110), texel2=2(010), texel3=4(100), rest=0
        bc5_block_data[63:16] = 48'h0000000008B0;
        bc5_block_data[71:64] = 8'h0A;    // green0 = 10
        bc5_block_data[79:72] = 8'h32;    // green1 = 50
        // Green indices (48 bits at [127:80]):
        //   texel0=1(001), texel1=7(111), texel2=3(011), texel3=5(101), rest=0
        bc5_block_data[127:80] = 48'h000000000AF9;

        // texel 0: red_pal[0]=50 -> R9=0x032, green_pal[1]=50 -> G9=0x032
        bc5_texel_idx = 4'd0;
        #10;
        check36("bc5 6v texel0 R=50 G=50",
                bc5_texel_out, {9'h032, 9'h032, 9'h000, 9'h100});

        // texel 1: red_pal[6]=0 -> R9=0x000, green_pal[7]=255 -> G9=0x100
        bc5_texel_idx = 4'd1;
        #10;
        check36("bc5 6v texel1 R=0 G=255",
                bc5_texel_out, {9'h000, 9'h100, 9'h000, 9'h100});

        // texel 2: red_pal[2]=80 -> R9=0x050, green_pal[3]=26 -> G9=0x01A
        bc5_texel_idx = 4'd2;
        #10;
        check36("bc5 6v texel2 R=80 G=26",
                bc5_texel_out, {9'h050, 9'h01A, 9'h000, 9'h100});

        // texel 3: red_pal[4]=140 -> R9=0x08D, green_pal[5]=42 -> G9=0x02A
        bc5_texel_idx = 4'd3;
        #10;
        check36("bc5 6v texel3 R=140 G=42",
                bc5_texel_out, {9'h08D, 9'h02A, 9'h000, 9'h100});

        // Verify B=0 and A=opaque for all BC5 texels (spot check texel 0 Block A)
        bc5_block_data = 128'h0;
        bc5_block_data[7:0]   = 8'hC8;
        bc5_block_data[15:8]  = 8'h64;
        bc5_block_data[71:64] = 8'h32;
        bc5_block_data[79:72] = 8'h0A;
        bc5_texel_idx = 4'd0;
        #10;
        check36("bc5 B=0 A=opaque",
                {27'b0, bc5_texel_out[17:9]}, {27'b0, 9'h000});
        check36("bc5 A=0x100",
                {27'b0, bc5_texel_out[8:0]}, {27'b0, 9'h100});

        // ============================================================
        // Test 11: Format-select mux wiring (VER-005 step 11)
        // ============================================================
        $display("--- Test 11: Format-select mux (8-format, 4-bit, 36-bit) ---");

        // Set up DISTINCTIVE data for each decoder so all 7 outputs are
        // provably unique.  This ensures the mux test can detect any
        // miswiring (two decoders producing identical output would mask a
        // mux routing error).

        // --- BC1 (format 0): pure green, 4-color opaque mode ---
        // color0 = 0x07E0 (R5=0, G6=63, B5=0), color1 = 0x0000
        // color0 > color1 -> 4-color mode; texel 0 index=0 -> color0
        // R9=0, G9=0x100, B9=0, A9=0x100
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'h07E0;  // color0 = green
        bc1_data[31:16] = 16'h0000;  // color1 = black
        bc1_data[63:32] = 32'h0;     // all texels index 0
        bc1_texel_idx = 4'd0;

        // --- BC2 (format 1): white with A4=0x8 ---
        // c0_r9=0x100, c0_g9=0x100, c0_b9=0x100
        // alpha4=0x8 -> alpha9 = expand(4'h8) (half alpha)
        bc2_block_data = 128'h0;
        bc2_block_data[3:0]    = 4'h8;     // texel 0 alpha = 0x8
        bc2_block_data[79:64]  = 16'hFFFF; // color0 = white
        bc2_block_data[95:80]  = 16'h0000; // color1 = black
        bc2_block_data[127:96] = 32'h0;    // all texels index 0
        bc2_texel_idx = 4'd0;

        // --- BC3 (format 2): cyan with alpha0=0x80 ---
        // c0_r9=0, c0_g9=0x100, c0_b9=0x100
        // alpha9 = 9'h081
        bc3_block_data = 128'h0;
        bc3_block_data[7:0]    = 8'h80;    // alpha0 = 0x80
        bc3_block_data[15:8]   = 8'h00;    // alpha1 = 0x00
        bc3_block_data[63:16]  = 48'h0;    // all alpha indices = 0 (-> alpha0)
        bc3_block_data[79:64]  = 16'h07FF; // color0 = cyan (R=0, G=63, B=31)
        bc3_block_data[95:80]  = 16'h0000; // color1 = black
        bc3_block_data[127:96] = 32'h0;    // all texels index 0
        bc3_texel_idx = 4'd0;

        // --- BC4 (format 3): red0=0x80 ---
        // red9 = 9'h081, replicated to RGB, A9=0x100
        bc4_block_data = 64'h0;
        bc4_block_data[7:0]  = 8'h80;  // red0 = 0x80
        bc4_block_data[15:8] = 8'h00;  // red1 = 0x00
        bc4_texel_idx = 4'd0;

        // --- BC5 (format 4): red0=0xC0, green0=0x40 ---
        // red9 = {1'b0, 0xC0} + 1 = 9'h0C1, green9 = {1'b0, 0x40} + 0 = 9'h040
        bc5_block_data = 128'h0;
        bc5_block_data[7:0]   = 8'hC0;    // red0 = 0xC0
        bc5_block_data[15:8]  = 8'h00;    // red1 = 0x00
        bc5_block_data[71:64] = 8'h40;    // green0 = 0x40
        bc5_block_data[79:72] = 8'h00;    // green1 = 0x00
        bc5_texel_idx = 4'd0;

        // --- RGB565 (format 5): pure blue = 0x001F ---
        // R9=0, G9=0, B9=0x100, A9=0x1FF
        rgb565_block_data = 256'h0;
        rgb565_block_data[15:0] = 16'h001F;
        rgb565_texel_idx = 4'd0;

        // --- RGBA8888 (format 6): R=0x80, G=0x40, B=0xC0, A=0xFF ---
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'hFF, 8'hC0, 8'h40, 8'h80};
        rgba8888_texel_idx = 4'd0;

        // --- R8 (format 7): R8=0x60 ---
        r8_block_data = 128'h0;
        r8_block_data[7:0] = 8'h60;
        r8_texel_idx = 4'd0;

        #10;

        // Verify mux routes each decoder's 36-bit output correctly
        mux_tex_format = 4'd0;
        #10;
        check36("mux fmt=0 (BC1) routes decoder", mux_result, bc1_texel_out);

        mux_tex_format = 4'd1;
        #10;
        check36("mux fmt=1 (BC2) routes decoder", mux_result, bc2_texel_out);

        mux_tex_format = 4'd2;
        #10;
        check36("mux fmt=2 (BC3) routes decoder", mux_result, bc3_texel_out);

        mux_tex_format = 4'd3;
        #10;
        check36("mux fmt=3 (BC4) routes decoder", mux_result, bc4_texel_out);

        mux_tex_format = 4'd4;
        #10;
        check36("mux fmt=4 (BC5) routes decoder", mux_result, bc5_texel_out);

        mux_tex_format = 4'd5;
        #10;
        check36("mux fmt=5 (RGB565) routes decoder", mux_result, rgb565_texel_out);

        mux_tex_format = 4'd6;
        #10;
        check36("mux fmt=6 (RGBA8888) routes decoder", mux_result, rgba8888_texel_out);

        mux_tex_format = 4'd7;
        #10;
        check36("mux fmt=7 (R8) routes decoder", mux_result, r8_texel_out);

        mux_tex_format = 4'd8;
        #10;
        check36("mux fmt=8 (reserved) -> zero", mux_result, 36'b0);

        // ============================================================
        // Test 12: UQ1.8 bit layout verification
        // ============================================================
        $display("--- Test 12: UQ1.8 bit layout ---");

        // Use RGBA8888 decoder with known per-channel values to verify
        // the UQ1.8 bit field positions.
        // R=0x80, G=0x40, B=0xC0, A=0x20
        // Output order for rgba8888: {A9, B9, G9, R9}
        // R9=0x101, G9=0x080, B9=0x181, A9=0x040
        rgba8888_block_data = 512'h0;
        rgba8888_block_data[31:0] = {8'h20, 8'hC0, 8'h40, 8'h80};
        rgba8888_texel_idx = 4'd0;
        #10;

        // Verify each 9-bit field position independently.
        // rgba8888 ordering: [8:0]=R9, [17:9]=G9, [26:18]=B9, [35:27]=A9
        check36("uq18 R9 at [8:0]",
                {27'b0, rgba8888_texel_out[8:0]}, {27'b0, 9'h101});
        check36("uq18 G9 at [17:9]",
                {27'b0, rgba8888_texel_out[17:9]}, {27'b0, 9'h080});
        check36("uq18 B9 at [26:18]",
                {27'b0, rgba8888_texel_out[26:18]}, {27'b0, 9'h181});
        check36("uq18 A9 at [35:27]",
                {27'b0, rgba8888_texel_out[35:27]}, {27'b0, 9'h040});

        // Cross-check: full 36-bit value
        check36("uq18 full layout", rgba8888_texel_out,
                {9'h040, 9'h181, 9'h080, 9'h101});

        // Also verify BC1 layout (which uses {R9, G9, B9, A9} ordering).
        // BC1 with color0=0xF800 (pure red), texel 0 = index 0.
        // Expected: R9=0x100, G9=0x000, B9=0x000, A9=0x100
        // [35:27]=R9, [26:18]=G9, [17:9]=B9, [8:0]=A9
        bc1_data = 64'h0;
        bc1_data[15:0]  = 16'hF800;
        bc1_data[31:16] = 16'h001F;
        bc1_data[63:32] = 32'h0;
        bc1_texel_idx = 4'd0;
        #10;

        check36("bc1 uq18 R9 at [35:27]",
                {27'b0, bc1_texel_out[35:27]}, {27'b0, 9'h100});
        check36("bc1 uq18 G9 at [26:18]",
                {27'b0, bc1_texel_out[26:18]}, {27'b0, 9'h000});
        check36("bc1 uq18 B9 at [17:9]",
                {27'b0, bc1_texel_out[17:9]}, {27'b0, 9'h000});
        check36("bc1 uq18 A9 at [8:0]",
                {27'b0, bc1_texel_out[8:0]}, {27'b0, 9'h100});

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

`default_nettype wire
