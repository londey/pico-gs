// Testbench for sync_fifo module
// Tests single-clock FIFO operations: flags, data integrity, boundary conditions
// Uses 100 MHz clk_core (10 ns period) matching the unified GPU clock domain

module tb_sync_fifo;

    // Parameters — smaller DEPTH for faster simulation
    localparam WIDTH = 16;
    localparam DEPTH = 32;
    localparam ADDR_WIDTH = $clog2(DEPTH);

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg                 clk;
    reg                 rst_n;
    reg                 wr_en;
    reg  [WIDTH-1:0]    wr_data;
    wire                wr_full;
    reg                 rd_en;
    wire [WIDTH-1:0]    rd_data;
    wire                rd_empty;
    wire [ADDR_WIDTH:0] rd_count;

    sync_fifo #(
        .WIDTH (WIDTH),
        .DEPTH (DEPTH)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .wr_full  (wr_full),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_empty (rd_empty),
        .rd_count (rd_count)
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

    task check_count(input string name, input logic [ADDR_WIDTH:0] actual,
                     input logic [ADDR_WIDTH:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %0d, got %0d", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask

    task check_data(input string name, input logic [WIDTH-1:0] actual,
                    input logic [WIDTH-1:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %h, got %h", name, expected, actual);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);

        // Initialize signals
        rst_n   = 0;
        wr_en   = 0;
        rd_en   = 0;
        wr_data = '0;

        // Assert reset for several cycles
        #100;
        rst_n = 1;
        @(posedge clk);

        $display("=== Testing sync_fifo Module ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        @(posedge clk); #1;
        check_bit("rd_empty = 1 after reset", rd_empty, 1'b1);
        check_bit("wr_full = 0 after reset", wr_full, 1'b0);
        check_count("rd_count = 0 after reset", rd_count, 6'd0);

        // ============================================================
        // Test 2: Single Write/Read
        // ============================================================
        $display("--- Test 2: Single Write/Read ---");

        // Write one entry
        @(posedge clk);
        wr_en  = 1'b1;
        wr_data = 16'hCAFE;
        @(posedge clk);
        wr_en  = 1'b0;

        // Flags update combinationally (same cycle as pointer update)
        #1;
        check_bit("rd_empty = 0 after write", rd_empty, 1'b0);
        check_count("rd_count = 1 after write", rd_count, 6'd1);

        // Read one entry (rd_data is registered, appears one cycle after rd_en)
        @(posedge clk);
        rd_en = 1'b1;
        @(posedge clk);
        rd_en = 1'b0;
        #1;
        check_data("rd_data matches written value", rd_data, 16'hCAFE);
        check_bit("rd_empty = 1 after read", rd_empty, 1'b1);
        check_count("rd_count = 0 after read", rd_count, 6'd0);

        // ============================================================
        // Test 3: Fill to DEPTH (Full Flag)
        // ============================================================
        $display("--- Test 3: Fill to DEPTH (Full Flag) ---");

        // Reset for clean state
        rst_n = 0;
        #100;
        rst_n = 1;
        @(posedge clk);

        // Write DEPTH entries
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            wr_data = i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        #1;

        check_bit("wr_full = 1 after filling", wr_full, 1'b1);
        check_bit("rd_empty = 0 when full", rd_empty, 1'b0);
        check_count("rd_count = DEPTH when full", rd_count, DEPTH[ADDR_WIDTH:0]);

        // ============================================================
        // Test 4: Read All / Empty Flag / Data Ordering
        // ============================================================
        $display("--- Test 4: Read All (Empty Flag, FIFO Order) ---");

        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            rd_en = 1'b1;
            @(posedge clk);
            rd_en = 1'b0;
            #1;
            check_data($sformatf("FIFO order entry %0d", i),
                       rd_data, i[WIDTH-1:0]);
        end

        #1;
        check_bit("rd_empty = 1 after reading all", rd_empty, 1'b1);
        check_count("rd_count = 0 after reading all", rd_count, 6'd0);
        check_bit("wr_full = 0 after reading all", wr_full, 1'b0);

        // ============================================================
        // Test 5: Simultaneous Read/Write (Back-to-Back)
        // ============================================================
        $display("--- Test 5: Simultaneous Read/Write ---");

        // Reset for clean state
        rst_n = 0;
        #100;
        rst_n = 1;
        @(posedge clk);

        // Pre-fill with 10 entries
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            wr_data = 16'hA000 + i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        #1;
        check_count("rd_count = 10 after pre-fill", rd_count, 6'd10);

        // Simultaneous read and write for 10 cycles
        // Count should stay at 10 throughout
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            rd_en   = 1'b1;
            wr_data = 16'hB000 + i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        rd_en = 1'b0;
        #1;
        check_count("rd_count stable at 10 after simultaneous r/w", rd_count, 6'd10);

        // Drain and verify: first read gets entry from simultaneous phase,
        // then the new writes follow
        // The first read during simultaneous phase already consumed the first pre-fill entry.
        // After 10 simultaneous cycles, we consumed 10 pre-fill entries and wrote 10 new ones.
        // But we also got 10 rd_data outputs during the simultaneous phase.
        // Let's verify the remaining 10 entries are the B-series writes.
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            rd_en = 1'b1;
            @(posedge clk);
            rd_en = 1'b0;
            #1;
            check_data($sformatf("simultaneous drain %0d", i),
                       rd_data, 16'hB000 + i[WIDTH-1:0]);
        end
        #1;
        check_bit("rd_empty after simultaneous drain", rd_empty, 1'b1);

        // ============================================================
        // Test 6: Overflow Protection (Write When Full)
        // ============================================================
        $display("--- Test 6: Overflow Protection ---");

        // Reset for clean state
        rst_n = 0;
        #100;
        rst_n = 1;
        @(posedge clk);

        // Fill FIFO to capacity
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            wr_data = 16'hD000 + i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        #1;
        check_bit("wr_full before overflow attempt", wr_full, 1'b1);

        // Attempt to write one more entry (should be suppressed)
        @(posedge clk);
        wr_en   = 1'b1;
        wr_data = 16'hFFFF;
        @(posedge clk);
        wr_en   = 1'b0;
        #1;
        check_bit("wr_full still set after overflow attempt", wr_full, 1'b1);
        check_count("rd_count unchanged after overflow attempt", rd_count, DEPTH[ADDR_WIDTH:0]);

        // Read all entries and verify original data (overflow write discarded)
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            rd_en = 1'b1;
            @(posedge clk);
            rd_en = 1'b0;
            #1;
            check_data($sformatf("overflow prot entry %0d", i),
                       rd_data, 16'hD000 + i[WIDTH-1:0]);
        end

        // ============================================================
        // Test 7: Underflow Protection (Read When Empty)
        // ============================================================
        $display("--- Test 7: Underflow Protection ---");

        // FIFO should be empty now
        #1;
        check_bit("rd_empty before underflow attempt", rd_empty, 1'b1);

        // Attempt to read when empty (should be suppressed, rd_ptr unchanged)
        @(posedge clk);
        rd_en = 1'b1;
        @(posedge clk);
        rd_en = 1'b0;
        #1;
        check_bit("rd_empty still set after underflow attempt", rd_empty, 1'b1);
        check_count("rd_count still 0 after underflow attempt", rd_count, 6'd0);

        // Write a new entry to confirm FIFO still functional after underflow
        @(posedge clk);
        wr_en   = 1'b1;
        wr_data = 16'h1234;
        @(posedge clk);
        wr_en   = 1'b0;
        #1;
        check_bit("rd_empty = 0 after recovery write", rd_empty, 1'b0);
        check_count("rd_count = 1 after recovery write", rd_count, 6'd1);

        // Read it back
        @(posedge clk);
        rd_en = 1'b1;
        @(posedge clk);
        rd_en = 1'b0;
        #1;
        check_data("recovery read data correct", rd_data, 16'h1234);

        // ============================================================
        // Test 8: Count Accuracy Across Operations
        // ============================================================
        $display("--- Test 8: Count Accuracy ---");

        // Reset for clean state
        rst_n = 0;
        #100;
        rst_n = 1;
        @(posedge clk);
        #1;
        check_count("count = 0 after reset", rd_count, 6'd0);

        // Write 5 entries, check count at each step
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            wr_data = i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        #1;
        check_count("count = 5 after 5 writes", rd_count, 6'd5);

        // Read 3 entries
        for (i = 0; i < 3; i = i + 1) begin
            @(posedge clk);
            rd_en = 1'b1;
            @(posedge clk);
            rd_en = 1'b0;
        end
        #1;
        check_count("count = 2 after reading 3", rd_count, 6'd2);

        // Write 4 more
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            wr_en   = 1'b1;
            wr_data = 16'hE000 + i[WIDTH-1:0];
        end
        @(posedge clk);
        wr_en = 1'b0;
        #1;
        check_count("count = 6 after 4 more writes", rd_count, 6'd6);

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
        #500000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule
