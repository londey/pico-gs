// Testbench for alpha_blend module
// Tests all four blend modes with saturation clamping and boundary conditions
//
// Blend modes:
//   000 = DISABLED: result = src (passthrough)
//   001 = ADD:      result = saturate(src + dst) clamped to [0, Q412_ONE]
//   010 = SUBTRACT: result = saturate(src - dst) clamped to [0, Q412_ONE]
//   011 = BLEND:    result = src * alpha + dst * (1 - alpha) (Porter-Duff)
//
// See: UNIT-006 (Pixel Pipeline, Alpha Blending), REQ-005.03

`timescale 1ns/1ps

module tb_alpha_blend;

    // DUT signals
    reg  [63:0] src_rgba;
    reg  [47:0] dst_rgb;
    reg  [2:0]  blend_mode;
    wire [47:0] result_rgb;

    // Blend mode encoding
    localparam [2:0] BLEND_DISABLED = 3'b000;
    localparam [2:0] BLEND_ADD      = 3'b001;
    localparam [2:0] BLEND_SUBTRACT = 3'b010;
    localparam [2:0] BLEND_BLEND    = 3'b011;

    // Q4.12 constants
    localparam [15:0] Q_ZERO = 16'h0000;
    localparam [15:0] Q_HALF = 16'h0800;  // 0.5
    localparam [15:0] Q_ONE  = 16'h1000;  // 1.0
    localparam [15:0] Q_QTR  = 16'h0400;  // 0.25
    localparam [15:0] Q_3QTR = 16'h0C00;  // 0.75

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    alpha_blend dut (
        .src_rgba   (src_rgba),
        .dst_rgb    (dst_rgb),
        .blend_mode (blend_mode),
        .result_rgb (result_rgb)
    );

    // Extract result channels for readability
    wire [15:0] res_r = result_rgb[47:32];
    wire [15:0] res_g = result_rgb[31:16];
    wire [15:0] res_b = result_rgb[15:0];

    // Check helper: compare a 16-bit value against expected
    /* verilator lint_off UNUSEDSIGNAL */
    task check16(input string name, input [15:0] actual, input [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s - expected 0x%04h, got 0x%04h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Check with tolerance: allow +/- N LSBs for rounding in BLEND mode.
    // Uses absolute difference to avoid unsigned underflow when expected ~ 0.
    /* verilator lint_off UNUSEDSIGNAL */
    task check_approx(input string name, input [15:0] actual, input [15:0] expected, input [15:0] tolerance);
        reg [15:0] diff;
        begin
            if (actual >= expected) begin
                diff = actual - expected;
            end else begin
                diff = expected - actual;
            end
            if (diff <= tolerance) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: %s - expected 0x%04h +/-%0d, got 0x%04h",
                         name, expected, tolerance, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Helper: build src_rgba from four Q4.12 channels
    function automatic [63:0] make_src(input [15:0] r, input [15:0] g,
                                        input [15:0] b, input [15:0] a);
        make_src = {r, g, b, a};
    endfunction

    // Helper: build dst_rgb from three Q4.12 channels
    function automatic [47:0] make_dst(input [15:0] r, input [15:0] g,
                                        input [15:0] b);
        make_dst = {r, g, b};
    endfunction

    initial begin
        $dumpfile("alpha_blend.vcd");
        $dumpvars(0, tb_alpha_blend);

        $display("=== Testing alpha_blend Module ===\n");

        // ============================================================
        // DISABLED Mode: result = src RGB (alpha ignored)
        // ============================================================
        $display("--- DISABLED Mode ---");

        blend_mode = BLEND_DISABLED;

        // Solid red src, blue dst
        src_rgba = make_src(Q_ONE, Q_ZERO, Q_ZERO, Q_ONE);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ONE);
        #1;
        check16("disabled: R passthrough", res_r, Q_ONE);
        check16("disabled: G passthrough", res_g, Q_ZERO);
        check16("disabled: B passthrough", res_b, Q_ZERO);

        // Half-intensity src with zero alpha (alpha ignored in DISABLED)
        src_rgba = make_src(Q_HALF, Q_QTR, Q_3QTR, Q_ZERO);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check16("disabled: R=0.5", res_r, Q_HALF);
        check16("disabled: G=0.25", res_g, Q_QTR);
        check16("disabled: B=0.75", res_b, Q_3QTR);

        // ============================================================
        // ADD Mode: result = saturate(src + dst)
        // ============================================================
        $display("--- ADD Mode ---");

        blend_mode = BLEND_ADD;

        // 0.25 + 0.25 = 0.5 (no saturation)
        src_rgba = make_src(Q_QTR, Q_QTR, Q_QTR, Q_ONE);
        dst_rgb  = make_dst(Q_QTR, Q_QTR, Q_QTR);
        #1;
        check16("add: 0.25+0.25=0.5 R", res_r, Q_HALF);
        check16("add: 0.25+0.25=0.5 G", res_g, Q_HALF);
        check16("add: 0.25+0.25=0.5 B", res_b, Q_HALF);

        // 0.75 + 0.5 = 1.25 -> saturates to 1.0
        src_rgba = make_src(Q_3QTR, Q_3QTR, Q_3QTR, Q_ONE);
        dst_rgb  = make_dst(Q_HALF, Q_HALF, Q_HALF);
        #1;
        check16("add: 0.75+0.5 saturate R", res_r, Q_ONE);
        check16("add: 0.75+0.5 saturate G", res_g, Q_ONE);
        check16("add: 0.75+0.5 saturate B", res_b, Q_ONE);

        // 1.0 + 1.0 = 2.0 -> saturates to 1.0
        src_rgba = make_src(Q_ONE, Q_ONE, Q_ONE, Q_ONE);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check16("add: 1.0+1.0 saturate R", res_r, Q_ONE);
        check16("add: 1.0+1.0 saturate G", res_g, Q_ONE);
        check16("add: 1.0+1.0 saturate B", res_b, Q_ONE);

        // 0 + 0 = 0
        src_rgba = make_src(Q_ZERO, Q_ZERO, Q_ZERO, Q_ONE);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ZERO);
        #1;
        check16("add: 0+0=0 R", res_r, Q_ZERO);
        check16("add: 0+0=0 G", res_g, Q_ZERO);
        check16("add: 0+0=0 B", res_b, Q_ZERO);

        // 0 + 1.0 = 1.0
        src_rgba = make_src(Q_ZERO, Q_ZERO, Q_ZERO, Q_ONE);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check16("add: 0+1.0=1.0 R", res_r, Q_ONE);
        check16("add: 0+1.0=1.0 G", res_g, Q_ONE);
        check16("add: 0+1.0=1.0 B", res_b, Q_ONE);

        // Mixed channels: R=(0.5+0.25), G=(0.75+0.0), B=(0.0+0.5)
        src_rgba = make_src(Q_HALF, Q_3QTR, Q_ZERO, Q_ONE);
        dst_rgb  = make_dst(Q_QTR, Q_ZERO, Q_HALF);
        #1;
        check16("add: mixed R", res_r, Q_3QTR);
        check16("add: mixed G", res_g, Q_3QTR);
        check16("add: mixed B", res_b, Q_HALF);

        // ============================================================
        // SUBTRACT Mode: result = saturate(src - dst), clamp to 0
        // ============================================================
        $display("--- SUBTRACT Mode ---");

        blend_mode = BLEND_SUBTRACT;

        // 0.75 - 0.25 = 0.5
        src_rgba = make_src(Q_3QTR, Q_3QTR, Q_3QTR, Q_ONE);
        dst_rgb  = make_dst(Q_QTR, Q_QTR, Q_QTR);
        #1;
        check16("sub: 0.75-0.25=0.5 R", res_r, Q_HALF);
        check16("sub: 0.75-0.25=0.5 G", res_g, Q_HALF);
        check16("sub: 0.75-0.25=0.5 B", res_b, Q_HALF);

        // 0.25 - 0.75 = -0.5 -> clamp to 0
        src_rgba = make_src(Q_QTR, Q_QTR, Q_QTR, Q_ONE);
        dst_rgb  = make_dst(Q_3QTR, Q_3QTR, Q_3QTR);
        #1;
        check16("sub: 0.25-0.75 clamp R", res_r, Q_ZERO);
        check16("sub: 0.25-0.75 clamp G", res_g, Q_ZERO);
        check16("sub: 0.25-0.75 clamp B", res_b, Q_ZERO);

        // 0 - 1.0 = -1.0 -> clamp to 0
        src_rgba = make_src(Q_ZERO, Q_ZERO, Q_ZERO, Q_ONE);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check16("sub: 0-1.0 clamp R", res_r, Q_ZERO);
        check16("sub: 0-1.0 clamp G", res_g, Q_ZERO);
        check16("sub: 0-1.0 clamp B", res_b, Q_ZERO);

        // 1.0 - 0 = 1.0
        src_rgba = make_src(Q_ONE, Q_ONE, Q_ONE, Q_ONE);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ZERO);
        #1;
        check16("sub: 1.0-0=1.0 R", res_r, Q_ONE);
        check16("sub: 1.0-0=1.0 G", res_g, Q_ONE);
        check16("sub: 1.0-0=1.0 B", res_b, Q_ONE);

        // Same values: 0.5 - 0.5 = 0
        src_rgba = make_src(Q_HALF, Q_HALF, Q_HALF, Q_ONE);
        dst_rgb  = make_dst(Q_HALF, Q_HALF, Q_HALF);
        #1;
        check16("sub: 0.5-0.5=0 R", res_r, Q_ZERO);
        check16("sub: 0.5-0.5=0 G", res_g, Q_ZERO);
        check16("sub: 0.5-0.5=0 B", res_b, Q_ZERO);

        // ============================================================
        // BLEND Mode: result = src * alpha + dst * (1 - alpha)
        // ============================================================
        $display("--- BLEND Mode (Porter-Duff src-over) ---");

        blend_mode = BLEND_BLEND;

        // Alpha=1.0: result = src (full source)
        src_rgba = make_src(Q_ONE, Q_ZERO, Q_HALF, Q_ONE);
        dst_rgb  = make_dst(Q_ZERO, Q_ONE, Q_ZERO);
        #1;
        // src*1.0 + dst*0.0 = src
        check_approx("blend a=1.0: R=src", res_r, Q_ONE, 16'd1);
        check_approx("blend a=1.0: G=src", res_g, Q_ZERO, 16'd1);
        check_approx("blend a=1.0: B=src", res_b, Q_HALF, 16'd1);

        // Alpha=0: result = dst (full destination)
        src_rgba = make_src(Q_ONE, Q_ZERO, Q_HALF, Q_ZERO);
        dst_rgb  = make_dst(Q_ZERO, Q_ONE, Q_QTR);
        #1;
        // src*0.0 + dst*1.0 = dst
        check_approx("blend a=0: R=dst", res_r, Q_ZERO, 16'd1);
        check_approx("blend a=0: G=dst", res_g, Q_ONE, 16'd1);
        check_approx("blend a=0: B=dst", res_b, Q_QTR, 16'd1);

        // Alpha=0.5: result = (src + dst) / 2
        // src=1.0, dst=0.0, alpha=0.5 -> result = 0.5
        src_rgba = make_src(Q_ONE, Q_ONE, Q_ONE, Q_HALF);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ZERO);
        #1;
        check_approx("blend a=0.5 src=1 dst=0: R", res_r, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=1 dst=0: G", res_g, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=1 dst=0: B", res_b, Q_HALF, 16'd1);

        // Alpha=0.5: src=0.0, dst=1.0 -> result = 0.5
        src_rgba = make_src(Q_ZERO, Q_ZERO, Q_ZERO, Q_HALF);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check_approx("blend a=0.5 src=0 dst=1: R", res_r, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=0 dst=1: G", res_g, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=0 dst=1: B", res_b, Q_HALF, 16'd1);

        // Alpha=0.5: src=0.5, dst=0.5 -> result = 0.5
        src_rgba = make_src(Q_HALF, Q_HALF, Q_HALF, Q_HALF);
        dst_rgb  = make_dst(Q_HALF, Q_HALF, Q_HALF);
        #1;
        check_approx("blend a=0.5 src=dst=0.5: R", res_r, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=dst=0.5: G", res_g, Q_HALF, 16'd1);
        check_approx("blend a=0.5 src=dst=0.5: B", res_b, Q_HALF, 16'd1);

        // Alpha=0.25: src=1.0, dst=0.0 -> result = 0.25
        src_rgba = make_src(Q_ONE, Q_ONE, Q_ONE, Q_QTR);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ZERO);
        #1;
        check_approx("blend a=0.25 src=1 dst=0: R", res_r, Q_QTR, 16'd1);
        check_approx("blend a=0.25 src=1 dst=0: G", res_g, Q_QTR, 16'd1);
        check_approx("blend a=0.25 src=1 dst=0: B", res_b, Q_QTR, 16'd1);

        // Alpha=0.75: src=1.0, dst=0.0 -> result = 0.75
        src_rgba = make_src(Q_ONE, Q_ONE, Q_ONE, Q_3QTR);
        dst_rgb  = make_dst(Q_ZERO, Q_ZERO, Q_ZERO);
        #1;
        check_approx("blend a=0.75 src=1 dst=0: R", res_r, Q_3QTR, 16'd1);
        check_approx("blend a=0.75 src=1 dst=0: G", res_g, Q_3QTR, 16'd1);
        check_approx("blend a=0.75 src=1 dst=0: B", res_b, Q_3QTR, 16'd1);

        // Alpha=0.25: src=0.5, dst=1.0 -> 0.5*0.25 + 1.0*0.75 = 0.125 + 0.75 = 0.875
        // 0.875 in Q4.12 = 0x0E00
        src_rgba = make_src(Q_HALF, Q_HALF, Q_HALF, Q_QTR);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check_approx("blend a=0.25 src=0.5 dst=1.0: R", res_r, 16'h0E00, 16'd1);
        check_approx("blend a=0.25 src=0.5 dst=1.0: G", res_g, 16'h0E00, 16'd1);
        check_approx("blend a=0.25 src=0.5 dst=1.0: B", res_b, 16'h0E00, 16'd1);

        // ============================================================
        // Default Mode: unknown codes (100-111) -> passthrough
        // ============================================================
        $display("--- Default/Unknown Modes ---");

        blend_mode = 3'b100;
        src_rgba = make_src(Q_HALF, Q_QTR, Q_3QTR, Q_ONE);
        dst_rgb  = make_dst(Q_ONE, Q_ONE, Q_ONE);
        #1;
        check16("mode 100: R passthrough", res_r, Q_HALF);
        check16("mode 100: G passthrough", res_g, Q_QTR);
        check16("mode 100: B passthrough", res_b, Q_3QTR);

        blend_mode = 3'b111;
        #1;
        check16("mode 111: R passthrough", res_r, Q_HALF);
        check16("mode 111: G passthrough", res_g, Q_QTR);
        check16("mode 111: B passthrough", res_b, Q_3QTR);

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

endmodule
