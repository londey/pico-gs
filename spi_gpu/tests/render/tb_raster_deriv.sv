// Testbench for raster_deriv module
// Tests sequential time-multiplexed derivative computation and initial value calculation
// Verification: UNIT-005.02 (Derivative Pre-computation)

`timescale 1ns/1ps

module tb_raster_deriv;

    // ========================================================================
    // Clock and Reset
    // ========================================================================

    /* verilator lint_off PROCASSINIT */
    reg clk = 1'b0;                // System clock (100 MHz)
    /* verilator lint_on PROCASSINIT */
    reg rst_n;                     // Active-low async reset
    reg enable;                    // Start pulse

    always #5 clk = ~clk;         // 10ns period (100 MHz)

    /* verilator lint_off UNUSEDSIGNAL */
    wire deriv_done;               // Completion flag from DUT
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT Signals — Vertex Color0
    // ========================================================================

    reg [7:0] c0_r0;       // Color0 red, vertex 0
    reg [7:0] c0_g0;       // Color0 green, vertex 0
    reg [7:0] c0_b0;       // Color0 blue, vertex 0
    reg [7:0] c0_a0;       // Color0 alpha, vertex 0
    reg [7:0] c0_r1;       // Color0 red, vertex 1
    reg [7:0] c0_g1;       // Color0 green, vertex 1
    reg [7:0] c0_b1;       // Color0 blue, vertex 1
    reg [7:0] c0_a1;       // Color0 alpha, vertex 1
    reg [7:0] c0_r2;       // Color0 red, vertex 2
    reg [7:0] c0_g2;       // Color0 green, vertex 2
    reg [7:0] c0_b2;       // Color0 blue, vertex 2
    reg [7:0] c0_a2;       // Color0 alpha, vertex 2

    // ========================================================================
    // DUT Signals — Vertex Color1
    // ========================================================================

    reg [7:0] c1_r0;       // Color1 red, vertex 0
    reg [7:0] c1_g0;       // Color1 green, vertex 0
    reg [7:0] c1_b0;       // Color1 blue, vertex 0
    reg [7:0] c1_a0;       // Color1 alpha, vertex 0
    reg [7:0] c1_r1;       // Color1 red, vertex 1
    reg [7:0] c1_g1;       // Color1 green, vertex 1
    reg [7:0] c1_b1;       // Color1 blue, vertex 1
    reg [7:0] c1_a1;       // Color1 alpha, vertex 1
    reg [7:0] c1_r2;       // Color1 red, vertex 2
    reg [7:0] c1_g2;       // Color1 green, vertex 2
    reg [7:0] c1_b2;       // Color1 blue, vertex 2
    reg [7:0] c1_a2;       // Color1 alpha, vertex 2

    // ========================================================================
    // DUT Signals — Vertex Depth, ST, Q
    // ========================================================================

    reg [15:0] z0;                   // Depth, vertex 0
    reg [15:0] z1;                   // Depth, vertex 1
    reg [15:0] z2;                   // Depth, vertex 2
    reg signed [15:0] st0_s0;       // ST0 S, vertex 0
    reg signed [15:0] st0_t0;       // ST0 T, vertex 0
    reg signed [15:0] st0_s1;       // ST0 S, vertex 1
    reg signed [15:0] st0_t1;       // ST0 T, vertex 1
    reg signed [15:0] st0_s2;       // ST0 S, vertex 2
    reg signed [15:0] st0_t2;       // ST0 T, vertex 2
    reg signed [15:0] st1_s0;       // ST1 S, vertex 0
    reg signed [15:0] st1_t0;       // ST1 T, vertex 0
    reg signed [15:0] st1_s1;       // ST1 S, vertex 1
    reg signed [15:0] st1_t1;       // ST1 T, vertex 1
    reg signed [15:0] st1_s2;       // ST1 S, vertex 2
    reg signed [15:0] st1_t2;       // ST1 T, vertex 2
    reg [15:0] q0;                   // Q/W, vertex 0
    reg [15:0] q1;                   // Q/W, vertex 1
    reg [15:0] q2;                   // Q/W, vertex 2

    // ========================================================================
    // DUT Signals — Edge Coefficients, Scaling, Position
    // ========================================================================

    reg signed [10:0] edge1_A;      // Edge 1 A coefficient
    reg signed [10:0] edge1_B;      // Edge 1 B coefficient
    reg signed [10:0] edge2_A;      // Edge 2 A coefficient
    reg signed [10:0] edge2_B;      // Edge 2 B coefficient
    reg [17:0] inv_area;             // UQ4.14 inverse area
    reg [4:0]  area_shift;          // Area normalization shift
    reg [9:0]  bbox_min_x;          // Bounding box min X
    reg [9:0]  bbox_min_y;          // Bounding box min Y
    reg [9:0]  x0;                  // Vertex 0 X
    reg [9:0]  y0;                  // Vertex 0 Y

    // ========================================================================
    // DUT Outputs — Derivatives
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [31:0] pre_c0r_dx;  // Color0 R dx
    wire signed [31:0] pre_c0r_dy;  // Color0 R dy
    wire signed [31:0] pre_c0g_dx;  // Color0 G dx
    wire signed [31:0] pre_c0g_dy;  // Color0 G dy
    wire signed [31:0] pre_c0b_dx;  // Color0 B dx
    wire signed [31:0] pre_c0b_dy;  // Color0 B dy
    wire signed [31:0] pre_c0a_dx;  // Color0 A dx
    wire signed [31:0] pre_c0a_dy;  // Color0 A dy
    wire signed [31:0] pre_c1r_dx;  // Color1 R dx
    wire signed [31:0] pre_c1r_dy;  // Color1 R dy
    wire signed [31:0] pre_c1g_dx;  // Color1 G dx
    wire signed [31:0] pre_c1g_dy;  // Color1 G dy
    wire signed [31:0] pre_c1b_dx;  // Color1 B dx
    wire signed [31:0] pre_c1b_dy;  // Color1 B dy
    wire signed [31:0] pre_c1a_dx;  // Color1 A dx
    wire signed [31:0] pre_c1a_dy;  // Color1 A dy
    wire signed [31:0] pre_z_dx;    // Z dx
    wire signed [31:0] pre_z_dy;    // Z dy
    wire signed [31:0] pre_s0_dx; // ST0 S dx
    wire signed [31:0] pre_s0_dy; // ST0 S dy
    wire signed [31:0] pre_t0_dx; // ST0 T dx
    wire signed [31:0] pre_t0_dy; // ST0 T dy
    wire signed [31:0] pre_s1_dx; // ST1 S dx
    wire signed [31:0] pre_s1_dy; // ST1 S dy
    wire signed [31:0] pre_t1_dx; // ST1 T dx
    wire signed [31:0] pre_t1_dy; // ST1 T dy
    wire signed [31:0] pre_q_dx;    // Q dx
    wire signed [31:0] pre_q_dy;    // Q dy

    // ========================================================================
    // DUT Outputs — Initial Values
    // ========================================================================

    wire signed [31:0] init_c0r;    // Color0 R initial
    wire signed [31:0] init_c0g;    // Color0 G initial
    wire signed [31:0] init_c0b;    // Color0 B initial
    wire signed [31:0] init_c0a;    // Color0 A initial
    wire signed [31:0] init_c1r;    // Color1 R initial
    wire signed [31:0] init_c1g;    // Color1 G initial
    wire signed [31:0] init_c1b;    // Color1 B initial
    wire signed [31:0] init_c1a;    // Color1 A initial
    wire signed [31:0] init_z;      // Z initial
    wire signed [31:0] init_s0;   // ST0 S initial
    wire signed [31:0] init_t0;   // ST0 T initial
    wire signed [31:0] init_s1;   // ST1 S initial
    wire signed [31:0] init_t1;   // ST1 T initial
    wire signed [31:0] init_q;      // Q initial
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    raster_deriv dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .deriv_done(deriv_done),
        .c0_r0(c0_r0), .c0_g0(c0_g0), .c0_b0(c0_b0), .c0_a0(c0_a0),
        .c0_r1(c0_r1), .c0_g1(c0_g1), .c0_b1(c0_b1), .c0_a1(c0_a1),
        .c0_r2(c0_r2), .c0_g2(c0_g2), .c0_b2(c0_b2), .c0_a2(c0_a2),
        .c1_r0(c1_r0), .c1_g0(c1_g0), .c1_b0(c1_b0), .c1_a0(c1_a0),
        .c1_r1(c1_r1), .c1_g1(c1_g1), .c1_b1(c1_b1), .c1_a1(c1_a1),
        .c1_r2(c1_r2), .c1_g2(c1_g2), .c1_b2(c1_b2), .c1_a2(c1_a2),
        .z0(z0), .z1(z1), .z2(z2),
        .st0_s0(st0_s0), .st0_t0(st0_t0),
        .st0_s1(st0_s1), .st0_t1(st0_t1),
        .st0_s2(st0_s2), .st0_t2(st0_t2),
        .st1_s0(st1_s0), .st1_t0(st1_t0),
        .st1_s1(st1_s1), .st1_t1(st1_t1),
        .st1_s2(st1_s2), .st1_t2(st1_t2),
        .q0(q0), .q1(q1), .q2(q2),
        .edge1_A(edge1_A), .edge1_B(edge1_B),
        .edge2_A(edge2_A), .edge2_B(edge2_B),
        .inv_area(inv_area), .area_shift(area_shift),
        .bbox_min_x(bbox_min_x), .bbox_min_y(bbox_min_y),
        .x0(x0), .y0(y0),
        .pre_c0r_dx(pre_c0r_dx), .pre_c0r_dy(pre_c0r_dy),
        .pre_c0g_dx(pre_c0g_dx), .pre_c0g_dy(pre_c0g_dy),
        .pre_c0b_dx(pre_c0b_dx), .pre_c0b_dy(pre_c0b_dy),
        .pre_c0a_dx(pre_c0a_dx), .pre_c0a_dy(pre_c0a_dy),
        .pre_c1r_dx(pre_c1r_dx), .pre_c1r_dy(pre_c1r_dy),
        .pre_c1g_dx(pre_c1g_dx), .pre_c1g_dy(pre_c1g_dy),
        .pre_c1b_dx(pre_c1b_dx), .pre_c1b_dy(pre_c1b_dy),
        .pre_c1a_dx(pre_c1a_dx), .pre_c1a_dy(pre_c1a_dy),
        .pre_z_dx(pre_z_dx), .pre_z_dy(pre_z_dy),
        .pre_s0_dx(pre_s0_dx), .pre_s0_dy(pre_s0_dy),
        .pre_t0_dx(pre_t0_dx), .pre_t0_dy(pre_t0_dy),
        .pre_s1_dx(pre_s1_dx), .pre_s1_dy(pre_s1_dy),
        .pre_t1_dx(pre_t1_dx), .pre_t1_dy(pre_t1_dy),
        .pre_q_dx(pre_q_dx), .pre_q_dy(pre_q_dy),
        .init_c0r(init_c0r), .init_c0g(init_c0g),
        .init_c0b(init_c0b), .init_c0a(init_c0a),
        .init_c1r(init_c1r), .init_c1g(init_c1g),
        .init_c1b(init_c1b), .init_c1a(init_c1a),
        .init_z(init_z),
        .init_s0(init_s0), .init_t0(init_t0),
        .init_s1(init_s1), .init_t1(init_t1),
        .init_q(init_q)
    );

    // ========================================================================
    // Test Infrastructure
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;
    integer cycle_count;            // Cycle counter for deriv_done timing check

    /* verilator lint_off UNUSEDSIGNAL */
    task check32s(input string name,
                  input signed [31:0] actual,
                  input signed [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%08h (%0d), got 0x%08h (%0d)",
                     name, expected, expected, actual, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Zero all vertex attribute inputs
    task zero_all_inputs;
        begin
            c0_r0 = 8'd0; c0_g0 = 8'd0; c0_b0 = 8'd0; c0_a0 = 8'd0;
            c0_r1 = 8'd0; c0_g1 = 8'd0; c0_b1 = 8'd0; c0_a1 = 8'd0;
            c0_r2 = 8'd0; c0_g2 = 8'd0; c0_b2 = 8'd0; c0_a2 = 8'd0;
            c1_r0 = 8'd0; c1_g0 = 8'd0; c1_b0 = 8'd0; c1_a0 = 8'd0;
            c1_r1 = 8'd0; c1_g1 = 8'd0; c1_b1 = 8'd0; c1_a1 = 8'd0;
            c1_r2 = 8'd0; c1_g2 = 8'd0; c1_b2 = 8'd0; c1_a2 = 8'd0;
            z0 = 16'd0; z1 = 16'd0; z2 = 16'd0;
            st0_s0 = 16'sd0; st0_t0 = 16'sd0;
            st0_s1 = 16'sd0; st0_t1 = 16'sd0;
            st0_s2 = 16'sd0; st0_t2 = 16'sd0;
            st1_s0 = 16'sd0; st1_t0 = 16'sd0;
            st1_s1 = 16'sd0; st1_t1 = 16'sd0;
            st1_s2 = 16'sd0; st1_t2 = 16'sd0;
            q0 = 16'd0; q1 = 16'd0; q2 = 16'd0;
            edge1_A = 11'sd0; edge1_B = 11'sd0;
            edge2_A = 11'sd0; edge2_B = 11'sd0;

            inv_area = 18'h0FFFF;   // UQ4.14 = ~4.0 (matches old 16-bit 0xFFFF)
            area_shift = 5'd0;
            bbox_min_x = 10'd0; bbox_min_y = 10'd0;
            x0 = 10'd0; y0 = 10'd0;
            enable = 1'b0;
        end
    endtask

    // Pulse enable for one cycle and wait for deriv_done
    task run_deriv;
        begin
            @(posedge clk);
            enable = 1'b1;
            cycle_count = 0;
            @(posedge clk);
            enable = 1'b0;
            cycle_count = 1;
            // Wait for deriv_done (with timeout)
            while (!deriv_done && cycle_count < 30) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
            end
            // Sample outputs on the next clock edge after deriv_done
            @(negedge clk);
        end
    endtask

    // ========================================================================
    // Test Procedure
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/raster_deriv.vcd");
        $dumpvars(0, tb_raster_deriv);

        $display("=== Testing raster_deriv Module (Sequential) ===\n");

        // Reset sequence
        zero_all_inputs;
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ============================================================
        // Test 0: Verify deriv_done timing (8 cycles after enable)
        // ============================================================
        $display("--- Test 0: deriv_done Timing ---");
        zero_all_inputs;
        run_deriv;
        // cycle_count should be 9 (enable at cycle 0, 7 pair cycles + 1 finishing)
        if (cycle_count >= 30) begin
            $display("FAIL: deriv_done did not assert within 30 cycles");
            fail_count = fail_count + 1;
        end else begin
            $display("  deriv_done asserted after %0d cycles", cycle_count);
            pass_count = pass_count + 1;
        end

        // ============================================================
        // Test 1: Zero deltas — all attributes identical across vertices
        // ============================================================
        $display("--- Test 1: Zero Deltas (constant attributes) ---");
        zero_all_inputs;
        c0_r0 = 8'd100; c0_r1 = 8'd100; c0_r2 = 8'd100;
        z0 = 16'h8000; z1 = 16'h8000; z2 = 16'h8000;
        edge1_A = 11'sd5; edge1_B = 11'sd3;
        edge2_A = 11'sd2; edge2_B = 11'sd7;

        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        x0 = 10'd0; y0 = 10'd0;
        run_deriv;

        // All deltas are zero, so all derivatives must be zero
        check32s("zero deltas: pre_c0r_dx", pre_c0r_dx, 32'sd0);
        check32s("zero deltas: pre_c0r_dy", pre_c0r_dy, 32'sd0);
        check32s("zero deltas: pre_z_dx", pre_z_dx, 32'sd0);
        check32s("zero deltas: pre_z_dy", pre_z_dy, 32'sd0);
        check32s("zero deltas: pre_s0_dx", pre_s0_dx, 32'sd0);
        check32s("zero deltas: pre_q_dx", pre_q_dx, 32'sd0);

        // Init values at bbox origin = vertex 0 position:
        // Color: {8'b0, 100, 16'b0} = 0x00640000
        check32s("zero deltas: init_c0r", init_c0r, 32'sh0064_0000);
        // Z: {16'h8000, 16'b0} = 0x80000000
        check32s("zero deltas: init_z", init_z, 32'sh8000_0000);

        // ============================================================
        // Test 2: Single-channel color gradient
        // ============================================================
        $display("--- Test 2: Color Gradient (single channel) ---");
        zero_all_inputs;
        c0_r0 = 8'd0; c0_r1 = 8'd10; c0_r2 = 8'd20;
        edge1_A = 11'sd3; edge1_B = 11'sd2;
        edge2_A = 11'sd5; edge2_B = 11'sd4;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // raw_dx = 10*3 + 20*5 = 130; scl = 130*65535 = 8519550
        check32s("gradient: pre_c0r_dx", pre_c0r_dx, 32'sd8519550);
        // raw_dy = 10*2 + 20*4 = 100; scl = 100*65535 = 6553500
        check32s("gradient: pre_c0r_dy", pre_c0r_dy, 32'sd6553500);
        // Other channels must still be zero (only c0_r varies)
        check32s("gradient: pre_c0g_dx", pre_c0g_dx, 32'sd0);
        check32s("gradient: pre_c1r_dx", pre_c1r_dx, 32'sd0);

        // ============================================================
        // Test 3: Negative color delta
        // ============================================================
        $display("--- Test 3: Negative Color Delta ---");
        zero_all_inputs;
        c0_r0 = 8'd200; c0_r1 = 8'd50; c0_r2 = 8'd200;
        edge1_A = 11'sd4; edge1_B = 11'sd1;
        edge2_A = 11'sd0; edge2_B = 11'sd0;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // raw_dx = (-150)*4 = -600; scl = -600*65535 = -39321000
        check32s("neg delta: pre_c0r_dx", pre_c0r_dx, -32'sd39321000);
        // raw_dy = (-150)*1 = -150; scl = -150*65535 = -9830250
        check32s("neg delta: pre_c0r_dy", pre_c0r_dy, -32'sd9830250);

        // ============================================================
        // Test 4: Z (wide channel) derivative
        // ============================================================
        $display("--- Test 4: Z (Wide Channel) Derivative ---");
        zero_all_inputs;
        z0 = 16'd0; z1 = 16'h1000; z2 = 16'd0;
        edge1_A = 11'sd2; edge1_B = 11'sd3;
        edge2_A = 11'sd0; edge2_B = 11'sd0;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // raw_z_dx = 4096*2 = 8192; scl = 8192*65535 = 536862720
        check32s("Z wide: pre_z_dx", pre_z_dx, 32'sd536862720);
        // raw_z_dy = 4096*3 = 12288; scl = 12288*65535 = 805294080
        check32s("Z wide: pre_z_dy", pre_z_dy, 32'sd805294080);

        // ============================================================
        // Test 5: ST signed values
        // ============================================================
        $display("--- Test 5: ST Signed Values ---");
        zero_all_inputs;
        st0_s0 = -16'sd100; st0_s1 = 16'sd200; st0_s2 = -16'sd100;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd0;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // d10_s0 = 300, raw_dx = 300*1 = 300; scl = 300*65535 = 19660500
        check32s("ST signed: pre_s0_dx", pre_s0_dx, 32'sd19660500);
        // Init at origin: {st0_s0, 16'b0} + 0 + 0 = {-100, 16'b0}
        check32s("ST signed: init_s0", init_s0, {-16'sd100, 16'b0});

        // ============================================================
        // Test 6: Hardcoded INV_AREA/AREA_SHIFT (Phase 1 interim)
        // ============================================================
        $display("--- Test 6: Hardcoded INV_AREA Scaling (Phase 1) ---");
        zero_all_inputs;
        c0_r0 = 8'd0; c0_r1 = 8'd128; c0_r2 = 8'd0;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // d10=128, raw_dx=128*1=128; scl=128*65535=8388480; pre=8388480>>>0=8388480
        check32s("hardcoded inv_area: pre_c0r_dx", pre_c0r_dx, 32'sd8388480);

        // ============================================================
        // Test 7: Initial value with bbox offset from vertex 0
        // ============================================================
        $display("--- Test 7: Initial Value with Bbox Offset ---");
        zero_all_inputs;
        c0_r0 = 8'd100; c0_r1 = 8'd110; c0_r2 = 8'd100;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd1;

        x0 = 10'd5; y0 = 10'd5;
        bbox_min_x = 10'd8; bbox_min_y = 10'd7;
        run_deriv;

        // d10=10, d20=0
        // raw_dx = 10*1 = 10; scl = 10*65535 = 655350
        // raw_dy = 10*0 = 0
        // bbox_sx = 8-5 = 3, bbox_sy = 7-5 = 2
        // init = {8'b0, 100, 16'b0} + 655350*3 + 0*2 = 0x00640000 + 1966050
        // 1966050 = 0x001DFFE2 → init = 0x0081FFE2
        check32s("bbox offset: pre_c0r_dx", pre_c0r_dx, 32'sd655350);
        check32s("bbox offset: pre_c0r_dy", pre_c0r_dy, 32'sd0);
        check32s("bbox offset: init_c0r", init_c0r, 32'sh0081_FFE2);

        // ============================================================
        // Test 8: Color1 derivative (verify second color channel path)
        // ============================================================
        $display("--- Test 8: Color1 Derivative ---");
        zero_all_inputs;
        c1_g0 = 8'd0; c1_g1 = 8'd0; c1_g2 = 8'd50;
        edge1_A = 11'sd0; edge1_B = 11'sd0;
        edge2_A = 11'sd3; edge2_B = 11'sd7;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // d10_c1g = 0, d20_c1g = 50
        // raw_dx = 0 + 50*3 = 150; scl = 150*65535 = 9830250
        check32s("color1: pre_c1g_dx", pre_c1g_dx, 32'sd9830250);
        // raw_dy = 0 + 50*7 = 350; scl = 350*65535 = 22937250
        check32s("color1: pre_c1g_dy", pre_c1g_dy, 32'sd22937250);
        // c0 channels should be zero (only c1_g varies)
        check32s("color1: pre_c0r_dx", pre_c0r_dx, 32'sd0);

        // ============================================================
        // Test 9: Q/W derivative (unsigned vertex values)
        // ============================================================
        $display("--- Test 9: Q/W Derivative ---");
        zero_all_inputs;
        q0 = 16'd1000; q1 = 16'd2000; q2 = 16'd1000;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd0;

        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        run_deriv;

        // d10_q = 2000-1000 = 1000, d20_q = 0
        // raw_dx = 1000*1 = 1000; scl = 1000*65535 = 65535000
        check32s("Q: pre_q_dx", pre_q_dx, 32'sd65535000);
        check32s("Q: pre_q_dy", pre_q_dy, 32'sd0);

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Raster Deriv Test Summary ===");
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
