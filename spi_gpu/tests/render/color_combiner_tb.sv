// Testbench for color_combiner module (VER-004)
//
// Covers all 14 VER-004 test procedures:
//   1. CC_MODE configures both combiner cycles
//   2. TEX_COLOR0 and TEX_COLOR1 input sourcing
//   3. SHADE0 and SHADE1 input sourcing
//   4. CONST0 and CONST1 loading from CONST_COLOR register
//   5. COMBINED source in cycle 1 equals cycle 0 output
//   6. MODULATE mode: TEX0 * SHADE0
//   7. DECAL mode: TEX0 passthrough
//   8. LIGHTMAP mode: TEX0 * TEX1
//   9. MODULATE_ADD mode: two-stage specular
//  10. FOG mode: lerp toward CONST1 via SHADE0.A
//  11. Per-component independence
//  12. Single-stage pass-through
//  13. Overflow saturation (clamp to 1.0)
//  14. Underflow saturation (clamp to 0.0)

`timescale 1ns/1ps

module color_combiner_tb;

    // Clock and reset
    reg         clk;
    reg         rst_n;

    // Fragment inputs (Q4.12 packed RGBA)
    reg  [63:0] tex_color0;
    reg  [63:0] tex_color1;
    reg  [63:0] shade0;
    reg  [63:0] shade1;

    // Fragment position and valid
    reg  [15:0] frag_x;
    reg  [15:0] frag_y;
    reg  [15:0] frag_z;
    reg         frag_valid;

    // Configuration
    reg  [63:0] cc_mode;
    reg  [63:0] const_color;

    // Outputs
    wire [63:0] combined_color;
    wire [15:0] out_frag_x;
    wire [15:0] out_frag_y;
    wire [15:0] out_frag_z;
    wire        out_frag_valid;
    wire        in_ready;
    reg         out_ready;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Q4.12 constants
    localparam [15:0] Q412_ZERO    = 16'h0000;
    localparam [15:0] Q412_QUARTER = 16'h0400;  // 0.25
    localparam [15:0] Q412_HALF    = 16'h0800;  // 0.5
    localparam [15:0] Q412_3Q      = 16'h0C00;  // 0.75
    localparam [15:0] Q412_ONE     = 16'h1000;  // 1.0

    // CC_SOURCE encoding (cc_source_e from RDL)
    localparam [3:0] CC_COMBINED = 4'd0;
    localparam [3:0] CC_TEX0     = 4'd1;
    localparam [3:0] CC_TEX1     = 4'd2;
    localparam [3:0] CC_SHADE0   = 4'd3;
    localparam [3:0] CC_CONST0   = 4'd4;
    localparam [3:0] CC_CONST1   = 4'd5;
    localparam [3:0] CC_ONE      = 4'd6;
    localparam [3:0] CC_ZERO     = 4'd7;
    localparam [3:0] CC_SHADE1   = 4'd8;

    // CC_RGB_C_SOURCE encoding (cc_rgb_c_source_e from RDL, extended)
    localparam [3:0] CC_C_COMBINED       = 4'd0;
    localparam [3:0] CC_C_TEX0           = 4'd1;
    localparam [3:0] CC_C_TEX1           = 4'd2;
    localparam [3:0] CC_C_SHADE0         = 4'd3;
    localparam [3:0] CC_C_CONST0         = 4'd4;
    localparam [3:0] CC_C_CONST1         = 4'd5;
    localparam [3:0] CC_C_ONE            = 4'd6;
    localparam [3:0] CC_C_ZERO           = 4'd7;
    localparam [3:0] CC_C_TEX0_ALPHA     = 4'd8;
    localparam [3:0] CC_C_TEX1_ALPHA     = 4'd9;
    localparam [3:0] CC_C_SHADE0_ALPHA   = 4'd10;
    localparam [3:0] CC_C_CONST0_ALPHA   = 4'd11;
    localparam [3:0] CC_C_COMBINED_ALPHA = 4'd12;
    localparam [3:0] CC_C_SHADE1         = 4'd13;
    localparam [3:0] CC_C_SHADE1_ALPHA   = 4'd14;

    // Instantiate DUT
    color_combiner dut (
        .clk(clk),
        .rst_n(rst_n),
        .tex_color0(tex_color0),
        .tex_color1(tex_color1),
        .shade0(shade0),
        .shade1(shade1),
        .frag_x(frag_x),
        .frag_y(frag_y),
        .frag_z(frag_z),
        .frag_valid(frag_valid),
        .cc_mode(cc_mode),
        .const_color(const_color),
        .combined_color(combined_color),
        .out_frag_x(out_frag_x),
        .out_frag_y(out_frag_y),
        .out_frag_z(out_frag_z),
        .out_frag_valid(out_frag_valid),
        .in_ready(in_ready),
        .out_ready(out_ready)
    );

    // Clock generation (100 MHz)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Check helpers
    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected %0b, got %0b", name, expected, actual);
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

    // Check with tolerance: |actual - expected| <= tolerance
    task check16_approx(input string name, input logic [15:0] actual, input logic [15:0] expected, input int tolerance);
        int diff;
        begin
            if ($signed(actual) > $signed(expected)) begin
                diff = $signed(actual) - $signed(expected);
            end else begin
                diff = $signed(expected) - $signed(actual);
            end
            if (diff <= tolerance) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: %s - expected 0x%04x (+/-%0d), got 0x%04x (diff=%0d)", name, expected, tolerance, actual, diff);
                fail_count = fail_count + 1;
            end
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Helper: build one CC_MODE cycle from selectors
    // Layout: {alpha_d, alpha_c, alpha_b, alpha_a, rgb_d, rgb_c, rgb_b, rgb_a}
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [31:0] pack_cycle(
        input [3:0] rgb_a, input [3:0] rgb_b, input [3:0] rgb_c, input [3:0] rgb_d,
        input [3:0] alpha_a, input [3:0] alpha_b, input [3:0] alpha_c, input [3:0] alpha_d
    );
        begin
            pack_cycle = {alpha_d, alpha_c, alpha_b, alpha_a, rgb_d, rgb_c, rgb_b, rgb_a};
        end
    endfunction

    // Helper: pack Q4.12 RGBA into 64-bit {R, G, B, A}
    function automatic [63:0] pack_q412(
        input [15:0] r, input [15:0] g, input [15:0] b, input [15:0] a
    );
        begin
            pack_q412 = {r, g, b, a};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // Common passthrough cycle 1: A=COMBINED, B=ZERO, C=ONE, D=ZERO
    // (passes cycle 0 result through unchanged)
    localparam [31:0] PASSTHROUGH_CYCLE = {
        4'd7, 4'd6, 4'd7, 4'd0,   // alpha: D=ZERO, C=ONE, B=ZERO, A=COMBINED
        4'd7, 4'd6, 4'd7, 4'd0    // rgb:   D=ZERO, C=ONE, B=ZERO, A=COMBINED
    };

    // Helper: drive one fragment and wait for pipeline output (4 stages)
    task drive_fragment();
        begin
            frag_valid = 1;
            @(posedge clk);
            frag_valid = 0;
            // Wait for 4 pipeline stages
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
            @(posedge clk);
        end
    endtask

    // Helper: CONST UNORM8->Q4.12 promotion reference model
    // Formula: {4'b0000, u8, u8[7:4]}
    // Maps [0,255] -> [0x0000, 0x0FFF], staying within UNORM [0, 1.0).
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic [15:0] promote_u8(input [7:0] u8);
        begin
            promote_u8 = {4'b0000, u8, u8[7:4]};
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        $dumpfile("color_combiner.vcd");
        $dumpvars(0, color_combiner_tb);

        // Initialize
        rst_n = 0;
        tex_color0 = 64'h0;
        tex_color1 = 64'h0;
        shade0 = 64'h0;
        shade1 = 64'h0;
        frag_x = 16'h0;
        frag_y = 16'h0;
        frag_z = 16'h0;
        frag_valid = 0;
        cc_mode = 64'h0;
        const_color = 64'h0;
        out_ready = 1;

        #100;
        rst_n = 1;
        #20;

        $display("=== Color Combiner Testbench (VER-004) ===\n");

        // ============================================================
        // Test 1 (VER-004 Proc 1): CC_MODE configures both cycles
        // Cycle 0: TEX0 * SHADE0 (modulate)
        // Cycle 1: COMBINED + SHADE1 (specular add)
        // Verifies both cycles apply their respective equations.
        // ============================================================
        $display("--- Test 1: CC_MODE configures both cycles ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade0     = pack_q412(Q412_ONE,  Q412_ONE,  Q412_ONE,  Q412_ONE);
        shade1     = pack_q412(Q412_QUARTER, Q412_QUARTER, Q412_QUARTER, Q412_QUARTER);

        // Cycle 0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO -> TEX0 * SHADE0 = 0.5
        // Cycle 1: A=COMBINED, B=ZERO, C=ONE, D=SHADE1 -> COMBINED + SHADE1 = 0.75
        cc_mode = {
            pack_cycle(CC_COMBINED, CC_ZERO, CC_C_ONE,    CC_SHADE1,
                       CC_COMBINED, CC_ZERO, CC_ONE,      CC_SHADE1),
            pack_cycle(CC_TEX0,     CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0,     CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        drive_fragment();

        // 0.5 * 1.0 + 0.25 = 0.75
        check16_approx("both_cycles R", combined_color[63:48], Q412_3Q, 1);
        check16_approx("both_cycles G", combined_color[47:32], Q412_3Q, 1);
        check16_approx("both_cycles B", combined_color[31:16], Q412_3Q, 1);
        check16_approx("both_cycles A", combined_color[15:0],  Q412_3Q, 1);

        // ============================================================
        // Test 2 (VER-004 Proc 2): TEX_COLOR0 and TEX_COLOR1 sourcing
        // Pass through TEX0 then TEX1 via passthrough configuration.
        // ============================================================
        $display("--- Test 2: TEX_COLOR0 and TEX_COLOR1 input sourcing ---");

        tex_color0 = pack_q412(16'h0A00, 16'h0B00, 16'h0C00, 16'h0D00);
        tex_color1 = pack_q412(16'h0100, 16'h0200, 16'h0300, 16'h0400);

        // Cycle 0: passthrough TEX0 (A=TEX0, B=ZERO, C=ONE, D=ZERO)
        // Cycle 1: passthrough COMBINED
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("tex0 pass R", combined_color[63:48], 16'h0A00);
        check16("tex0 pass G", combined_color[47:32], 16'h0B00);
        check16("tex0 pass B", combined_color[31:16], 16'h0C00);
        check16("tex0 pass A", combined_color[15:0],  16'h0D00);

        // Now passthrough TEX1
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX1, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_TEX1, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("tex1 pass R", combined_color[63:48], 16'h0100);
        check16("tex1 pass G", combined_color[47:32], 16'h0200);
        check16("tex1 pass B", combined_color[31:16], 16'h0300);
        check16("tex1 pass A", combined_color[15:0],  16'h0400);

        // ============================================================
        // Test 3 (VER-004 Proc 3): SHADE0 and SHADE1 input sourcing
        // ============================================================
        $display("--- Test 3: SHADE0 and SHADE1 input sourcing ---");

        shade0 = pack_q412(16'h0E00, 16'h0F00, 16'h0500, 16'h0600);
        shade1 = pack_q412(16'h0700, 16'h0100, 16'h0200, 16'h0900);

        // Passthrough SHADE0
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_SHADE0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_SHADE0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("shade0 pass R", combined_color[63:48], 16'h0E00);
        check16("shade0 pass G", combined_color[47:32], 16'h0F00);
        check16("shade0 pass B", combined_color[31:16], 16'h0500);
        check16("shade0 pass A", combined_color[15:0],  16'h0600);

        // Passthrough SHADE1
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_SHADE1, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_SHADE1, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("shade1 pass R", combined_color[63:48], 16'h0700);
        check16("shade1 pass G", combined_color[47:32], 16'h0100);
        check16("shade1 pass B", combined_color[31:16], 16'h0200);
        check16("shade1 pass A", combined_color[15:0],  16'h0900);

        // ============================================================
        // Test 4 (VER-004 Proc 4): CONST0 and CONST1 promotion
        // CONST_COLOR: CONST0 in [31:0], CONST1 in [63:32]
        // Byte layout per channel: [7:0]=R, [15:8]=G, [23:16]=B, [31:24]=A
        // Promotion: {3'b000, u8, u8[7:4], 1'b0}
        // ============================================================
        $display("--- Test 4: CONST0 and CONST1 promotion ---");

        // CONST0 = R:0x80, G:0x40, B:0xC0, A:0xFF
        //        = {A, B, G, R} = {0xFF, 0xC0, 0x40, 0x80} = 0xFFC04080
        // CONST1 = R:0x20, G:0x60, B:0xA0, A:0x00
        //        = {A, B, G, R} = {0x00, 0xA0, 0x60, 0x20} = 0x00A06020
        const_color = {32'h00A06020, 32'hFFC04080};

        // Passthrough CONST0
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_CONST0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_CONST0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        // R=0x80: {000, 10000000, 1000, 0} = 0x0410
        check16("const0 R", combined_color[63:48], promote_u8(8'h80));
        // G=0x40: {000, 01000000, 0100, 0} = 0x0208
        check16("const0 G", combined_color[47:32], promote_u8(8'h40));
        // B=0xC0: {000, 11000000, 1100, 0} = 0x0618
        check16("const0 B", combined_color[31:16], promote_u8(8'hC0));
        // A=0xFF: {000, 11111111, 1111, 0} = 0x0FFE
        check16("const0 A", combined_color[15:0],  promote_u8(8'hFF));

        // Passthrough CONST1
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_CONST1, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_CONST1, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        // R=0x20: {000, 00100000, 0010, 0} = 0x0104
        check16("const1 R", combined_color[63:48], promote_u8(8'h20));
        // G=0x60: {000, 01100000, 0110, 0} = 0x030C
        check16("const1 G", combined_color[47:32], promote_u8(8'h60));
        // B=0xA0: {000, 10100000, 1010, 0} = 0x0514
        check16("const1 B", combined_color[31:16], promote_u8(8'hA0));
        // A=0x00: {000, 00000000, 0000, 0} = 0x0000
        check16("const1 A", combined_color[15:0],  promote_u8(8'h00));

        // ============================================================
        // Test 5 (VER-004 Proc 5): COMBINED source in cycle 1
        // Cycle 0: passthrough SHADE0
        // Cycle 1: passthrough COMBINED -> output = SHADE0
        // ============================================================
        $display("--- Test 5: COMBINED source ---");

        const_color = 64'h0;
        shade0 = pack_q412(16'h0C00, 16'h0800, 16'h0400, 16'h1000);

        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_SHADE0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_SHADE0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("combined=shade0 R", combined_color[63:48], 16'h0C00);
        check16("combined=shade0 G", combined_color[47:32], 16'h0800);
        check16("combined=shade0 B", combined_color[31:16], 16'h0400);
        check16("combined=shade0 A", combined_color[15:0],  16'h1000);

        // ============================================================
        // Test 6 (VER-004 Proc 6): MODULATE mode (TEX0 * SHADE0)
        // TEX0 = 0.5, SHADE0 = 0.5 -> output = 0.25
        // ============================================================
        $display("--- Test 6: Modulate (TEX0 * SHADE0) ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade0     = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);

        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        drive_fragment();

        check16_approx("modulate R", combined_color[63:48], Q412_QUARTER, 1);
        check16_approx("modulate G", combined_color[47:32], Q412_QUARTER, 1);
        check16_approx("modulate B", combined_color[31:16], Q412_QUARTER, 1);
        check16_approx("modulate A", combined_color[15:0],  Q412_QUARTER, 1);

        // ============================================================
        // Test 7 (VER-004 Proc 7): DECAL mode (TEX0 passthrough)
        // A=TEX0, B=ZERO, C=ONE, D=ZERO -> TEX0
        // ============================================================
        $display("--- Test 7: Decal (TEX0 passthrough) ---");

        tex_color0 = pack_q412(16'h0ABC, 16'h0DEF, 16'h0123, 16'h0456);

        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("decal R", combined_color[63:48], 16'h0ABC);
        check16("decal G", combined_color[47:32], 16'h0DEF);
        check16("decal B", combined_color[31:16], 16'h0123);
        check16("decal A", combined_color[15:0],  16'h0456);

        // ============================================================
        // Test 8 (VER-004 Proc 8): LIGHTMAP mode (TEX0 * TEX1)
        // TEX0 = 0.5 all, TEX1 = 0.5 all -> 0.25
        // ============================================================
        $display("--- Test 8: Lightmap (TEX0 * TEX1) ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        tex_color1 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);

        // Cycle 0: A=TEX0, B=ZERO, C=TEX1 (rgb_c uses CC_C_TEX1), D=ZERO
        // Alpha C uses CC_TEX1 (standard mux)
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_TEX1, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_TEX1,   CC_ZERO)
        };

        drive_fragment();

        check16_approx("lightmap R", combined_color[63:48], Q412_QUARTER, 1);
        check16_approx("lightmap G", combined_color[47:32], Q412_QUARTER, 1);
        check16_approx("lightmap B", combined_color[31:16], Q412_QUARTER, 1);
        check16_approx("lightmap A", combined_color[15:0],  Q412_QUARTER, 1);

        // ============================================================
        // Test 9 (VER-004 Proc 9): MODULATE_ADD (specular)
        // Cycle 0: TEX0 * SHADE0  (0.5 * 0.5 = 0.25)
        // Cycle 1: COMBINED + SHADE1  (0.25 + 0.5 = 0.75)
        // ============================================================
        $display("--- Test 9: Specular add (MODULATE_ADD) ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade0     = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade1     = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);

        // Cycle 0: A=TEX0, B=ZERO, C=SHADE0, D=ZERO
        // Cycle 1: A=COMBINED, B=ZERO, C=ONE, D=SHADE1
        cc_mode = {
            pack_cycle(CC_COMBINED, CC_ZERO, CC_C_ONE,    CC_SHADE1,
                       CC_COMBINED, CC_ZERO, CC_ONE,      CC_SHADE1),
            pack_cycle(CC_TEX0,     CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0,     CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        drive_fragment();

        // 0.5*0.5 + 0.5 = 0.75
        check16_approx("specular R", combined_color[63:48], Q412_3Q, 1);
        check16_approx("specular G", combined_color[47:32], Q412_3Q, 1);
        check16_approx("specular B", combined_color[31:16], Q412_3Q, 1);
        check16_approx("specular A", combined_color[15:0],  Q412_3Q, 1);

        // ============================================================
        // Test 10 (VER-004 Proc 10): FOG mode
        // Cycle 0: TEX0 * SHADE0  (0.5 * 1.0 = 0.5 -> COMBINED)
        // Cycle 1: lerp(COMBINED, CONST1, SHADE0.A)
        //   = (COMBINED - CONST1) * SHADE0.A + CONST1
        //   = (0.5 - 0.25) * 0.5 + 0.25 = 0.125 + 0.25 = 0.375
        //
        // SHADE0.A used as fog factor via CC_C_SHADE0_ALPHA broadcast
        // CONST1 used as fog color
        // ============================================================
        $display("--- Test 10: Fog ---");

        tex_color0 = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);
        shade0     = pack_q412(Q412_ONE,  Q412_ONE,  Q412_ONE,  Q412_HALF);  // A=0.5 (fog factor)
        const_color = 64'h0;

        // CONST1 (fog color) = R:0x40, G:0x40, B:0x40, A:0x40 -> uniform 0.25-ish
        // const_color[63:32] = {A=0x40, B=0x40, G=0x40, R=0x40} = 0x40404040
        const_color = {32'h40404040, 32'h00000000};

        // Compute expected promoted CONST1 value
        // 0x40 -> {0000, 01000000, 0100} = 0x0404
        // (COMBINED - CONST1) * SHADE0.A + CONST1
        // = (0x0800 - 0x0404) * 0x0800 + 0x0404
        // diff = 0x03FC, product = (0x03FC * 0x0800) >> 12 = 0x01FE
        // sum = 0x01FE + 0x0404 = 0x0602

        // Cycle 0: A=TEX0, B=ZERO, C=ONE (full diffuse), D=ZERO -> TEX0 = 0.5
        // Cycle 1: A=COMBINED, B=CONST1, C=SHADE0_ALPHA, D=CONST1
        cc_mode = {
            pack_cycle(CC_COMBINED, CC_CONST1, CC_C_SHADE0_ALPHA, CC_CONST1,
                       CC_COMBINED, CC_CONST1, CC_SHADE0,         CC_CONST1),
            pack_cycle(CC_TEX0,     CC_ZERO,   CC_C_ONE,          CC_ZERO,
                       CC_TEX0,     CC_ZERO,   CC_ONE,            CC_ZERO)
        };

        drive_fragment();

        // Expected RGB: (0x0800 - 0x0404) * 0x0800 >> 12 + 0x0404
        //             = 0x03FC * 0x0800 >> 12 + 0x0404
        //             = 0x01FE + 0x0404 = 0x0602
        // Alpha: same computation (SHADE0 A=0x0800 used as C for alpha)
        check16_approx("fog R", combined_color[63:48], 16'h0602, 1);
        check16_approx("fog G", combined_color[47:32], 16'h0602, 1);
        check16_approx("fog B", combined_color[31:16], 16'h0602, 1);
        check16_approx("fog A", combined_color[15:0],  16'h0602, 1);

        // ============================================================
        // Test 11 (VER-004 Proc 11): Per-component independence
        // TEX0 has distinct R, G, B, A.  SHADE0 has distinct per-channel.
        // Modulate mode. Verify each channel is independent.
        // ============================================================
        $display("--- Test 11: Per-component independence ---");

        const_color = 64'h0;

        // TEX0: R=0.25, G=0.5, B=0.75, A=1.0
        tex_color0 = pack_q412(Q412_QUARTER, Q412_HALF, Q412_3Q, Q412_ONE);
        // SHADE0: R=1.0, G=0.5, B=0.25, A=0.5
        shade0 = pack_q412(Q412_ONE, Q412_HALF, Q412_QUARTER, Q412_HALF);

        // Modulate: TEX0 * SHADE0
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        drive_fragment();

        // R: 0.25 * 1.0  = 0.25  = 0x0400
        check16_approx("perchan R", combined_color[63:48], Q412_QUARTER, 1);
        // G: 0.5  * 0.5  = 0.25  = 0x0400
        check16_approx("perchan G", combined_color[47:32], Q412_QUARTER, 1);
        // B: 0.75 * 0.25 = 0.1875 = 0x0300
        check16_approx("perchan B", combined_color[31:16], 16'h0300, 1);
        // A: 1.0  * 0.5  = 0.5   = 0x0800
        check16_approx("perchan A", combined_color[15:0],  Q412_HALF, 1);

        // ============================================================
        // Test 12 (VER-004 Proc 12): Single-stage pass-through
        // Cycle 0: TEX0 * SHADE0 (modulate: 0.75 * 0.5 = 0.375)
        // Cycle 1: passthrough (A=COMBINED, B=ZERO, C=ONE, D=ZERO)
        // Final output = cycle 0 output exactly.
        // ============================================================
        $display("--- Test 12: Pass-through cycle 1 ---");

        tex_color0 = pack_q412(Q412_3Q, Q412_3Q, Q412_3Q, Q412_3Q);
        shade0     = pack_q412(Q412_HALF, Q412_HALF, Q412_HALF, Q412_HALF);

        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_SHADE0, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_SHADE0,   CC_ZERO)
        };

        drive_fragment();

        // 0.75 * 0.5 = 0.375 = 0x0600
        check16_approx("passthru R", combined_color[63:48], 16'h0600, 1);
        check16_approx("passthru G", combined_color[47:32], 16'h0600, 1);
        check16_approx("passthru B", combined_color[31:16], 16'h0600, 1);
        check16_approx("passthru A", combined_color[15:0],  16'h0600, 1);

        // ============================================================
        // Test 13 (VER-004 Proc 13): Overflow saturation
        // (A=ONE, B=ZERO, C=ONE, D=ONE) = 1.0 + 1.0 = 2.0 -> clamp 1.0
        // ============================================================
        $display("--- Test 13: Overflow saturation ---");

        cc_mode = {
            pack_cycle(CC_ONE, CC_ZERO, CC_C_ONE, CC_ONE,
                       CC_ONE, CC_ZERO, CC_ONE,   CC_ONE),
            pack_cycle(CC_ONE, CC_ZERO, CC_C_ONE, CC_ONE,
                       CC_ONE, CC_ZERO, CC_ONE,   CC_ONE)
        };

        drive_fragment();

        check16("overflow R", combined_color[63:48], Q412_ONE);
        check16("overflow G", combined_color[47:32], Q412_ONE);
        check16("overflow B", combined_color[31:16], Q412_ONE);
        check16("overflow A", combined_color[15:0],  Q412_ONE);

        // ============================================================
        // Test 14 (VER-004 Proc 14): Underflow saturation
        // (A=ZERO, B=ONE, C=ONE, D=ZERO) = (0 - 1) * 1 + 0 = -1.0
        // -> clamp to 0.0
        // ============================================================
        $display("--- Test 14: Underflow saturation ---");

        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_ZERO, CC_ONE, CC_C_ONE, CC_ZERO,
                       CC_ZERO, CC_ONE, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("underflow R", combined_color[63:48], Q412_ZERO);
        check16("underflow G", combined_color[47:32], Q412_ZERO);
        check16("underflow B", combined_color[31:16], Q412_ZERO);
        check16("underflow A", combined_color[15:0],  Q412_ZERO);

        // ============================================================
        // Bonus: Fragment position passthrough
        // Verify frag_x, frag_y, frag_z propagate correctly.
        // ============================================================
        $display("--- Bonus: Fragment position passthrough ---");

        frag_x = 16'h0123;
        frag_y = 16'h0456;
        frag_z = 16'h0789;

        // Simple passthrough
        cc_mode = {
            PASSTHROUGH_CYCLE,
            pack_cycle(CC_TEX0, CC_ZERO, CC_C_ONE, CC_ZERO,
                       CC_TEX0, CC_ZERO, CC_ONE,   CC_ZERO)
        };

        drive_fragment();

        check16("frag_x passthru", out_frag_x, 16'h0123);
        check16("frag_y passthru", out_frag_y, 16'h0456);
        check16("frag_z passthru", out_frag_z, 16'h0789);

        frag_x = 16'h0;
        frag_y = 16'h0;
        frag_z = 16'h0;

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
        #200000;
        $display("\nERROR: Timeout - simulation ran too long");
        $finish;
    end

endmodule
