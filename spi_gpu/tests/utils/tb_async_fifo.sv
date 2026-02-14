// Testbench for async_fifo module
// Tests CDC operations, FIFO flags, and boot pre-population pointer initialization
// Uses two independent clocks at unrelated frequencies for CDC coverage

module tb_async_fifo;

    // Parameters
    localparam WIDTH = 72;
    localparam DEPTH = 32;
    localparam ADDR_WIDTH = $clog2(DEPTH);

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ========================================================================
    // Standard FIFO (BOOT_COUNT=0) — Tests 1-6
    // ========================================================================

    reg                 wr_clk, rd_clk;
    reg                 wr_rst_n, rd_rst_n;
    reg                 wr_en, rd_en;
    reg  [WIDTH-1:0]    wr_data;
    wire [WIDTH-1:0]    rd_data;
    wire                wr_full, wr_almost_full, rd_empty;
    wire [ADDR_WIDTH:0] rd_count;

    async_fifo #(
        .WIDTH      (WIDTH),
        .DEPTH      (DEPTH),
        .BOOT_COUNT (0)
    ) dut_std (
        .wr_clk        (wr_clk),
        .wr_rst_n      (wr_rst_n),
        .wr_en         (wr_en),
        .wr_data       (wr_data),
        .wr_full       (wr_full),
        .wr_almost_full(wr_almost_full),
        .rd_clk        (rd_clk),
        .rd_rst_n      (rd_rst_n),
        .rd_en         (rd_en),
        .rd_data       (rd_data),
        .rd_empty      (rd_empty),
        .rd_count      (rd_count)
    );

    // ========================================================================
    // Boot FIFO (BOOT_COUNT=5) — Tests 7-8
    // ========================================================================

    reg                 b_wr_rst_n, b_rd_rst_n;
    reg                 b_wr_en, b_rd_en;
    reg  [WIDTH-1:0]    b_wr_data;
    wire [WIDTH-1:0]    b_rd_data;
    wire                b_wr_full, b_wr_almost_full, b_rd_empty;
    wire [ADDR_WIDTH:0] b_rd_count;

    async_fifo #(
        .WIDTH      (WIDTH),
        .DEPTH      (DEPTH),
        .BOOT_COUNT (5)
    ) dut_boot (
        .wr_clk        (wr_clk),
        .wr_rst_n      (b_wr_rst_n),
        .wr_en         (b_wr_en),
        .wr_data       (b_wr_data),
        .wr_full       (b_wr_full),
        .wr_almost_full(b_wr_almost_full),
        .rd_clk        (rd_clk),
        .rd_rst_n      (b_rd_rst_n),
        .rd_en         (b_rd_en),
        .rd_data       (b_rd_data),
        .rd_empty      (b_rd_empty),
        .rd_count      (b_rd_count)
    );

    // ========================================================================
    // Clock Generation — unrelated frequencies for CDC exercise
    // ========================================================================

    initial begin
        wr_clk = 0;
        forever #5 wr_clk = ~wr_clk;   // 10ns period (100 MHz)
    end

    initial begin
        rd_clk = 0;
        forever #7 rd_clk = ~rd_clk;   // 14ns period (~71 MHz)
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

    task check_count(input string name, input logic [ADDR_WIDTH:0] actual,
                     input logic [ADDR_WIDTH:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0d, got %0d", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check72(input string name, input logic [WIDTH-1:0] actual,
                 input logic [WIDTH-1:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %h, got %h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // Wait for CDC synchronizers to propagate (conservative: 6 cycles each domain)
    task wait_cdc;
        @(posedge rd_clk); @(posedge rd_clk); @(posedge rd_clk);
        @(posedge rd_clk); @(posedge rd_clk); @(posedge rd_clk);
        @(posedge wr_clk); @(posedge wr_clk); @(posedge wr_clk);
        @(posedge wr_clk); @(posedge wr_clk); @(posedge wr_clk);
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        // Initialize all signals
        wr_rst_n = 0;    rd_rst_n = 0;
        wr_en = 0;       rd_en = 0;
        wr_data = '0;
        b_wr_rst_n = 0;  b_rd_rst_n = 0;
        b_wr_en = 0;     b_rd_en = 0;
        b_wr_data = '0;

        // Assert reset for several cycles
        #100;
        wr_rst_n = 1;  rd_rst_n = 1;
        b_wr_rst_n = 1; b_rd_rst_n = 1;

        // Wait for CDC synchronizers to settle after reset
        wait_cdc;

        $display("=== Testing async_fifo Module ===\n");

        // ============================================================
        // Test 1: Reset with BOOT_COUNT=0
        // ============================================================
        $display("--- Test 1: Reset with BOOT_COUNT=0 ---");
        @(posedge rd_clk); #1;
        check_bit("rd_empty = 1 after reset", rd_empty, 1'b1);
        check_count("rd_count = 0 after reset", rd_count, 6'd0);
        @(posedge wr_clk); #1;
        check_bit("wr_full = 0 after reset", wr_full, 1'b0);
        check_bit("wr_almost_full = 0 after reset", wr_almost_full, 1'b0);

        // ============================================================
        // Test 2: Single Write-Then-Read
        // ============================================================
        $display("--- Test 2: Single Write-Then-Read ---");

        // Write one 72-bit entry
        @(posedge wr_clk);
        wr_en = 1'b1;
        wr_data = 72'hAB_CDEF_0123_4567_89AB;
        @(posedge wr_clk);
        wr_en = 1'b0;

        // Wait for CDC propagation to read domain
        wait_cdc;
        @(posedge rd_clk); #1;
        check_bit("rd_empty deasserts after write", rd_empty, 1'b0);
        check_count("rd_count = 1 after write", rd_count, 6'd1);

        // Read the entry
        @(posedge rd_clk);
        rd_en = 1'b1;
        @(posedge rd_clk);
        rd_en = 1'b0;
        #1;
        check72("rd_data matches written value", rd_data, 72'hAB_CDEF_0123_4567_89AB);

        // Wait for CDC and verify empty
        wait_cdc;
        @(posedge rd_clk); #1;
        check_bit("rd_empty reasserts after read", rd_empty, 1'b1);
        check_count("rd_count = 0 after read", rd_count, 6'd0);

        // ============================================================
        // Test 3: Fill to DEPTH (Full and Almost-Full Flags)
        // ============================================================
        $display("--- Test 3: Fill to DEPTH (Full Flag) ---");

        // Reset to clean state
        wr_rst_n = 0; rd_rst_n = 0;
        #100;
        wr_rst_n = 1; rd_rst_n = 1;
        wait_cdc;

        // Write 32 entries sequentially
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge wr_clk);
            wr_en = 1'b1;
            wr_data = {8'hAA, 32'b0, i[31:0]};
            @(posedge wr_clk);
            wr_en = 1'b0;

            // Check almost_full transition at DEPTH-2 threshold
            if (i == 28) begin
                #1;
                check_bit("wr_almost_full = 0 at 29 entries", wr_almost_full, 1'b0);
            end
            if (i == 29) begin
                #1;
                check_bit("wr_almost_full = 1 at 30 entries (DEPTH-2)", wr_almost_full, 1'b1);
            end
        end

        // Verify full after 32 writes
        #1;
        check_bit("wr_full = 1 after 32 writes", wr_full, 1'b1);
        check_bit("wr_almost_full = 1 when full", wr_almost_full, 1'b1);

        // ============================================================
        // Test 4: Empty Flag (read all entries from full state)
        // ============================================================
        $display("--- Test 4: Empty Flag ---");

        // Wait for CDC so read domain sees all entries
        wait_cdc;

        // Read all 32 entries and verify FIFO order preserved
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            rd_en = 1'b0;
            #1;
            check72($sformatf("FIFO order entry %0d", i),
                    rd_data, {8'hAA, 32'b0, i[31:0]});
        end

        // Verify empty after reading all
        wait_cdc;
        @(posedge rd_clk); #1;
        check_bit("rd_empty = 1 after reading all", rd_empty, 1'b1);
        check_count("rd_count = 0 after reading all", rd_count, 6'd0);

        // ============================================================
        // Test 5: Back-to-Back Operations
        // ============================================================
        $display("--- Test 5: Back-to-Back Operations ---");

        // Reset to clean state
        wr_rst_n = 0; rd_rst_n = 0;
        #100;
        wr_rst_n = 1; rd_rst_n = 1;
        wait_cdc;

        // Pre-fill FIFO with 10 entries
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge wr_clk);
            wr_en = 1'b1;
            wr_data = {8'hBB, 32'b0, i[31:0]};
            @(posedge wr_clk);
            wr_en = 1'b0;
        end
        wait_cdc;

        // Interleave: read one entry, write one new entry, repeat 10 times
        for (i = 0; i < 10; i = i + 1) begin
            // Read (should get original pre-filled entry i)
            @(posedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            rd_en = 1'b0;
            #1;
            check72($sformatf("back-to-back read %0d", i),
                    rd_data, {8'hBB, 32'b0, i[31:0]});

            // Write a new entry
            @(posedge wr_clk);
            wr_en = 1'b1;
            wr_data = {8'hCC, 32'b0, i[31:0]};
            @(posedge wr_clk);
            wr_en = 1'b0;

            wait_cdc;
        end

        // Drain the 10 newly written entries
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            rd_en = 1'b0;
            #1;
            check72($sformatf("back-to-back drain %0d", i),
                    rd_data, {8'hCC, 32'b0, i[31:0]});
        end

        // Verify empty
        wait_cdc;
        @(posedge rd_clk); #1;
        check_bit("rd_empty after back-to-back", rd_empty, 1'b1);

        // ============================================================
        // Test 6: Overflow Protection
        // ============================================================
        $display("--- Test 6: Overflow Protection ---");

        // Reset to clean state
        wr_rst_n = 0; rd_rst_n = 0;
        #100;
        wr_rst_n = 1; rd_rst_n = 1;
        wait_cdc;

        // Fill FIFO to capacity with known pattern
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge wr_clk);
            wr_en = 1'b1;
            wr_data = {8'hDD, 32'b0, i[31:0]};
            @(posedge wr_clk);
            wr_en = 1'b0;
        end
        #1;
        check_bit("wr_full before overflow attempt", wr_full, 1'b1);

        // Attempt to write one more entry (should be silently discarded)
        @(posedge wr_clk);
        wr_en = 1'b1;
        wr_data = 72'hFF_FFFF_FFFF_FFFF_FFFF;
        @(posedge wr_clk);
        wr_en = 1'b0;
        #1;
        check_bit("wr_full still set after overflow attempt", wr_full, 1'b1);

        // Read all 32 entries and verify original data (overflow write discarded)
        wait_cdc;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge rd_clk);
            rd_en = 1'b1;
            @(posedge rd_clk);
            rd_en = 1'b0;
            #1;
            check72($sformatf("overflow prot entry %0d", i),
                    rd_data, {8'hDD, 32'b0, i[31:0]});
        end

        // ============================================================
        // Test 7: Reset with BOOT_COUNT=5
        // ============================================================
        $display("--- Test 7: Reset with BOOT_COUNT=5 ---");

        // Reset boot FIFO specifically
        b_wr_rst_n = 0; b_rd_rst_n = 0;
        #100;
        b_wr_rst_n = 1; b_rd_rst_n = 1;
        wait_cdc;

        // After reset, FIFO should show 5 pre-populated entries
        @(posedge rd_clk); #1;
        check_bit("boot: rd_empty = 0 after reset", b_rd_empty, 1'b0);
        check_count("boot: rd_count = 5 after reset", b_rd_count, 6'd5);
        @(posedge wr_clk); #1;
        check_bit("boot: wr_full = 0 after reset", b_wr_full, 1'b0);
        check_bit("boot: wr_almost_full = 0 after reset", b_wr_almost_full, 1'b0);

        // ============================================================
        // Test 8: Write Pointer Initialization
        // ============================================================
        $display("--- Test 8: Write Pointer Initialization ---");

        // Write one new entry (should be stored at mem[5], not mem[0])
        @(posedge wr_clk);
        b_wr_en = 1'b1;
        b_wr_data = 72'h55_AAAA_BBBB_CCCC_DDDD;
        @(posedge wr_clk);
        b_wr_en = 1'b0;

        wait_cdc;
        @(posedge rd_clk); #1;
        check_count("boot: rd_count = 6 after 1 write", b_rd_count, 6'd6);

        // Read and discard 5 boot entries (undefined content, skip data check)
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge rd_clk);
            b_rd_en = 1'b1;
            @(posedge rd_clk);
            b_rd_en = 1'b0;
        end

        // Read entry at position 5 (the one we wrote after boot entries)
        @(posedge rd_clk);
        b_rd_en = 1'b1;
        @(posedge rd_clk);
        b_rd_en = 1'b0;
        #1;
        check72("boot: entry at mem[5] matches written data",
                b_rd_data, 72'h55_AAAA_BBBB_CCCC_DDDD);

        // Verify FIFO is now empty (boot entries consumed + our write consumed)
        wait_cdc;
        @(posedge rd_clk); #1;
        check_bit("boot: rd_empty after consuming all", b_rd_empty, 1'b1);
        check_count("boot: rd_count = 0 after consuming all", b_rd_count, 6'd0);

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
        #100000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule
