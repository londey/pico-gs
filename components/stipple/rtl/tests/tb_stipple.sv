// Testbench for stipple module
// Tests fragment discard against 8x8 stipple bitmask
//
// The stipple module is a purely combinational test: when stipple is enabled
// and the pattern bit at position {frag_y, frag_x} is 0, the fragment is
// discarded. When the bit is 1, or stipple is disabled, the fragment passes.
//
// See: UNIT-006 (Pixel Pipeline Stage 0a), INT-010 (RENDER_MODE.STIPPLE_EN,
//      STIPPLE_PATTERN register)

`timescale 1ns/1ps

module tb_stipple;

    // DUT signals
    reg  [2:0]  frag_x;
    reg  [2:0]  frag_y;
    reg         stipple_en;
    reg  [63:0] stipple_pattern;

    wire        discard;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;

    // Instantiate DUT
    stipple dut (
        .frag_x         (frag_x),
        .frag_y         (frag_y),
        .stipple_en     (stipple_en),
        .stipple_pattern(stipple_pattern),
        .discard        (discard)
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

    // Loop variables
    integer ix, iy;

    initial begin
        $dumpfile("../build/sim_out/stipple.vcd");
        $dumpvars(0, tb_stipple);

        // Defaults
        frag_x = 3'd0;
        frag_y = 3'd0;
        stipple_en = 1'b0;
        stipple_pattern = 64'h0;

        $display("=== Testing stipple Module ===\n");

        // ============================================================
        // Test 1: Stipple disabled — never discard
        // ============================================================
        $display("--- Stipple Disabled ---");

        stipple_en = 1'b0;

        // All-zeros pattern with stipple disabled: should pass
        stipple_pattern = 64'h0;
        frag_x = 3'd0;
        frag_y = 3'd0;
        #1;
        check("disabled, pattern=0, (0,0)", discard, 1'b0);

        frag_x = 3'd7;
        frag_y = 3'd7;
        #1;
        check("disabled, pattern=0, (7,7)", discard, 1'b0);

        // All-ones pattern with stipple disabled: should still pass
        stipple_pattern = 64'hFFFFFFFFFFFFFFFF;
        frag_x = 3'd3;
        frag_y = 3'd5;
        #1;
        check("disabled, pattern=all-1s, (3,5)", discard, 1'b0);

        // Arbitrary pattern with stipple disabled
        stipple_pattern = 64'hAA55AA55AA55AA55;
        frag_x = 3'd1;
        frag_y = 3'd2;
        #1;
        check("disabled, pattern=checker, (1,2)", discard, 1'b0);

        // ============================================================
        // Test 2: All-ones pattern — all positions pass
        // ============================================================
        $display("--- All-Ones Pattern ---");

        stipple_en = 1'b1;
        stipple_pattern = 64'hFFFFFFFFFFFFFFFF;

        for (iy = 0; iy < 8; iy = iy + 1) begin
            for (ix = 0; ix < 8; ix = ix + 1) begin
                frag_x = ix[2:0];
                frag_y = iy[2:0];
                #1;
                check($sformatf("all-1s: (%0d,%0d)", ix, iy), discard, 1'b0);
            end
        end

        // ============================================================
        // Test 3: All-zeros pattern — all positions discard
        // ============================================================
        $display("--- All-Zeros Pattern ---");

        stipple_pattern = 64'h0;

        for (iy = 0; iy < 8; iy = iy + 1) begin
            for (ix = 0; ix < 8; ix = ix + 1) begin
                frag_x = ix[2:0];
                frag_y = iy[2:0];
                #1;
                check($sformatf("all-0s: (%0d,%0d)", ix, iy), discard, 1'b1);
            end
        end

        // ============================================================
        // Test 4: Single-bit test — only the set position passes
        // ============================================================
        $display("--- Single-Bit Pattern ---");

        // Set bit at position (3, 2): bit_index = 2*8 + 3 = 19
        stipple_pattern = 64'h1 << 19;

        // The set position should pass (discard=0)
        frag_x = 3'd3;
        frag_y = 3'd2;
        #1;
        check("single-bit: (3,2) set bit passes", discard, 1'b0);

        // Adjacent positions should discard
        frag_x = 3'd2;
        frag_y = 3'd2;
        #1;
        check("single-bit: (2,2) unset bit discards", discard, 1'b1);

        frag_x = 3'd4;
        frag_y = 3'd2;
        #1;
        check("single-bit: (4,2) unset bit discards", discard, 1'b1);

        frag_x = 3'd3;
        frag_y = 3'd1;
        #1;
        check("single-bit: (3,1) unset bit discards", discard, 1'b1);

        frag_x = 3'd3;
        frag_y = 3'd3;
        #1;
        check("single-bit: (3,3) unset bit discards", discard, 1'b1);

        // Origin should discard
        frag_x = 3'd0;
        frag_y = 3'd0;
        #1;
        check("single-bit: (0,0) unset bit discards", discard, 1'b1);

        // ============================================================
        // Test 5: Checkerboard pattern — alternating results
        // ============================================================
        $display("--- Checkerboard Pattern ---");

        // Pattern 0xAA55AA55AA55AA55:
        // Row 0 (bits  0- 7): 0x55 = 0101_0101 → x=0 pass, x=1 fail, x=2 pass, ...
        // Row 1 (bits  8-15): 0xAA = 1010_1010 → x=0 fail, x=1 pass, x=2 fail, ...
        // Row 2 (bits 16-23): 0x55 → same as row 0
        // Row 3 (bits 24-31): 0xAA → same as row 1
        // (repeats for rows 4-7)
        stipple_pattern = 64'hAA55AA55AA55AA55;

        for (iy = 0; iy < 8; iy = iy + 1) begin
            for (ix = 0; ix < 8; ix = ix + 1) begin
                frag_x = ix[2:0];
                frag_y = iy[2:0];
                #1;
                // Bit index = iy*8 + ix. The pattern alternates:
                // even rows have 0x55 (even x passes), odd rows have 0xAA (odd x passes)
                if ((ix[0] ^ iy[0]) == 1'b0) begin
                    check($sformatf("checker: (%0d,%0d) pass", ix, iy), discard, 1'b0);
                end else begin
                    check($sformatf("checker: (%0d,%0d) discard", ix, iy), discard, 1'b1);
                end
            end
        end

        // ============================================================
        // Test 6: Corner positions with known patterns
        // ============================================================
        $display("--- Corner Positions ---");

        // Pattern with only corners set: bits 0, 7, 56, 63
        // bit 0  = (0,0): index 0
        // bit 7  = (7,0): index 7
        // bit 56 = (0,7): index 56
        // bit 63 = (7,7): index 63
        stipple_pattern = (64'h1 << 0) | (64'h1 << 7) | (64'h1 << 56) | (64'h1 << 63);

        frag_x = 3'd0;
        frag_y = 3'd0;
        #1;
        check("corners: (0,0) pass", discard, 1'b0);

        frag_x = 3'd7;
        frag_y = 3'd0;
        #1;
        check("corners: (7,0) pass", discard, 1'b0);

        frag_x = 3'd0;
        frag_y = 3'd7;
        #1;
        check("corners: (0,7) pass", discard, 1'b0);

        frag_x = 3'd7;
        frag_y = 3'd7;
        #1;
        check("corners: (7,7) pass", discard, 1'b0);

        // Center should discard
        frag_x = 3'd4;
        frag_y = 3'd4;
        #1;
        check("corners: (4,4) discard", discard, 1'b1);

        // Edge midpoints should discard
        frag_x = 3'd3;
        frag_y = 3'd0;
        #1;
        check("corners: (3,0) discard", discard, 1'b1);

        frag_x = 3'd0;
        frag_y = 3'd3;
        #1;
        check("corners: (0,3) discard", discard, 1'b1);

        // ============================================================
        // Test 7: Exhaustive bit-index verification
        // ============================================================
        $display("--- Exhaustive Bit-Index Verification ---");

        // Walk a single bit through all 64 positions
        for (iy = 0; iy < 8; iy = iy + 1) begin
            for (ix = 0; ix < 8; ix = ix + 1) begin
                // Set exactly one bit at the expected index
                stipple_pattern = 64'h1 << (iy * 8 + ix);
                frag_x = ix[2:0];
                frag_y = iy[2:0];
                #1;
                check($sformatf("walk-1: (%0d,%0d) matching bit passes", ix, iy),
                      discard, 1'b0);

                // Check that a different position discards with this pattern
                frag_x = 3'(((ix + 1) % 8));
                frag_y = iy[2:0];
                #1;
                // This position should discard (different bit set), unless
                // the shifted position happens to wrap to the same bit (impossible
                // since we only shifted x by 1 within 0..7)
                check($sformatf("walk-1: (%0d,%0d) non-matching bit discards",
                      (ix + 1) % 8, iy), discard, 1'b1);
            end
        end

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
