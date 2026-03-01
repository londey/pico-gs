// Testbench for raster_edge_walk module
// Tests position tracking, edge functions, inside-triangle logic,
// and the DD-025 fragment valid/ready handshake
// Verification: UNIT-005.04 (Iteration FSM)

`timescale 1ns/1ps

module tb_raster_edge_walk;

    // ========================================================================
    // Clock and Reset
    // ========================================================================

    reg clk;           // System clock
    reg rst_n;         // Active-low async reset

    initial begin
        clk = 1'b0;
    end
    always #5 clk = ~clk;  // 100 MHz

    // ========================================================================
    // Control Signals
    // ========================================================================

    reg do_idle;           // Deassert frag_valid
    reg init_pos_e0;       // Init position + e0
    reg init_e1;           // Init e1
    reg init_e2;           // Init e2
    reg do_interpolate;    // INTERPOLATE state
    reg step_x;            // Step right
    reg step_y;            // New row

    // ========================================================================
    // Shared Multiplier Products
    // ========================================================================

    reg signed [21:0] smul_p1;     // Multiplier product 1
    reg signed [21:0] smul_p2;     // Multiplier product 2

    // ========================================================================
    // Edge Coefficients
    // ========================================================================

    reg signed [10:0] edge0_A;     // Edge 0 A
    reg signed [10:0] edge0_B;     // Edge 0 B
    reg signed [20:0] edge0_C;     // Edge 0 C
    reg signed [10:0] edge1_A;     // Edge 1 A
    reg signed [10:0] edge1_B;     // Edge 1 B
    reg signed [20:0] edge1_C;     // Edge 1 C
    reg signed [10:0] edge2_A;     // Edge 2 A
    reg signed [10:0] edge2_B;     // Edge 2 B
    reg signed [20:0] edge2_C;     // Edge 2 C

    // ========================================================================
    // Bounding Box
    // ========================================================================

    reg [9:0] bbox_min_x;          // Bbox min X
    reg [9:0] bbox_min_y;          // Bbox min Y

    // ========================================================================
    // Attribute Inputs (from raster_attr_accum)
    // ========================================================================

    reg [15:0] out_c0r;            // Promoted color0 R
    reg [15:0] out_c0g;            // Promoted color0 G
    reg [15:0] out_c0b;            // Promoted color0 B
    reg [15:0] out_c0a;            // Promoted color0 A
    reg [15:0] out_c1r;            // Promoted color1 R
    reg [15:0] out_c1g;            // Promoted color1 G
    reg [15:0] out_c1b;            // Promoted color1 B
    reg [15:0] out_c1a;            // Promoted color1 A
    reg [15:0] out_z;              // Clamped Z
    reg signed [31:0] uv0u_acc;    // UV0 U raw
    reg signed [31:0] uv0v_acc;    // UV0 V raw
    reg signed [31:0] uv1u_acc;    // UV1 U raw
    reg signed [31:0] uv1v_acc;    // UV1 V raw
    reg signed [31:0] q_acc;       // Q raw

    // ========================================================================
    // Handshake
    // ========================================================================

    reg frag_ready;                // Downstream ready

    // ========================================================================
    // DUT Outputs
    // ========================================================================

    wire frag_valid;               // Fragment valid
    wire [9:0]  frag_x;           // Fragment X
    wire [9:0]  frag_y;           // Fragment Y
    wire [15:0] frag_z;           // Fragment Z
    wire [63:0] frag_color0;      // Fragment color0
    wire [63:0] frag_color1;      // Fragment color1
    wire [31:0] frag_uv0;         // Fragment UV0
    wire [31:0] frag_uv1;         // Fragment UV1
    wire [15:0] frag_q;           // Fragment Q
    wire [9:0]  curr_x;           // Current pixel X
    wire [9:0]  curr_y;           // Current pixel Y
    wire        inside_triangle;  // Inside-triangle test

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    raster_edge_walk dut (
        .clk(clk),
        .rst_n(rst_n),
        .do_idle(do_idle),
        .init_pos_e0(init_pos_e0),
        .init_e1(init_e1),
        .init_e2(init_e2),
        .do_interpolate(do_interpolate),
        .step_x(step_x),
        .step_y(step_y),
        .smul_p1(smul_p1),
        .smul_p2(smul_p2),
        .edge0_A(edge0_A), .edge0_B(edge0_B), .edge0_C(edge0_C),
        .edge1_A(edge1_A), .edge1_B(edge1_B), .edge1_C(edge1_C),
        .edge2_A(edge2_A), .edge2_B(edge2_B), .edge2_C(edge2_C),
        .bbox_min_x(bbox_min_x),
        .bbox_min_y(bbox_min_y),
        .out_c0r(out_c0r), .out_c0g(out_c0g),
        .out_c0b(out_c0b), .out_c0a(out_c0a),
        .out_c1r(out_c1r), .out_c1g(out_c1g),
        .out_c1b(out_c1b), .out_c1a(out_c1a),
        .out_z(out_z),
        .uv0u_acc(uv0u_acc), .uv0v_acc(uv0v_acc),
        .uv1u_acc(uv1u_acc), .uv1v_acc(uv1v_acc),
        .q_acc(q_acc),
        .frag_ready(frag_ready),
        .frag_valid(frag_valid),
        .frag_x(frag_x), .frag_y(frag_y), .frag_z(frag_z),
        .frag_color0(frag_color0), .frag_color1(frag_color1),
        .frag_uv0(frag_uv0), .frag_uv1(frag_uv1),
        .frag_q(frag_q),
        .curr_x(curr_x), .curr_y(curr_y),
        .inside_triangle(inside_triangle)
    );

    // ========================================================================
    // Test Infrastructure
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;

    /* verilator lint_off UNUSEDSIGNAL */
    task check1(input string name,
                input logic actual,
                input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check10(input string name,
                 input [9:0] actual,
                 input [9:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0d, got %0d",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name,
                 input [15:0] actual,
                 input [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%04h, got 0x%04h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check32(input string name,
                 input [31:0] actual,
                 input [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%08h, got 0x%08h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check64(input string name,
                 input [63:0] actual,
                 input [63:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%016h, got 0x%016h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Zero all inputs
    task zero_all_inputs;
        begin
            do_idle = 1'b0;
            init_pos_e0 = 1'b0;
            init_e1 = 1'b0;
            init_e2 = 1'b0;
            do_interpolate = 1'b0;
            step_x = 1'b0;
            step_y = 1'b0;
            smul_p1 = 22'sd0;
            smul_p2 = 22'sd0;
            edge0_A = 11'sd0; edge0_B = 11'sd0; edge0_C = 21'sd0;
            edge1_A = 11'sd0; edge1_B = 11'sd0; edge1_C = 21'sd0;
            edge2_A = 11'sd0; edge2_B = 11'sd0; edge2_C = 21'sd0;
            bbox_min_x = 10'd0;
            bbox_min_y = 10'd0;
            out_c0r = 16'h0000; out_c0g = 16'h0000;
            out_c0b = 16'h0000; out_c0a = 16'h0000;
            out_c1r = 16'h0000; out_c1g = 16'h0000;
            out_c1b = 16'h0000; out_c1a = 16'h0000;
            out_z = 16'h0000;
            uv0u_acc = 32'sd0; uv0v_acc = 32'sd0;
            uv1u_acc = 32'sd0; uv1v_acc = 32'sd0;
            q_acc = 32'sd0;
            frag_ready = 1'b0;
        end
    endtask

    // ========================================================================
    // Test Procedure
    // ========================================================================

    initial begin
        $dumpfile("raster_edge_walk.vcd");
        $dumpvars(0, tb_raster_edge_walk);

        zero_all_inputs;

        // Reset
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        $display("=== Testing raster_edge_walk Module ===\n");

        // ============================================================
        // Test 1: Reset state
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check1("reset: frag_valid", frag_valid, 1'b0);
        check10("reset: curr_x", curr_x, 10'd0);
        check10("reset: curr_y", curr_y, 10'd0);
        check16("reset: frag_z", frag_z, 16'h0000);

        // ============================================================
        // Test 2: Position and edge init (init_pos_e0)
        // ============================================================
        // e0 = smul_p1 + smul_p2 + edge0_C
        // smul_p1=100, smul_p2=200, edge0_C=300 → e0 = 600
        $display("--- Test 2: Position Init (init_pos_e0) ---");
        bbox_min_x = 10'd10;
        bbox_min_y = 10'd20;
        smul_p1 = 22'sd100;
        smul_p2 = 22'sd200;
        edge0_C = 21'sd300;
        init_pos_e0 = 1'b1;
        @(posedge clk);
        #1;
        init_pos_e0 = 1'b0;
        @(posedge clk);
        #1;

        check10("init_pos_e0: curr_x", curr_x, 10'd10);
        check10("init_pos_e0: curr_y", curr_y, 10'd20);

        // ============================================================
        // Test 3: Init e1 and e2
        // ============================================================
        // e1 = smul_p1 + smul_p2 + edge1_C
        // smul_p1=50, smul_p2=60, edge1_C=70 → e1 = 180
        $display("--- Test 3: Init E1 and E2 ---");
        smul_p1 = 22'sd50;
        smul_p2 = 22'sd60;
        edge1_C = 21'sd70;
        init_e1 = 1'b1;
        @(posedge clk);
        #1;
        init_e1 = 1'b0;

        // e2 = smul_p1 + smul_p2 + edge2_C
        // smul_p1=10, smul_p2=20, edge2_C=30 → e2 = 60
        smul_p1 = 22'sd10;
        smul_p2 = 22'sd20;
        edge2_C = 21'sd30;
        init_e2 = 1'b1;
        @(posedge clk);
        #1;
        init_e2 = 1'b0;
        @(posedge clk);
        #1;

        // ============================================================
        // Test 4: Inside triangle — all positive edges
        // ============================================================
        $display("--- Test 4: Inside Triangle (all positive) ---");
        // e0=600, e1=180, e2=60 — all >= 0
        check1("inside: all positive", inside_triangle, 1'b1);

        // ============================================================
        // Test 5: Inside triangle — one negative edge
        // ============================================================
        // Re-init e2 with negative value: smul_p1=-100, smul_p2=-200, edge2_C=-50
        // e2 = -100 + -200 + -50 = -350
        $display("--- Test 5: Inside Triangle (one negative) ---");
        smul_p1 = -22'sd100;
        smul_p2 = -22'sd200;
        edge2_C = -21'sd50;
        init_e2 = 1'b1;
        @(posedge clk);
        #1;
        init_e2 = 1'b0;
        @(posedge clk);
        #1;

        check1("inside: one negative", inside_triangle, 1'b0);

        // Restore e2 positive for later tests
        smul_p1 = 22'sd10;
        smul_p2 = 22'sd20;
        edge2_C = 21'sd30;
        init_e2 = 1'b1;
        @(posedge clk);
        #1;
        init_e2 = 1'b0;
        @(posedge clk);
        #1;

        // ============================================================
        // Test 6: Fragment latch (DD-025 first cycle)
        // ============================================================
        // frag_valid = 0, assert do_interpolate → should latch and assert valid
        $display("--- Test 6: Fragment Latch (DD-025) ---");
        out_c0r = 16'h0A0A;
        out_c0g = 16'h0B0B;
        out_c0b = 16'h0C0C;
        out_c0a = 16'h0FFF;
        out_c1r = 16'h0111;
        out_c1g = 16'h0222;
        out_c1b = 16'h0333;
        out_c1a = 16'h0444;
        out_z = 16'hABCD;
        uv0u_acc = 32'hAAAA_0000;
        uv0v_acc = 32'hBBBB_0000;
        uv1u_acc = 32'h1111_0000;
        uv1v_acc = 32'h2222_0000;
        q_acc = 32'h5555_0000;
        frag_ready = 1'b0;

        do_interpolate = 1'b1;
        @(posedge clk);
        #1;

        // After one clock edge with do_interpolate and !frag_valid, valid should assert
        check1("frag latch: frag_valid", frag_valid, 1'b1);
        check10("frag latch: frag_x", frag_x, 10'd10);
        check10("frag latch: frag_y", frag_y, 10'd20);
        check16("frag latch: frag_z", frag_z, 16'hABCD);
        check64("frag latch: frag_color0",
                frag_color0, {16'h0A0A, 16'h0B0B, 16'h0C0C, 16'h0FFF});
        check64("frag latch: frag_color1",
                frag_color1, {16'h0111, 16'h0222, 16'h0333, 16'h0444});
        check32("frag latch: frag_uv0", frag_uv0, {16'hAAAA, 16'hBBBB});
        check32("frag latch: frag_uv1", frag_uv1, {16'h1111, 16'h2222});
        check16("frag latch: frag_q", frag_q, 16'h5555);

        // ============================================================
        // Test 7: Back-pressure (frag_valid=1, frag_ready=0)
        // ============================================================
        $display("--- Test 7: Back-pressure ---");
        // do_interpolate still asserted, frag_ready=0
        // Fragment outputs should hold stable
        @(posedge clk);
        #1;

        check1("backpressure: frag_valid held", frag_valid, 1'b1);
        check16("backpressure: frag_z stable", frag_z, 16'hABCD);

        // ============================================================
        // Test 8: Handshake complete (frag_ready=1)
        // ============================================================
        $display("--- Test 8: Handshake Complete ---");
        frag_ready = 1'b1;
        @(posedge clk);
        #1;

        // valid should deassert
        check1("handshake: frag_valid deasserts", frag_valid, 1'b0);
        do_interpolate = 1'b0;
        frag_ready = 1'b0;

        // ============================================================
        // Test 9: Step X
        // ============================================================
        $display("--- Test 9: Step X ---");
        edge0_A = 11'sd5;
        edge1_A = 11'sd3;
        edge2_A = -11'sd2;

        step_x = 1'b1;
        @(posedge clk);
        #1;
        step_x = 1'b0;
        @(posedge clk);
        #1;

        // curr_x should increment: 10 + 1 = 11
        check10("step_x: curr_x", curr_x, 10'd11);
        // curr_y unchanged
        check10("step_x: curr_y", curr_y, 10'd20);

        // ============================================================
        // Test 10: Step Y (new row)
        // ============================================================
        $display("--- Test 10: Step Y ---");
        edge0_B = 11'sd7;
        edge1_B = 11'sd4;
        edge2_B = -11'sd1;

        step_y = 1'b1;
        @(posedge clk);
        #1;
        step_y = 1'b0;
        @(posedge clk);
        #1;

        // curr_x resets to bbox_min_x = 10
        check10("step_y: curr_x reset", curr_x, 10'd10);
        // curr_y increments: 20 + 1 = 21
        check10("step_y: curr_y", curr_y, 10'd21);

        // ============================================================
        // Test 11: Idle — deassert frag_valid
        // ============================================================
        $display("--- Test 11: Idle ---");
        // First assert valid via interpolation
        do_interpolate = 1'b1;
        @(posedge clk);
        #1;
        do_interpolate = 1'b0;

        check1("idle: frag_valid before idle", frag_valid, 1'b1);

        do_idle = 1'b1;
        @(posedge clk);
        #1;
        do_idle = 1'b0;
        @(posedge clk);
        #1;

        check1("idle: frag_valid after idle", frag_valid, 1'b0);

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Raster Edge Walk Test Summary ===");
        $display("  Passed: %0d", pass_count);
        $display("  Failed: %0d", fail_count);
        if (fail_count == 0) begin
            $display("ALL TESTS PASSED");
        end else begin
            $display("SOME TESTS FAILED");
        end

        $finish;
    end

endmodule
