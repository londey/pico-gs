// Testbench for raster_attr_accum module
// Tests derivative latching, accumulator stepping, and output promotion/clamping
// Verification: UNIT-005.02 (Derivative Pre-computation), UNIT-005.03 (Attribute Accumulation)

`timescale 1ns/1ps

module tb_raster_attr_accum;

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

    reg latch_derivs;  // Latch derivatives and init accumulators
    reg step_x;        // Step right
    reg step_y;        // New row

    // ========================================================================
    // Derivative Inputs (from raster_deriv, only c0r/z/uv0u/q used in tests)
    // ========================================================================

    reg signed [31:0] pre_c0r_dx;   // Color0 R dx
    reg signed [31:0] pre_c0r_dy;   // Color0 R dy
    reg signed [31:0] pre_c0g_dx;   // Color0 G dx
    reg signed [31:0] pre_c0g_dy;   // Color0 G dy
    reg signed [31:0] pre_c0b_dx;   // Color0 B dx
    reg signed [31:0] pre_c0b_dy;   // Color0 B dy
    reg signed [31:0] pre_c0a_dx;   // Color0 A dx
    reg signed [31:0] pre_c0a_dy;   // Color0 A dy
    reg signed [31:0] pre_c1r_dx;   // Color1 R dx
    reg signed [31:0] pre_c1r_dy;   // Color1 R dy
    reg signed [31:0] pre_c1g_dx;   // Color1 G dx
    reg signed [31:0] pre_c1g_dy;   // Color1 G dy
    reg signed [31:0] pre_c1b_dx;   // Color1 B dx
    reg signed [31:0] pre_c1b_dy;   // Color1 B dy
    reg signed [31:0] pre_c1a_dx;   // Color1 A dx
    reg signed [31:0] pre_c1a_dy;   // Color1 A dy
    reg signed [31:0] pre_z_dx;     // Z dx
    reg signed [31:0] pre_z_dy;     // Z dy
    reg signed [31:0] pre_uv0u_dx;  // UV0 U dx
    reg signed [31:0] pre_uv0u_dy;  // UV0 U dy
    reg signed [31:0] pre_uv0v_dx;  // UV0 V dx
    reg signed [31:0] pre_uv0v_dy;  // UV0 V dy
    reg signed [31:0] pre_uv1u_dx;  // UV1 U dx
    reg signed [31:0] pre_uv1u_dy;  // UV1 U dy
    reg signed [31:0] pre_uv1v_dx;  // UV1 V dx
    reg signed [31:0] pre_uv1v_dy;  // UV1 V dy
    reg signed [31:0] pre_q_dx;     // Q dx
    reg signed [31:0] pre_q_dy;     // Q dy

    // ========================================================================
    // Initial Value Inputs (from raster_deriv)
    // ========================================================================

    reg signed [31:0] init_c0r;     // Color0 R initial
    reg signed [31:0] init_c0g;     // Color0 G initial
    reg signed [31:0] init_c0b;     // Color0 B initial
    reg signed [31:0] init_c0a;     // Color0 A initial
    reg signed [31:0] init_c1r;     // Color1 R initial
    reg signed [31:0] init_c1g;     // Color1 G initial
    reg signed [31:0] init_c1b;     // Color1 B initial
    reg signed [31:0] init_c1a;     // Color1 A initial
    reg signed [31:0] init_z;       // Z initial
    reg signed [31:0] init_uv0u;    // UV0 U initial
    reg signed [31:0] init_uv0v;    // UV0 V initial
    reg signed [31:0] init_uv1u;    // UV1 U initial
    reg signed [31:0] init_uv1v;    // UV1 V initial
    reg signed [31:0] init_q;       // Q initial

    // ========================================================================
    // DUT Outputs
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] out_c0r;            // Color0 R promoted (Q4.12)
    wire [15:0] out_c0g;            // Color0 G promoted (Q4.12)
    wire [15:0] out_c0b;            // Color0 B promoted (Q4.12)
    wire [15:0] out_c0a;            // Color0 A promoted (Q4.12)
    wire [15:0] out_c1r;            // Color1 R promoted (Q4.12)
    wire [15:0] out_c1g;            // Color1 G promoted (Q4.12)
    wire [15:0] out_c1b;            // Color1 B promoted (Q4.12)
    wire [15:0] out_c1a;            // Color1 A promoted (Q4.12)
    wire [15:0] out_z;              // Z clamped (16-bit unsigned)
    wire signed [31:0] uv0u_acc_out; // UV0 U raw accumulator
    wire signed [31:0] uv0v_acc_out; // UV0 V raw accumulator
    wire signed [31:0] uv1u_acc_out; // UV1 U raw accumulator
    wire signed [31:0] uv1v_acc_out; // UV1 V raw accumulator
    wire signed [31:0] q_acc_out;   // Q raw accumulator
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    raster_attr_accum dut (
        .clk(clk),
        .rst_n(rst_n),
        .latch_derivs(latch_derivs),
        .step_x(step_x),
        .step_y(step_y),
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
        .init_q(init_q),
        .out_c0r(out_c0r), .out_c0g(out_c0g),
        .out_c0b(out_c0b), .out_c0a(out_c0a),
        .out_c1r(out_c1r), .out_c1g(out_c1g),
        .out_c1b(out_c1b), .out_c1a(out_c1a),
        .out_z(out_z),
        .uv0u_acc_out(uv0u_acc_out), .uv0v_acc_out(uv0v_acc_out),
        .uv1u_acc_out(uv1u_acc_out), .uv1v_acc_out(uv1v_acc_out),
        .q_acc_out(q_acc_out)
    );

    // ========================================================================
    // Test Infrastructure
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;

    /* verilator lint_off UNUSEDSIGNAL */
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

    task check32s(input string name,
                  input signed [31:0] actual,
                  input signed [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected 0x%08h, got 0x%08h",
                     name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Zero all derivative and init inputs
    task zero_all_derivs;
        begin
            pre_c0r_dx = 32'sd0; pre_c0r_dy = 32'sd0;
            pre_c0g_dx = 32'sd0; pre_c0g_dy = 32'sd0;
            pre_c0b_dx = 32'sd0; pre_c0b_dy = 32'sd0;
            pre_c0a_dx = 32'sd0; pre_c0a_dy = 32'sd0;
            pre_c1r_dx = 32'sd0; pre_c1r_dy = 32'sd0;
            pre_c1g_dx = 32'sd0; pre_c1g_dy = 32'sd0;
            pre_c1b_dx = 32'sd0; pre_c1b_dy = 32'sd0;
            pre_c1a_dx = 32'sd0; pre_c1a_dy = 32'sd0;
            pre_z_dx = 32'sd0; pre_z_dy = 32'sd0;
            pre_uv0u_dx = 32'sd0; pre_uv0u_dy = 32'sd0;
            pre_uv0v_dx = 32'sd0; pre_uv0v_dy = 32'sd0;
            pre_uv1u_dx = 32'sd0; pre_uv1u_dy = 32'sd0;
            pre_uv1v_dx = 32'sd0; pre_uv1v_dy = 32'sd0;
            pre_q_dx = 32'sd0; pre_q_dy = 32'sd0;
            init_c0r = 32'sd0; init_c0g = 32'sd0;
            init_c0b = 32'sd0; init_c0a = 32'sd0;
            init_c1r = 32'sd0; init_c1g = 32'sd0;
            init_c1b = 32'sd0; init_c1a = 32'sd0;
            init_z = 32'sd0;
            init_uv0u = 32'sd0; init_uv0v = 32'sd0;
            init_uv1u = 32'sd0; init_uv1v = 32'sd0;
            init_q = 32'sd0;
        end
    endtask

    // Pulse a control signal for one clock cycle
    task pulse_latch;
        begin
            latch_derivs = 1'b1;
            @(posedge clk);
            #1;
            latch_derivs = 1'b0;
        end
    endtask

    task pulse_step_x;
        begin
            step_x = 1'b1;
            @(posedge clk);
            #1;
            step_x = 1'b0;
        end
    endtask

    task pulse_step_y;
        begin
            step_y = 1'b1;
            @(posedge clk);
            #1;
            step_y = 1'b0;
        end
    endtask

    // ========================================================================
    // Test Procedure
    // ========================================================================

    initial begin
        $dumpfile("raster_attr_accum.vcd");
        $dumpvars(0, tb_raster_attr_accum);

        // Initialize controls
        latch_derivs = 1'b0;
        step_x = 1'b0;
        step_y = 1'b0;
        zero_all_derivs;

        // Reset
        rst_n = 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;

        $display("=== Testing raster_attr_accum Module ===\n");

        // ============================================================
        // Test 1: Reset state
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check16("reset: out_c0r", out_c0r, 16'h0000);
        check16("reset: out_c0g", out_c0g, 16'h0000);
        check16("reset: out_z", out_z, 16'h0000);
        check32s("reset: uv0u_acc_out", uv0u_acc_out, 32'sd0);
        check32s("reset: q_acc_out", q_acc_out, 32'sd0);

        // ============================================================
        // Test 2: Latch with known init values — output promotion
        // ============================================================
        // Color 8.16 format: color value at bits [23:16]
        // c0_r = 0x80 (128) → acc = 0x00800000
        // Promoted: {4'b0, 8'h80, 4'h8} = 0x0808
        $display("--- Test 2: Latch and Output Promotion ---");
        zero_all_derivs;
        init_c0r = 32'sh0080_0000;  // c0_r = 128 in 8.16
        init_c0g = 32'sh00FF_0000;  // c0_g = 255 in 8.16
        init_c0b = 32'sh0000_0000;  // c0_b = 0 in 8.16
        init_z   = 32'sh4000_0000;  // Z = 0x4000 in 16.16
        init_uv0u = 32'sh1234_5678; // UV0 U raw
        init_q   = 32'sh0100_0000;  // Q raw
        // Set dx so we can test stepping later
        pre_c0r_dx = 32'sh0010_0000;  // c0_r advances by 16 per pixel
        pre_c0r_dy = 32'sh0020_0000;  // c0_r advances by 32 per row
        pulse_latch;
        // Wait for outputs to settle after clock edge
        @(posedge clk);
        #1;

        // Promotion: 128 → {4'b0, 8'h80, 4'h8} = 0x0808
        check16("latch: out_c0r (128)", out_c0r, 16'h0808);
        // Promotion: 255 → {4'b0, 8'hFF, 4'hF} = 0x0FFF
        check16("latch: out_c0g (255)", out_c0g, 16'h0FFF);
        // Promotion: 0 → 0x0000
        check16("latch: out_c0b (0)", out_c0b, 16'h0000);
        // Z: bits [31:16] = 0x4000
        check16("latch: out_z", out_z, 16'h4000);
        // UV/Q passthrough
        check32s("latch: uv0u_acc_out", uv0u_acc_out, 32'sh1234_5678);
        check32s("latch: q_acc_out", q_acc_out, 32'sh0100_0000);

        // ============================================================
        // Test 3: Step X — add dx to accumulator
        // ============================================================
        // c0r_acc = 0x00800000, dx = 0x00100000 (16 in 8.16)
        // After step_x: acc = 0x00900000 → color = 0x90
        // Promoted: {4'b0, 8'h90, 4'h9} = 0x0909
        $display("--- Test 3: Step X ---");
        pulse_step_x;
        @(posedge clk);
        #1;

        // 128 + 16 = 144 = 0x90 → promoted {4'b0, 8'h90, 4'h9} = 0x0909
        check16("step_x: out_c0r (144)", out_c0r, 16'h0909);

        // ============================================================
        // Test 4: Multiple step_x — verify cumulative addition
        // ============================================================
        // Two more steps: acc = 0x00900000 + 2*0x00100000 = 0x00B00000
        // color = 0xB0 = 176 → promoted {4'b0, 8'hB0, 4'hB} = 0x0B0B
        $display("--- Test 4: Multiple Step X ---");
        pulse_step_x;
        pulse_step_x;
        @(posedge clk);
        #1;

        check16("multi step_x: out_c0r (176)", out_c0r, 16'h0B0B);

        // ============================================================
        // Test 5: Step Y — reload from row + dy, not from current acc
        // ============================================================
        // Row was initialized to same as init: 0x00800000
        // After step_y: row += dy = 0x00800000 + 0x00200000 = 0x00A00000
        // acc reloads from new row = 0x00A00000
        // color = 0xA0 = 160 → promoted {4'b0, 8'hA0, 4'hA} = 0x0A0A
        $display("--- Test 5: Step Y (New Row) ---");
        pulse_step_y;
        @(posedge clk);
        #1;

        // acc was at 0x00B00000 from step_x, but step_y reloads from row+dy
        check16("step_y: out_c0r (160)", out_c0r, 16'h0A0A);

        // ============================================================
        // Test 6: Color clamping — negative
        // ============================================================
        // Re-latch with small positive init, then step with large negative dx
        $display("--- Test 6: Negative Color Clamping ---");
        zero_all_derivs;
        init_c0r = 32'sh0010_0000;     // c0_r = 16 in 8.16
        pre_c0r_dx = -32'sh0020_0000;  // dx = -32 (will go negative)
        pulse_latch;
        @(posedge clk);
        #1;

        // Verify initial: 16 → {4'b0, 8'h10, 4'h1} = 0x0101
        check16("neg clamp: out_c0r before step (16)", out_c0r, 16'h0101);

        // Step: 16 + (-32) = -16 → negative → clamp to 0
        pulse_step_x;
        @(posedge clk);
        #1;
        check16("neg clamp: out_c0r after step (clamped)", out_c0r, 16'h0000);

        // ============================================================
        // Test 7: Color clamping — overflow
        // ============================================================
        // Init at 0xF0 (240), step with dx = 0x20 (32) → 240+32=272 > 255
        $display("--- Test 7: Overflow Color Clamping ---");
        zero_all_derivs;
        init_c0r = 32'sh00F0_0000;    // c0_r = 240 in 8.16
        pre_c0r_dx = 32'sh0020_0000;  // dx = 32
        pulse_latch;
        @(posedge clk);
        #1;

        // Initial: 240 → {4'b0, 8'hF0, 4'hF} = 0x0F0F
        check16("overflow: out_c0r before step (240)", out_c0r, 16'h0F0F);

        // Step: 240+32 = 272 → acc[31:24] = 0x01 ≠ 0 → clamp to 0x0FFF
        pulse_step_x;
        @(posedge clk);
        #1;
        check16("overflow: out_c0r after step (clamped)", out_c0r, 16'h0FFF);

        // ============================================================
        // Test 8: Z clamping — negative
        // ============================================================
        $display("--- Test 8: Z Negative Clamping ---");
        zero_all_derivs;
        init_z = 32'sh0010_0000;      // Z = 0x0010 in 16.16
        pre_z_dx = -32'sh0020_0000;   // dx = -(0x0020 in 16.16)
        pulse_latch;
        @(posedge clk);
        #1;

        check16("Z clamp: out_z before step", out_z, 16'h0010);

        pulse_step_x;
        @(posedge clk);
        #1;
        // 0x0010 - 0x0020 = -0x0010 → negative → clamp to 0
        check16("Z clamp: out_z after step (clamped)", out_z, 16'h0000);

        // ============================================================
        // Test 9: UV/Q raw accumulator passthrough
        // ============================================================
        $display("--- Test 9: UV/Q Accumulator Passthrough ---");
        zero_all_derivs;
        init_uv0u = 32'shAAAA_BBBB;
        init_uv0v = 32'shCCCC_DDDD;
        init_uv1u = 32'sh1111_2222;
        init_uv1v = 32'sh3333_4444;
        init_q    = 32'sh5555_6666;
        pulse_latch;
        @(posedge clk);
        #1;

        check32s("UV/Q: uv0u_acc_out", uv0u_acc_out, 32'shAAAA_BBBB);
        check32s("UV/Q: uv0v_acc_out", uv0v_acc_out, 32'shCCCC_DDDD);
        check32s("UV/Q: uv1u_acc_out", uv1u_acc_out, 32'sh1111_2222);
        check32s("UV/Q: uv1v_acc_out", uv1v_acc_out, 32'sh3333_4444);
        check32s("UV/Q: q_acc_out", q_acc_out, 32'sh5555_6666);

        // ============================================================
        // Test 10: UV stepping
        // ============================================================
        $display("--- Test 10: UV Accumulator Stepping ---");
        zero_all_derivs;
        init_uv0u = 32'sh0100_0000;
        pre_uv0u_dx = 32'sh0010_0000;
        pre_uv0u_dy = 32'sh0020_0000;
        pulse_latch;
        @(posedge clk);
        #1;

        check32s("UV step: initial", uv0u_acc_out, 32'sh0100_0000);

        // Step X: 0x01000000 + 0x00100000 = 0x01100000
        pulse_step_x;
        @(posedge clk);
        #1;
        check32s("UV step: after step_x", uv0u_acc_out, 32'sh0110_0000);

        // Step Y: row was 0x01000000, row += dy = 0x01000000+0x00200000 = 0x01200000
        // acc reloads from new row = 0x01200000
        pulse_step_y;
        @(posedge clk);
        #1;
        check32s("UV step: after step_y", uv0u_acc_out, 32'sh0120_0000);

        // ============================================================
        // Summary
        // ============================================================
        $display("\n=== Raster Attr Accum Test Summary ===");
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
