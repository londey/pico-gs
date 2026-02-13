// Testbench for early_z module
// Tests depth range clipping and Z-buffer compare functions

`timescale 1ns/1ps

module tb_early_z;

    // DUT signals
    reg  [15:0] fragment_z;
    reg  [15:0] zbuffer_z;
    reg  [15:0] z_range_min;
    reg  [15:0] z_range_max;
    reg         z_test_en;
    reg  [2:0]  z_compare;

    wire        range_pass;
    wire        z_test_pass;
    wire        z_bypass;

    // Compare function encoding
    localparam [2:0] CMP_LESS     = 3'b000;
    localparam [2:0] CMP_LEQUAL   = 3'b001;
    localparam [2:0] CMP_EQUAL    = 3'b010;
    localparam [2:0] CMP_GEQUAL   = 3'b011;
    localparam [2:0] CMP_GREATER  = 3'b100;
    localparam [2:0] CMP_NOTEQUAL = 3'b101;
    localparam [2:0] CMP_ALWAYS   = 3'b110;
    localparam [2:0] CMP_NEVER    = 3'b111;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    early_z dut (
        .fragment_z(fragment_z),
        .zbuffer_z(zbuffer_z),
        .z_range_min(z_range_min),
        .z_range_max(z_range_max),
        .z_test_en(z_test_en),
        .z_compare(z_compare),
        .range_pass(range_pass),
        .z_test_pass(z_test_pass),
        .z_bypass(z_bypass)
    );

    // Check helper
    /* verilator lint_off UNUSEDSIGNAL */
    task check(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    initial begin
        $dumpfile("early_z.vcd");
        $dumpvars(0, tb_early_z);

        // Defaults
        fragment_z = 16'h0000;
        zbuffer_z = 16'hFFFF;
        z_range_min = 16'h0000;
        z_range_max = 16'hFFFF;
        z_test_en = 1'b0;
        z_compare = CMP_LESS;

        $display("=== Testing early_z Module ===\n");

        // ============================================================
        // Depth Range Tests
        // ============================================================
        $display("--- Depth Range Tests ---");

        // Set a restricted range [0x0100, 0xFF00]
        z_range_min = 16'h0100;
        z_range_max = 16'hFF00;

        // Below min
        fragment_z = 16'h0050;
        #1;
        check("range: Z=0x0050 below min 0x0100", range_pass, 1'b0);

        // At min boundary (inclusive)
        fragment_z = 16'h0100;
        #1;
        check("range: Z=0x0100 at min (inclusive)", range_pass, 1'b1);

        // Within range
        fragment_z = 16'h5000;
        #1;
        check("range: Z=0x5000 within range", range_pass, 1'b1);

        // At max boundary (inclusive)
        fragment_z = 16'hFF00;
        #1;
        check("range: Z=0xFF00 at max (inclusive)", range_pass, 1'b1);

        // Above max
        fragment_z = 16'hFF01;
        #1;
        check("range: Z=0xFF01 above max 0xFF00", range_pass, 1'b0);

        // Full range (disabled) — all pass
        z_range_min = 16'h0000;
        z_range_max = 16'hFFFF;

        fragment_z = 16'h0000;
        #1;
        check("range: disabled, Z=0x0000", range_pass, 1'b1);

        fragment_z = 16'hFFFF;
        #1;
        check("range: disabled, Z=0xFFFF", range_pass, 1'b1);

        fragment_z = 16'h8000;
        #1;
        check("range: disabled, Z=0x8000", range_pass, 1'b1);

        // ============================================================
        // Z-Test Bypass Tests
        // ============================================================
        $display("--- Z-Test Bypass Tests ---");

        // z_test_en=0 → bypass
        z_test_en = 1'b0;
        z_compare = CMP_LESS;
        #1;
        check("bypass: z_test_en=0", z_bypass, 1'b1);
        check("bypass: z_test_en=0, z_test_pass=1", z_test_pass, 1'b1);

        // z_test_en=1, z_compare=ALWAYS → bypass
        z_test_en = 1'b1;
        z_compare = CMP_ALWAYS;
        #1;
        check("bypass: z_compare=ALWAYS", z_bypass, 1'b1);
        check("bypass: z_compare=ALWAYS, z_test_pass=1", z_test_pass, 1'b1);

        // z_test_en=1, z_compare=LESS → not bypass
        z_test_en = 1'b1;
        z_compare = CMP_LESS;
        #1;
        check("no bypass: z_test_en=1, z_compare=LESS", z_bypass, 1'b0);

        // ============================================================
        // Z Compare Function Tests
        // ============================================================
        $display("--- Z Compare Function Tests ---");
        z_test_en = 1'b1;

        // LESS: fragment < zbuffer → pass
        z_compare = CMP_LESS;
        fragment_z = 16'h1000;
        zbuffer_z = 16'h2000;
        #1;
        check("LESS: 0x1000 < 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("LESS: 0x2000 < 0x2000 → fail", z_test_pass, 1'b0);

        fragment_z = 16'h3000;
        zbuffer_z = 16'h2000;
        #1;
        check("LESS: 0x3000 < 0x2000 → fail", z_test_pass, 1'b0);

        // LEQUAL: fragment <= zbuffer → pass
        z_compare = CMP_LEQUAL;
        fragment_z = 16'h1000;
        zbuffer_z = 16'h2000;
        #1;
        check("LEQUAL: 0x1000 <= 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("LEQUAL: 0x2000 <= 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h3000;
        zbuffer_z = 16'h2000;
        #1;
        check("LEQUAL: 0x3000 <= 0x2000 → fail", z_test_pass, 1'b0);

        // EQUAL
        z_compare = CMP_EQUAL;
        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("EQUAL: 0x2000 == 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h1000;
        zbuffer_z = 16'h2000;
        #1;
        check("EQUAL: 0x1000 == 0x2000 → fail", z_test_pass, 1'b0);

        // GEQUAL
        z_compare = CMP_GEQUAL;
        fragment_z = 16'h3000;
        zbuffer_z = 16'h2000;
        #1;
        check("GEQUAL: 0x3000 >= 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("GEQUAL: 0x2000 >= 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h1000;
        zbuffer_z = 16'h2000;
        #1;
        check("GEQUAL: 0x1000 >= 0x2000 → fail", z_test_pass, 1'b0);

        // GREATER
        z_compare = CMP_GREATER;
        fragment_z = 16'h3000;
        zbuffer_z = 16'h2000;
        #1;
        check("GREATER: 0x3000 > 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("GREATER: 0x2000 > 0x2000 → fail", z_test_pass, 1'b0);

        // NOTEQUAL
        z_compare = CMP_NOTEQUAL;
        fragment_z = 16'h1000;
        zbuffer_z = 16'h2000;
        #1;
        check("NOTEQUAL: 0x1000 != 0x2000 → pass", z_test_pass, 1'b1);

        fragment_z = 16'h2000;
        zbuffer_z = 16'h2000;
        #1;
        check("NOTEQUAL: 0x2000 != 0x2000 → fail", z_test_pass, 1'b0);

        // ALWAYS (already tested via bypass, but verify directly)
        z_compare = CMP_ALWAYS;
        fragment_z = 16'hFFFF;
        zbuffer_z = 16'h0000;
        #1;
        check("ALWAYS: any values → pass", z_test_pass, 1'b1);

        // NEVER
        z_compare = CMP_NEVER;
        fragment_z = 16'h0000;
        zbuffer_z = 16'hFFFF;
        #1;
        check("NEVER: any values → fail", z_test_pass, 1'b0);

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
