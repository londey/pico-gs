// Testbench for texture_l2_cache module
// Tests direct-mapped compressed block cache: fill, lookup, eviction, invalidation
// Uses 100 MHz clk_core (10 ns period) matching the unified GPU clock domain
//
// Signal drive convention: all DUT inputs are driven on @(negedge clk) so they
// are stable well before the DUT's posedge-triggered always_ff evaluates them.

`default_nettype none

module tb_texture_l2_cache;

    // ========================================================================
    // Format Constants (INT-010)
    // ========================================================================

    /* verilator lint_off UNUSEDPARAM */
    localparam [3:0] FMT_BC1      = 4'd0;
    localparam [3:0] FMT_BC2      = 4'd1;
    localparam [3:0] FMT_BC3      = 4'd2;
    localparam [3:0] FMT_BC4      = 4'd3;
    localparam [3:0] FMT_RGB565   = 4'd5;
    localparam [3:0] FMT_RGBA8888 = 4'd6;
    localparam [3:0] FMT_R8       = 4'd7;
    /* verilator lint_on UNUSEDPARAM */

    // ========================================================================
    // Test Counters
    // ========================================================================

    integer pass_count = 0;
    integer fail_count = 0;
    integer i;
    /* verilator lint_off UNUSEDSIGNAL */
    integer w;  // Loop variable for fill_block task
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg         clk;
    reg         rst_n;

    // Lookup request
    reg         lookup_req;
    reg  [23:0] base_words;
    reg  [15:0] block_index;
    reg  [3:0]  tex_format;

    // Lookup result
    wire        l2_hit;
    wire        l2_ready;

    // Data outputs (32 × 16-bit)
    wire [15:0] l2_data_0,  l2_data_1,  l2_data_2,  l2_data_3;
    wire [15:0] l2_data_4,  l2_data_5,  l2_data_6,  l2_data_7;
    wire [15:0] l2_data_8,  l2_data_9,  l2_data_10, l2_data_11;
    wire [15:0] l2_data_12, l2_data_13, l2_data_14, l2_data_15;
    wire [15:0] l2_data_16, l2_data_17, l2_data_18, l2_data_19;
    wire [15:0] l2_data_20, l2_data_21, l2_data_22, l2_data_23;
    wire [15:0] l2_data_24, l2_data_25, l2_data_26, l2_data_27;
    wire [15:0] l2_data_28, l2_data_29, l2_data_30, l2_data_31;

    // Fill interface
    reg         fill_valid;
    reg  [15:0] fill_data;
    reg  [4:0]  fill_word_idx;
    reg         fill_done;
    reg  [23:0] fill_base_words;
    reg  [15:0] fill_block_index;
    reg  [3:0]  fill_format;

    // Invalidation
    reg         invalidate;

    // Wire array alias for indexed checking
    wire [15:0] l2_data [0:31];
    assign l2_data[0]  = l2_data_0;  assign l2_data[1]  = l2_data_1;
    assign l2_data[2]  = l2_data_2;  assign l2_data[3]  = l2_data_3;
    assign l2_data[4]  = l2_data_4;  assign l2_data[5]  = l2_data_5;
    assign l2_data[6]  = l2_data_6;  assign l2_data[7]  = l2_data_7;
    assign l2_data[8]  = l2_data_8;  assign l2_data[9]  = l2_data_9;
    assign l2_data[10] = l2_data_10; assign l2_data[11] = l2_data_11;
    assign l2_data[12] = l2_data_12; assign l2_data[13] = l2_data_13;
    assign l2_data[14] = l2_data_14; assign l2_data[15] = l2_data_15;
    assign l2_data[16] = l2_data_16; assign l2_data[17] = l2_data_17;
    assign l2_data[18] = l2_data_18; assign l2_data[19] = l2_data_19;
    assign l2_data[20] = l2_data_20; assign l2_data[21] = l2_data_21;
    assign l2_data[22] = l2_data_22; assign l2_data[23] = l2_data_23;
    assign l2_data[24] = l2_data_24; assign l2_data[25] = l2_data_25;
    assign l2_data[26] = l2_data_26; assign l2_data[27] = l2_data_27;
    assign l2_data[28] = l2_data_28; assign l2_data[29] = l2_data_29;
    assign l2_data[30] = l2_data_30; assign l2_data[31] = l2_data_31;

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    texture_l2_cache dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .lookup_req      (lookup_req),
        .base_words      (base_words),
        .block_index     (block_index),
        .tex_format      (tex_format),
        .l2_hit          (l2_hit),
        .l2_ready        (l2_ready),
        .l2_data_0       (l2_data_0),
        .l2_data_1       (l2_data_1),
        .l2_data_2       (l2_data_2),
        .l2_data_3       (l2_data_3),
        .l2_data_4       (l2_data_4),
        .l2_data_5       (l2_data_5),
        .l2_data_6       (l2_data_6),
        .l2_data_7       (l2_data_7),
        .l2_data_8       (l2_data_8),
        .l2_data_9       (l2_data_9),
        .l2_data_10      (l2_data_10),
        .l2_data_11      (l2_data_11),
        .l2_data_12      (l2_data_12),
        .l2_data_13      (l2_data_13),
        .l2_data_14      (l2_data_14),
        .l2_data_15      (l2_data_15),
        .l2_data_16      (l2_data_16),
        .l2_data_17      (l2_data_17),
        .l2_data_18      (l2_data_18),
        .l2_data_19      (l2_data_19),
        .l2_data_20      (l2_data_20),
        .l2_data_21      (l2_data_21),
        .l2_data_22      (l2_data_22),
        .l2_data_23      (l2_data_23),
        .l2_data_24      (l2_data_24),
        .l2_data_25      (l2_data_25),
        .l2_data_26      (l2_data_26),
        .l2_data_27      (l2_data_27),
        .l2_data_28      (l2_data_28),
        .l2_data_29      (l2_data_29),
        .l2_data_30      (l2_data_30),
        .l2_data_31      (l2_data_31),
        .fill_valid      (fill_valid),
        .fill_data       (fill_data),
        .fill_word_idx   (fill_word_idx),
        .fill_done       (fill_done),
        .fill_base_words (fill_base_words),
        .fill_block_index(fill_block_index),
        .fill_format     (fill_format),
        .invalidate      (invalidate)
    );

    // ========================================================================
    // Clock Generation — 100 MHz clk_core (10 ns period)
    // ========================================================================

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ========================================================================
    // Check Helpers
    // ========================================================================

    /* verilator lint_off UNUSEDSIGNAL */
    task check_bit(input string name, input logic actual, input logic expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0b, got %0b", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %04h, got %04h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Fill Helper — loads a block into L2 via the fill interface
    // ========================================================================
    // Fills num_words u16 words with data_base+0, data_base+1, ...
    // then commits with fill_done.  All signals driven on negedge.

    /* verilator lint_off UNUSEDSIGNAL */
    task fill_block(
        input [23:0] base,
        input [15:0] block_idx,
        input [3:0]  fmt,
        input [5:0]  num_words,
        input [15:0] data_base
    );
        // Setup fill address/format (constant throughout)
        @(negedge clk);
        fill_base_words  = base;
        fill_block_index = block_idx;
        fill_format      = fmt;

        // Stream words into fill buffer on negedge
        for (w = 0; w < num_words; w = w + 1) begin
            @(negedge clk);
            fill_valid    = 1'b1;
            fill_word_idx = w[4:0];
            fill_data     = data_base + w[15:0];
        end

        // Deassert fill_valid
        @(negedge clk);
        fill_valid = 1'b0;

        // Assert fill_done for 1 cycle to commit to banks + tags
        @(negedge clk);
        fill_done = 1'b1;
        @(negedge clk);
        fill_done = 1'b0;

        // Wait for commit (tag/bank writes resolve after next posedge)
        @(posedge clk);
        @(posedge clk);
    endtask

    // ========================================================================
    // Lookup Helper — initiates a lookup and waits for result
    // ========================================================================
    // On return: l2_hit and l2_data[] are valid for sampling (we are at #1
    // after the posedge where the DUT transitions to L2_OUTPUT on hit).
    // Caller should sample immediately, then @(posedge clk) to return to IDLE.

    task do_lookup(
        input [23:0] base,
        input [15:0] block_idx,
        input [3:0]  fmt
    );
        // Drive lookup request on negedge (stable before DUT's posedge)
        @(negedge clk);
        lookup_req  = 1'b1;
        base_words  = base;
        block_index = block_idx;
        tex_format  = fmt;

        // DUT processes on next posedge: tag check, l2_hit <= 1 if match
        @(posedge clk);
        #1;
        // l2_hit and l2_data are now valid (state == L2_OUTPUT if hit)

        // Deassert lookup_req on negedge
        @(negedge clk);
        lookup_req = 1'b0;
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("../build/sim_out/texture_l2_cache.vcd");
        $dumpvars(0, tb_texture_l2_cache);

        // Initialize all inputs
        rst_n           = 0;
        lookup_req      = 0;
        base_words      = 24'b0;
        block_index     = 16'b0;
        tex_format      = 4'b0;
        fill_valid      = 0;
        fill_data       = 16'b0;
        fill_word_idx   = 5'b0;
        fill_done       = 0;
        fill_base_words = 24'b0;
        fill_block_index = 16'b0;
        fill_format     = 4'b0;
        invalidate      = 0;

        // Assert reset for several cycles
        #100;
        rst_n = 1;
        @(posedge clk);

        $display("=== Testing texture_l2_cache Module ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        @(posedge clk); #1;
        check_bit("l2_ready = 1 after reset", l2_ready, 1'b1);
        check_bit("l2_hit = 0 after reset",   l2_hit,   1'b0);

        // ============================================================
        // Test 2: Miss on Empty
        // ============================================================
        $display("--- Test 2: Miss on Empty ---");
        do_lookup(24'h000200, 16'd0, FMT_BC1);
        check_bit("l2_hit = 0 on empty lookup", l2_hit, 1'b0);
        @(posedge clk);

        // ============================================================
        // Test 3: Fill + Hit (BC1, 4 words)
        // ============================================================
        $display("--- Test 3: Fill + Hit (BC1) ---");
        fill_block(24'h000100, 16'd5, FMT_BC1, 6'd4, 16'hA000);
        do_lookup(24'h000100, 16'd5, FMT_BC1);
        check_bit("BC1 l2_hit = 1", l2_hit, 1'b1);
        for (i = 0; i < 4; i = i + 1) begin
            check16($sformatf("BC1 l2_data[%0d]", i),
                    l2_data[i], 16'hA000 + i[15:0]);
        end
        // Unused words should be zero
        for (i = 4; i < 32; i = i + 1) begin
            check16($sformatf("BC1 l2_data[%0d] = 0", i),
                    l2_data[i], 16'h0000);
        end
        @(posedge clk); // Wait for L2_OUTPUT -> L2_IDLE

        // ============================================================
        // Test 4: Fill + Hit (BC3, 8 words)
        // ============================================================
        $display("--- Test 4: Fill + Hit (BC3) ---");
        fill_block(24'h000300, 16'd0, FMT_BC3, 6'd8, 16'hB000);
        do_lookup(24'h000300, 16'd0, FMT_BC3);
        check_bit("BC3 l2_hit = 1", l2_hit, 1'b1);
        for (i = 0; i < 8; i = i + 1) begin
            check16($sformatf("BC3 l2_data[%0d]", i),
                    l2_data[i], 16'hB000 + i[15:0]);
        end
        for (i = 8; i < 32; i = i + 1) begin
            check16($sformatf("BC3 l2_data[%0d] = 0", i),
                    l2_data[i], 16'h0000);
        end
        @(posedge clk);

        // ============================================================
        // Test 5: Fill + Hit (RGB565, 16 words)
        // ============================================================
        $display("--- Test 5: Fill + Hit (RGB565) ---");
        fill_block(24'h000400, 16'd0, FMT_RGB565, 6'd16, 16'hC000);
        do_lookup(24'h000400, 16'd0, FMT_RGB565);
        check_bit("RGB565 l2_hit = 1", l2_hit, 1'b1);
        for (i = 0; i < 16; i = i + 1) begin
            check16($sformatf("RGB565 l2_data[%0d]", i),
                    l2_data[i], 16'hC000 + i[15:0]);
        end
        for (i = 16; i < 32; i = i + 1) begin
            check16($sformatf("RGB565 l2_data[%0d] = 0", i),
                    l2_data[i], 16'h0000);
        end
        @(posedge clk);

        // ============================================================
        // Test 6: Fill + Hit (RGBA8888, 32 words)
        // ============================================================
        $display("--- Test 6: Fill + Hit (RGBA8888) ---");
        fill_block(24'h000500, 16'd0, FMT_RGBA8888, 6'd32, 16'hD000);
        do_lookup(24'h000500, 16'd0, FMT_RGBA8888);
        check_bit("RGBA8888 l2_hit = 1", l2_hit, 1'b1);
        for (i = 0; i < 32; i = i + 1) begin
            check16($sformatf("RGBA8888 l2_data[%0d]", i),
                    l2_data[i], 16'hD000 + i[15:0]);
        end
        @(posedge clk);

        // ============================================================
        // Test 7: Eviction (BC1, same-slot collision)
        // ============================================================
        // For BC1: slot = (base[9:0] ^ block_index[9:0]) & 10'h3FF
        // base=0, idx=0: slot = 0 ^ 0 = 0
        // base=0, idx=1024: slot = 0 ^ 0x400 = 0x400 & 0x3FF = 0
        $display("--- Test 7: Eviction ---");

        // Reset for clean state
        rst_n = 0; #100; rst_n = 1; @(posedge clk);

        // Fill block A at slot 0
        fill_block(24'h000000, 16'd0, FMT_BC1, 6'd4, 16'h1111);
        do_lookup(24'h000000, 16'd0, FMT_BC1);
        check_bit("block A l2_hit = 1", l2_hit, 1'b1);
        check16("block A data[0]", l2_data[0], 16'h1111);
        @(posedge clk);

        // Fill block B at same slot (idx=1024 maps to slot 0)
        fill_block(24'h000000, 16'd1024, FMT_BC1, 6'd4, 16'h2222);
        do_lookup(24'h000000, 16'd1024, FMT_BC1);
        check_bit("block B l2_hit = 1", l2_hit, 1'b1);
        check16("block B data[0]", l2_data[0], 16'h2222);
        check16("block B data[3]", l2_data[3], 16'h2225);
        @(posedge clk);

        // Block A should now miss (evicted)
        do_lookup(24'h000000, 16'd0, FMT_BC1);
        check_bit("block A evicted, l2_hit = 0", l2_hit, 1'b0);
        @(posedge clk);

        // ============================================================
        // Test 8: Invalidation
        // ============================================================
        $display("--- Test 8: Invalidation ---");

        // Reset for clean state
        rst_n = 0; #100; rst_n = 1; @(posedge clk);

        // Fill a block and verify hit
        fill_block(24'h000100, 16'd0, FMT_BC1, 6'd4, 16'hAAAA);
        do_lookup(24'h000100, 16'd0, FMT_BC1);
        check_bit("pre-invalidate l2_hit = 1", l2_hit, 1'b1);
        @(posedge clk);

        // Pulse invalidate for 1 cycle (negedge drive)
        @(negedge clk);
        invalidate = 1'b1;
        @(negedge clk);
        invalidate = 1'b0;
        @(posedge clk); // Wait for tag_valid clear
        @(posedge clk);

        // Same block should now miss
        do_lookup(24'h000100, 16'd0, FMT_BC1);
        check_bit("post-invalidate l2_hit = 0", l2_hit, 1'b0);
        @(posedge clk);

        // ============================================================
        // Test 9: Multiple Non-Conflicting Blocks
        // ============================================================
        $display("--- Test 9: Multiple Non-Conflicting Blocks ---");

        // Reset for clean state
        rst_n = 0; #100; rst_n = 1; @(posedge clk);

        // Fill 3 BC1 blocks at different slots
        // base=0, idx=0 -> slot 0
        // base=0, idx=1 -> slot 1
        // base=0, idx=2 -> slot 2
        fill_block(24'h000000, 16'd0, FMT_BC1, 6'd4, 16'h1000);
        fill_block(24'h000000, 16'd1, FMT_BC1, 6'd4, 16'h2000);
        fill_block(24'h000000, 16'd2, FMT_BC1, 6'd4, 16'h3000);

        // Verify each independently
        do_lookup(24'h000000, 16'd0, FMT_BC1);
        check_bit("multi block 0 hit", l2_hit, 1'b1);
        check16("multi block 0 data[0]", l2_data[0], 16'h1000);
        check16("multi block 0 data[3]", l2_data[3], 16'h1003);
        @(posedge clk);

        do_lookup(24'h000000, 16'd1, FMT_BC1);
        check_bit("multi block 1 hit", l2_hit, 1'b1);
        check16("multi block 1 data[0]", l2_data[0], 16'h2000);
        check16("multi block 1 data[3]", l2_data[3], 16'h2003);
        @(posedge clk);

        do_lookup(24'h000000, 16'd2, FMT_BC1);
        check_bit("multi block 2 hit", l2_hit, 1'b1);
        check16("multi block 2 data[0]", l2_data[0], 16'h3000);
        check16("multi block 2 data[3]", l2_data[3], 16'h3003);
        @(posedge clk);

        // ============================================================
        // Test 10: Back-to-Back Lookups
        // ============================================================
        $display("--- Test 10: Back-to-Back Lookups ---");

        // Blocks 0 and 1 are still filled from test 9.
        // Lookup block 0, then immediately block 1 after FSM returns to IDLE.
        do_lookup(24'h000000, 16'd0, FMT_BC1);
        check_bit("b2b first hit", l2_hit, 1'b1);
        check16("b2b first data[0]", l2_data[0], 16'h1000);
        @(posedge clk); // L2_OUTPUT -> L2_IDLE

        do_lookup(24'h000000, 16'd1, FMT_BC1);
        check_bit("b2b second hit", l2_hit, 1'b1);
        check16("b2b second data[0]", l2_data[0], 16'h2000);
        @(posedge clk);

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
        #1000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
