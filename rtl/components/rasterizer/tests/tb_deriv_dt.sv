// DT-verified testbench for raster_deriv
// Loads triangle stimulus and expected derivatives from hex files.
// Verification: UNIT-005.02 (Derivative Pre-computation)

`timescale 1ns/1ps

module tb_deriv_dt;

    // Clock and reset
    /* verilator lint_off PROCASSINIT */
    reg clk = 1'b0;
    /* verilator lint_on PROCASSINIT */
    reg rst_n;
    always #5 clk = ~clk;

    // Control
    reg enable;
    wire deriv_done;

    // Vertex color0 (8-bit per channel per vertex)
    reg [7:0] c0_r0, c0_g0, c0_b0, c0_a0;
    reg [7:0] c0_r1, c0_g1, c0_b1, c0_a1;
    reg [7:0] c0_r2, c0_g2, c0_b2, c0_a2;

    // Vertex color1
    reg [7:0] c1_r0, c1_g0, c1_b0, c1_a0;
    reg [7:0] c1_r1, c1_g1, c1_b1, c1_a1;
    reg [7:0] c1_r2, c1_g2, c1_b2, c1_a2;

    // Depth
    reg [15:0] z0, z1, z2;

    // ST0
    reg signed [15:0] st0_s0, st0_t0, st0_s1, st0_t1, st0_s2, st0_t2;

    // ST1
    reg signed [15:0] st1_s0, st1_t0, st1_s1, st1_t1, st1_s2, st1_t2;

    // Q
    reg [15:0] q0, q1, q2;

    // Edge coefficients
    reg signed [10:0] edge1_A, edge1_B, edge2_A, edge2_B;

    // Bbox origin
    reg [9:0] bbox_min_x, bbox_min_y;

    // Inverse area
    reg [17:0] inv_area;
    reg  [4:0] area_shift;
    reg        ccw;

    // Vertex 0 position
    reg [9:0] x0, y0;

    // Color derivative outputs (16-bit signed Q8.8)
    wire signed [15:0] pre_c0r_dx, pre_c0r_dy;
    wire signed [15:0] pre_c0g_dx, pre_c0g_dy;
    wire signed [15:0] pre_c0b_dx, pre_c0b_dy;
    wire signed [15:0] pre_c0a_dx, pre_c0a_dy;
    wire signed [15:0] pre_c1r_dx, pre_c1r_dy;
    wire signed [15:0] pre_c1g_dx, pre_c1g_dy;
    wire signed [15:0] pre_c1b_dx, pre_c1b_dy;
    wire signed [15:0] pre_c1a_dx, pre_c1a_dy;
    wire signed [31:0] pre_z_dx,   pre_z_dy;
    wire signed [31:0] pre_s0_dx,  pre_s0_dy;
    wire signed [31:0] pre_t0_dx,  pre_t0_dy;
    wire signed [31:0] pre_s1_dx,  pre_s1_dy;
    wire signed [31:0] pre_t1_dx,  pre_t1_dy;
    wire signed [31:0] pre_q_dx,   pre_q_dy;

    // Color init outputs (24-bit signed)
    wire signed [23:0] init_c0r, init_c0g, init_c0b, init_c0a;
    wire signed [23:0] init_c1r, init_c1g, init_c1b, init_c1a;
    wire signed [31:0] init_z;
    wire signed [31:0] init_s0, init_t0, init_s1, init_t1;
    wire signed [31:0] init_q;

    // DUT instantiation
    raster_deriv dut (
        .clk(clk), .rst_n(rst_n), .enable(enable), .deriv_done(deriv_done),
        .c0_r0(c0_r0), .c0_g0(c0_g0), .c0_b0(c0_b0), .c0_a0(c0_a0),
        .c0_r1(c0_r1), .c0_g1(c0_g1), .c0_b1(c0_b1), .c0_a1(c0_a1),
        .c0_r2(c0_r2), .c0_g2(c0_g2), .c0_b2(c0_b2), .c0_a2(c0_a2),
        .c1_r0(c1_r0), .c1_g0(c1_g0), .c1_b0(c1_b0), .c1_a0(c1_a0),
        .c1_r1(c1_r1), .c1_g1(c1_g1), .c1_b1(c1_b1), .c1_a1(c1_a1),
        .c1_r2(c1_r2), .c1_g2(c1_g2), .c1_b2(c1_b2), .c1_a2(c1_a2),
        .z0(z0), .z1(z1), .z2(z2),
        .st0_s0(st0_s0), .st0_t0(st0_t0), .st0_s1(st0_s1), .st0_t1(st0_t1),
        .st0_s2(st0_s2), .st0_t2(st0_t2),
        .st1_s0(st1_s0), .st1_t0(st1_t0), .st1_s1(st1_s1), .st1_t1(st1_t1),
        .st1_s2(st1_s2), .st1_t2(st1_t2),
        .q0(q0), .q1(q1), .q2(q2),
        .edge1_A(edge1_A), .edge1_B(edge1_B), .edge2_A(edge2_A), .edge2_B(edge2_B),
        .bbox_min_x(bbox_min_x), .bbox_min_y(bbox_min_y),
        .inv_area(inv_area), .area_shift(area_shift), .ccw(ccw),
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
        .init_c0r(init_c0r), .init_c0g(init_c0g), .init_c0b(init_c0b), .init_c0a(init_c0a),
        .init_c1r(init_c1r), .init_c1g(init_c1g), .init_c1b(init_c1b), .init_c1a(init_c1a),
        .init_z(init_z),
        .init_s0(init_s0), .init_t0(init_t0),
        .init_s1(init_s1), .init_t1(init_t1),
        .init_q(init_q)
    );

    // Hex storage: 13 stimulus words per triangle, 42 expected words per triangle
    parameter MAX_TRIS = 16;
    parameter STIM_WORDS_PER_TRI = 13;
    parameter EXP_WORDS_PER_TRI = 42;  // 14 dx + 14 dy + 14 init
    reg [63:0] stim_mem [0:MAX_TRIS*STIM_WORDS_PER_TRI-1];
    reg [31:0] exp_mem  [0:MAX_TRIS*EXP_WORDS_PER_TRI-1];

    integer pass_count = 0;
    integer fail_count = 0;

    // Check helper
    task check32(input string name, input [31:0] actual, input [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: %s expected=0x%08x got=0x%08x", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    integer tri_idx, si, ei;

    initial begin
        $readmemh("../rtl/components/rasterizer/tests/vectors/deriv_stim.hex", stim_mem);
        $readmemh("../rtl/components/rasterizer/tests/vectors/deriv_exp.hex", exp_mem);

        rst_n = 0;
        enable = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Process each triangle
        for (tri_idx = 0; tri_idx < MAX_TRIS; tri_idx = tri_idx + 1) begin
            si = tri_idx * STIM_WORDS_PER_TRI;
            ei = tri_idx * EXP_WORDS_PER_TRI;

            // Check if this triangle exists (first word not X)
            if (stim_mem[si] === 64'hxxxxxxxxxxxxxxxx) begin
                tri_idx = MAX_TRIS; // Break
            end else begin
                // Unpack stimulus
                // Word 0: color0 v0(RGBA) v1(RGBA)
                c0_r0 = stim_mem[si][63:56]; c0_g0 = stim_mem[si][55:48];
                c0_b0 = stim_mem[si][47:40]; c0_a0 = stim_mem[si][39:32];
                c0_r1 = stim_mem[si][31:24]; c0_g1 = stim_mem[si][23:16];
                c0_b1 = stim_mem[si][15:8];  c0_a1 = stim_mem[si][7:0];
                // Word 1: color0 v2(RGBA)
                c0_r2 = stim_mem[si+1][63:56]; c0_g2 = stim_mem[si+1][55:48];
                c0_b2 = stim_mem[si+1][47:40]; c0_a2 = stim_mem[si+1][39:32];
                // Word 2: color1 v0(RGBA) v1(RGBA)
                c1_r0 = stim_mem[si+2][63:56]; c1_g0 = stim_mem[si+2][55:48];
                c1_b0 = stim_mem[si+2][47:40]; c1_a0 = stim_mem[si+2][39:32];
                c1_r1 = stim_mem[si+2][31:24]; c1_g1 = stim_mem[si+2][23:16];
                c1_b1 = stim_mem[si+2][15:8];  c1_a1 = stim_mem[si+2][7:0];
                // Word 3: color1 v2(RGBA)
                c1_r2 = stim_mem[si+3][63:56]; c1_g2 = stim_mem[si+3][55:48];
                c1_b2 = stim_mem[si+3][47:40]; c1_a2 = stim_mem[si+3][39:32];
                // Word 4: Z values
                z0 = stim_mem[si+4][47:32]; z1 = stim_mem[si+4][31:16]; z2 = stim_mem[si+4][15:0];
                // Word 5-6: ST0
                st0_s0 = stim_mem[si+5][63:48]; st0_t0 = stim_mem[si+5][47:32];
                st0_s1 = stim_mem[si+5][31:16]; st0_t1 = stim_mem[si+5][15:0];
                st0_s2 = stim_mem[si+6][63:48]; st0_t2 = stim_mem[si+6][47:32];
                // Word 7-8: ST1
                st1_s0 = stim_mem[si+7][63:48]; st1_t0 = stim_mem[si+7][47:32];
                st1_s1 = stim_mem[si+7][31:16]; st1_t1 = stim_mem[si+7][15:0];
                st1_s2 = stim_mem[si+8][63:48]; st1_t2 = stim_mem[si+8][47:32];
                // Word 9: Q values
                q0 = stim_mem[si+9][47:32]; q1 = stim_mem[si+9][31:16]; q2 = stim_mem[si+9][15:0];
                // Word 10: edge coefficients
                edge1_A = stim_mem[si+10][58:48]; edge1_B = stim_mem[si+10][47:37];
                edge2_A = stim_mem[si+10][36:26]; edge2_B = stim_mem[si+10][25:15];
                // Word 11: scaling parameters
                inv_area   = stim_mem[si+11][49:32];
                area_shift = stim_mem[si+11][28:24];
                ccw        = stim_mem[si+11][23];
                x0         = stim_mem[si+11][22:13];
                y0         = stim_mem[si+11][12:3];
                // Word 12: bbox
                bbox_min_x = stim_mem[si+12][25:16];
                bbox_min_y = stim_mem[si+12][9:0];

                // Pulse enable
                @(posedge clk);
                enable = 1;
                @(posedge clk);
                enable = 0;

                // Wait for deriv_done
                while (!deriv_done) @(posedge clk);
                @(posedge clk); // One more cycle for init values to latch

                $display("Triangle %0d: checking derivatives...", tri_idx);

                // Compare dx derivatives (14 values)
                check32("c0r_dx", pre_c0r_dx, exp_mem[ei+ 0]);
                check32("c0g_dx", pre_c0g_dx, exp_mem[ei+ 1]);
                check32("c0b_dx", pre_c0b_dx, exp_mem[ei+ 2]);
                check32("c0a_dx", pre_c0a_dx, exp_mem[ei+ 3]);
                check32("c1r_dx", pre_c1r_dx, exp_mem[ei+ 4]);
                check32("c1g_dx", pre_c1g_dx, exp_mem[ei+ 5]);
                check32("c1b_dx", pre_c1b_dx, exp_mem[ei+ 6]);
                check32("c1a_dx", pre_c1a_dx, exp_mem[ei+ 7]);
                check32("z_dx",   pre_z_dx,   exp_mem[ei+ 8]);
                check32("s0_dx",  pre_s0_dx,  exp_mem[ei+ 9]);
                check32("t0_dx",  pre_t0_dx,  exp_mem[ei+10]);
                check32("q_dx",   pre_q_dx,   exp_mem[ei+11]);
                check32("s1_dx",  pre_s1_dx,  exp_mem[ei+12]);
                check32("t1_dx",  pre_t1_dx,  exp_mem[ei+13]);

                // Compare dy derivatives (14 values)
                check32("c0r_dy", pre_c0r_dy, exp_mem[ei+14]);
                check32("c0g_dy", pre_c0g_dy, exp_mem[ei+15]);
                check32("c0b_dy", pre_c0b_dy, exp_mem[ei+16]);
                check32("c0a_dy", pre_c0a_dy, exp_mem[ei+17]);
                check32("c1r_dy", pre_c1r_dy, exp_mem[ei+18]);
                check32("c1g_dy", pre_c1g_dy, exp_mem[ei+19]);
                check32("c1b_dy", pre_c1b_dy, exp_mem[ei+20]);
                check32("c1a_dy", pre_c1a_dy, exp_mem[ei+21]);
                check32("z_dy",   pre_z_dy,   exp_mem[ei+22]);
                check32("s0_dy",  pre_s0_dy,  exp_mem[ei+23]);
                check32("t0_dy",  pre_t0_dy,  exp_mem[ei+24]);
                check32("q_dy",   pre_q_dy,   exp_mem[ei+25]);
                check32("s1_dy",  pre_s1_dy,  exp_mem[ei+26]);
                check32("t1_dy",  pre_t1_dy,  exp_mem[ei+27]);

                // Compare init values (14 values)
                check32("init_c0r", init_c0r, exp_mem[ei+28]);
                check32("init_c0g", init_c0g, exp_mem[ei+29]);
                check32("init_c0b", init_c0b, exp_mem[ei+30]);
                check32("init_c0a", init_c0a, exp_mem[ei+31]);
                check32("init_c1r", init_c1r, exp_mem[ei+32]);
                check32("init_c1g", init_c1g, exp_mem[ei+33]);
                check32("init_c1b", init_c1b, exp_mem[ei+34]);
                check32("init_c1a", init_c1a, exp_mem[ei+35]);
                check32("init_z",   init_z,   exp_mem[ei+36]);
                check32("init_s0",  init_s0,  exp_mem[ei+37]);
                check32("init_t0",  init_t0,  exp_mem[ei+38]);
                check32("init_q",   init_q,   exp_mem[ei+39]);
                check32("init_s1",  init_s1,  exp_mem[ei+40]);
                check32("init_t1",  init_t1,  exp_mem[ei+41]);
            end
        end

        $display("");
        $display("tb_deriv_dt: PASS=%0d FAIL=%0d", pass_count, fail_count);
        if (fail_count > 0) begin
            $display("FAIL: %0d mismatches detected", fail_count);
            $fatal(1, "Test failed");
        end else begin
            $display("PASS: All derivatives match digital twin");
        end
        $finish;
    end

endmodule
