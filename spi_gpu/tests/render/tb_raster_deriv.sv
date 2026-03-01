// Testbench for raster_deriv module
// Tests purely combinational derivative computation and initial value calculation
// Verification: UNIT-005.02 (Derivative Pre-computation)

`timescale 1ns/1ps

module tb_raster_deriv;

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
    // DUT Signals — Vertex Depth, UV, Q
    // ========================================================================

    reg [15:0] z0;                   // Depth, vertex 0
    reg [15:0] z1;                   // Depth, vertex 1
    reg [15:0] z2;                   // Depth, vertex 2
    reg signed [15:0] uv0_u0;       // UV0 U, vertex 0
    reg signed [15:0] uv0_v0;       // UV0 V, vertex 0
    reg signed [15:0] uv0_u1;       // UV0 U, vertex 1
    reg signed [15:0] uv0_v1;       // UV0 V, vertex 1
    reg signed [15:0] uv0_u2;       // UV0 U, vertex 2
    reg signed [15:0] uv0_v2;       // UV0 V, vertex 2
    reg signed [15:0] uv1_u0;       // UV1 U, vertex 0
    reg signed [15:0] uv1_v0;       // UV1 V, vertex 0
    reg signed [15:0] uv1_u1;       // UV1 U, vertex 1
    reg signed [15:0] uv1_v1;       // UV1 V, vertex 1
    reg signed [15:0] uv1_u2;       // UV1 U, vertex 2
    reg signed [15:0] uv1_v2;       // UV1 V, vertex 2
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
    reg [15:0] inv_area_reg;        // 1/area scaling factor
    reg [3:0]  area_shift_reg;      // Barrel-shift count
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
    wire signed [31:0] pre_uv0u_dx; // UV0 U dx
    wire signed [31:0] pre_uv0u_dy; // UV0 U dy
    wire signed [31:0] pre_uv0v_dx; // UV0 V dx
    wire signed [31:0] pre_uv0v_dy; // UV0 V dy
    wire signed [31:0] pre_uv1u_dx; // UV1 U dx
    wire signed [31:0] pre_uv1u_dy; // UV1 U dy
    wire signed [31:0] pre_uv1v_dx; // UV1 V dx
    wire signed [31:0] pre_uv1v_dy; // UV1 V dy
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
    wire signed [31:0] init_uv0u;   // UV0 U initial
    wire signed [31:0] init_uv0v;   // UV0 V initial
    wire signed [31:0] init_uv1u;   // UV1 U initial
    wire signed [31:0] init_uv1v;   // UV1 V initial
    wire signed [31:0] init_q;      // Q initial
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    raster_deriv dut (
        .c0_r0(c0_r0), .c0_g0(c0_g0), .c0_b0(c0_b0), .c0_a0(c0_a0),
        .c0_r1(c0_r1), .c0_g1(c0_g1), .c0_b1(c0_b1), .c0_a1(c0_a1),
        .c0_r2(c0_r2), .c0_g2(c0_g2), .c0_b2(c0_b2), .c0_a2(c0_a2),
        .c1_r0(c1_r0), .c1_g0(c1_g0), .c1_b0(c1_b0), .c1_a0(c1_a0),
        .c1_r1(c1_r1), .c1_g1(c1_g1), .c1_b1(c1_b1), .c1_a1(c1_a1),
        .c1_r2(c1_r2), .c1_g2(c1_g2), .c1_b2(c1_b2), .c1_a2(c1_a2),
        .z0(z0), .z1(z1), .z2(z2),
        .uv0_u0(uv0_u0), .uv0_v0(uv0_v0),
        .uv0_u1(uv0_u1), .uv0_v1(uv0_v1),
        .uv0_u2(uv0_u2), .uv0_v2(uv0_v2),
        .uv1_u0(uv1_u0), .uv1_v0(uv1_v0),
        .uv1_u1(uv1_u1), .uv1_v1(uv1_v1),
        .uv1_u2(uv1_u2), .uv1_v2(uv1_v2),
        .q0(q0), .q1(q1), .q2(q2),
        .edge1_A(edge1_A), .edge1_B(edge1_B),
        .edge2_A(edge2_A), .edge2_B(edge2_B),
        .inv_area_reg(inv_area_reg), .area_shift_reg(area_shift_reg),
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
        .pre_uv0u_dx(pre_uv0u_dx), .pre_uv0u_dy(pre_uv0u_dy),
        .pre_uv0v_dx(pre_uv0v_dx), .pre_uv0v_dy(pre_uv0v_dy),
        .pre_uv1u_dx(pre_uv1u_dx), .pre_uv1u_dy(pre_uv1u_dy),
        .pre_uv1v_dx(pre_uv1v_dx), .pre_uv1v_dy(pre_uv1v_dy),
        .pre_q_dx(pre_q_dx), .pre_q_dy(pre_q_dy),
        .init_c0r(init_c0r), .init_c0g(init_c0g),
        .init_c0b(init_c0b), .init_c0a(init_c0a),
        .init_c1r(init_c1r), .init_c1g(init_c1g),
        .init_c1b(init_c1b), .init_c1a(init_c1a),
        .init_z(init_z),
        .init_uv0u(init_uv0u), .init_uv0v(init_uv0v),
        .init_uv1u(init_uv1u), .init_uv1v(init_uv1v),
        .init_q(init_q)
    );

    // ========================================================================
    // Test Infrastructure
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;

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
            uv0_u0 = 16'sd0; uv0_v0 = 16'sd0;
            uv0_u1 = 16'sd0; uv0_v1 = 16'sd0;
            uv0_u2 = 16'sd0; uv0_v2 = 16'sd0;
            uv1_u0 = 16'sd0; uv1_v0 = 16'sd0;
            uv1_u1 = 16'sd0; uv1_v1 = 16'sd0;
            uv1_u2 = 16'sd0; uv1_v2 = 16'sd0;
            q0 = 16'd0; q1 = 16'd0; q2 = 16'd0;
            edge1_A = 11'sd0; edge1_B = 11'sd0;
            edge2_A = 11'sd0; edge2_B = 11'sd0;
            inv_area_reg = 16'd0;
            area_shift_reg = 4'd0;
            bbox_min_x = 10'd0; bbox_min_y = 10'd0;
            x0 = 10'd0; y0 = 10'd0;
        end
    endtask

    // ========================================================================
    // Test Procedure
    // ========================================================================

    initial begin
        $dumpfile("raster_deriv.vcd");
        $dumpvars(0, tb_raster_deriv);

        $display("=== Testing raster_deriv Module ===\n");

        // ============================================================
        // Test 1: Zero deltas — all attributes identical across vertices
        // ============================================================
        $display("--- Test 1: Zero Deltas (constant attributes) ---");
        zero_all_inputs;
        c0_r0 = 8'd100; c0_r1 = 8'd100; c0_r2 = 8'd100;
        z0 = 16'h8000; z1 = 16'h8000; z2 = 16'h8000;
        edge1_A = 11'sd5; edge1_B = 11'sd3;
        edge2_A = 11'sd2; edge2_B = 11'sd7;
        inv_area_reg = 16'd1000;
        area_shift_reg = 4'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        x0 = 10'd0; y0 = 10'd0;
        #1;

        // All deltas are zero, so all derivatives must be zero
        check32s("zero deltas: pre_c0r_dx", pre_c0r_dx, 32'sd0);
        check32s("zero deltas: pre_c0r_dy", pre_c0r_dy, 32'sd0);
        check32s("zero deltas: pre_z_dx", pre_z_dx, 32'sd0);
        check32s("zero deltas: pre_z_dy", pre_z_dy, 32'sd0);
        check32s("zero deltas: pre_uv0u_dx", pre_uv0u_dx, 32'sd0);
        check32s("zero deltas: pre_q_dx", pre_q_dx, 32'sd0);

        // Init values at bbox origin = vertex 0 position:
        // Color: {8'b0, 100, 16'b0} = 0x00640000
        check32s("zero deltas: init_c0r", init_c0r, 32'sh0064_0000);
        // Z: {16'h8000, 16'b0} = 0x80000000
        check32s("zero deltas: init_z", init_z, 32'sh8000_0000);

        // ============================================================
        // Test 2: Single-channel color gradient
        // ============================================================
        // c0_r varies: v0=0, v1=10, v2=20
        // d10_c0r = 10, d20_c0r = 20
        // With inv_area_reg=1, area_shift=0:
        //   raw_dx = 10 * edge1_A + 20 * edge2_A
        //   pre_dx = raw_dx * 1 >>> 0 = raw_dx
        $display("--- Test 2: Color Gradient (single channel) ---");
        zero_all_inputs;
        c0_r0 = 8'd0; c0_r1 = 8'd10; c0_r2 = 8'd20;
        edge1_A = 11'sd3; edge1_B = 11'sd2;
        edge2_A = 11'sd5; edge2_B = 11'sd4;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // raw_dx = 10*3 + 20*5 = 30+100 = 130; pre = 130*1 >>> 0 = 130
        check32s("gradient: pre_c0r_dx", pre_c0r_dx, 32'sd130);
        // raw_dy = 10*2 + 20*4 = 20+80 = 100; pre = 100
        check32s("gradient: pre_c0r_dy", pre_c0r_dy, 32'sd100);
        // Other channels must still be zero (only c0_r varies)
        check32s("gradient: pre_c0g_dx", pre_c0g_dx, 32'sd0);
        check32s("gradient: pre_c1r_dx", pre_c1r_dx, 32'sd0);

        // ============================================================
        // Test 3: Negative color delta
        // ============================================================
        // c0_r: v0=200, v1=50, v2=200
        // d10 = 50-200 = -150 (signed 9-bit)
        // d20 = 0
        $display("--- Test 3: Negative Color Delta ---");
        zero_all_inputs;
        c0_r0 = 8'd200; c0_r1 = 8'd50; c0_r2 = 8'd200;
        edge1_A = 11'sd4; edge1_B = 11'sd1;
        edge2_A = 11'sd0; edge2_B = 11'sd0;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // raw_dx = (-150)*4 + 0*0 = -600; pre = -600
        check32s("neg delta: pre_c0r_dx", pre_c0r_dx, -32'sd600);
        // raw_dy = (-150)*1 + 0 = -150; pre = -150
        check32s("neg delta: pre_c0r_dy", pre_c0r_dy, -32'sd150);

        // ============================================================
        // Test 4: Z (wide channel) derivative
        // ============================================================
        // Z: v0=0, v1=0x1000 (4096), v2=0
        // d10_z = 4096 (17-bit signed), d20_z = 0
        $display("--- Test 4: Z (Wide Channel) Derivative ---");
        zero_all_inputs;
        z0 = 16'd0; z1 = 16'h1000; z2 = 16'd0;
        edge1_A = 11'sd2; edge1_B = 11'sd3;
        edge2_A = 11'sd0; edge2_B = 11'sd0;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // raw_z_dx = 4096*2 + 0 = 8192; pre = 8192
        check32s("Z wide: pre_z_dx", pre_z_dx, 32'sd8192);
        // raw_z_dy = 4096*3 + 0 = 12288
        check32s("Z wide: pre_z_dy", pre_z_dy, 32'sd12288);

        // ============================================================
        // Test 5: UV signed values
        // ============================================================
        // UV0_U: v0=-100, v1=+200, v2=-100 (Q4.12 signed)
        // d10_uv0u = 200-(-100) = 300, d20 = 0
        $display("--- Test 5: UV Signed Values ---");
        zero_all_inputs;
        uv0_u0 = -16'sd100; uv0_u1 = 16'sd200; uv0_u2 = -16'sd100;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd0;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // d10_uv0u = 300, raw_dx = 300*1 + 0 = 300; pre = 300
        check32s("UV signed: pre_uv0u_dx", pre_uv0u_dx, 32'sd300);
        // Init at origin: {uv0_u0, 16'b0} + 0 + 0 = {-100, 16'b0}
        // -100 in 16-bit = 0xFF9C, extended to 32-bit: {0xFF9C, 16'h0000} = 0xFF9C0000
        check32s("UV signed: init_uv0u", init_uv0u, {-16'sd100, 16'b0});

        // ============================================================
        // Test 6: area_shift_reg effect
        // ============================================================
        // Same raw value, different shift amounts
        $display("--- Test 6: area_shift_reg Scaling ---");
        zero_all_inputs;
        c0_r0 = 8'd0; c0_r1 = 8'd128; c0_r2 = 8'd0;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd0;
        inv_area_reg = 16'd256;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // d10=128, raw_dx=128*1=128; scl=128*256=32768; pre=32768>>>0=32768
        check32s("shift=0: pre_c0r_dx", pre_c0r_dx, 32'sd32768);

        // Now shift by 2 — should divide result by 4
        area_shift_reg = 4'd2;
        #1;
        // pre = 32768 >>> 2 = 8192
        check32s("shift=2: pre_c0r_dx", pre_c0r_dx, 32'sd8192);

        // Shift by 4 — divide by 16
        area_shift_reg = 4'd4;
        #1;
        // pre = 32768 >>> 4 = 2048
        check32s("shift=4: pre_c0r_dx", pre_c0r_dx, 32'sd2048);

        // ============================================================
        // Test 7: Initial value with bbox offset from vertex 0
        // ============================================================
        // bbox origin != vertex 0 → init includes derivative offsets
        $display("--- Test 7: Initial Value with Bbox Offset ---");
        zero_all_inputs;
        c0_r0 = 8'd100; c0_r1 = 8'd110; c0_r2 = 8'd100;
        edge1_A = 11'sd1; edge1_B = 11'sd0;
        edge2_A = 11'sd0; edge2_B = 11'sd1;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd5; y0 = 10'd5;
        bbox_min_x = 10'd8; bbox_min_y = 10'd7;
        #1;

        // d10=10, d20=0
        // pre_c0r_dx = 10*1 + 0 = 10
        // pre_c0r_dy = 10*0 + 0 = 0
        // bbox_sx = 8-5 = 3, bbox_sy = 7-5 = 2
        // init = {8'b0, 100, 16'b0} + 10*3 + 0*2 = 0x00640000 + 30 = 0x0064001E
        check32s("bbox offset: pre_c0r_dx", pre_c0r_dx, 32'sd10);
        check32s("bbox offset: pre_c0r_dy", pre_c0r_dy, 32'sd0);
        check32s("bbox offset: init_c0r", init_c0r, 32'sh0064_001E);

        // ============================================================
        // Test 8: Color1 derivative (verify second color channel path)
        // ============================================================
        $display("--- Test 8: Color1 Derivative ---");
        zero_all_inputs;
        c1_g0 = 8'd0; c1_g1 = 8'd0; c1_g2 = 8'd50;
        edge1_A = 11'sd0; edge1_B = 11'sd0;
        edge2_A = 11'sd3; edge2_B = 11'sd7;
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // d10_c1g = 0, d20_c1g = 50
        // raw_dx = 0 + 50*3 = 150; pre = 150
        check32s("color1: pre_c1g_dx", pre_c1g_dx, 32'sd150);
        // raw_dy = 0 + 50*7 = 350; pre = 350
        check32s("color1: pre_c1g_dy", pre_c1g_dy, 32'sd350);
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
        inv_area_reg = 16'd1;
        area_shift_reg = 4'd0;
        x0 = 10'd0; y0 = 10'd0;
        bbox_min_x = 10'd0; bbox_min_y = 10'd0;
        #1;

        // d10_q = 2000-1000 = 1000, d20_q = 0
        // raw_dx = 1000*1 = 1000; pre = 1000
        check32s("Q: pre_q_dx", pre_q_dx, 32'sd1000);
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
