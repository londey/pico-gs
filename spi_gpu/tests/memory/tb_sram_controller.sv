`default_nettype none

// Testbench for sram_controller module
// Tests 10-state FSM: single-word read/write (backward compatibility),
// burst read/write, burst cancel, back-to-back bursts, and reset during burst
// Uses 100 MHz clk_core (10 ns period) matching the unified GPU clock domain

module tb_sram_controller;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ========================================================================
    // DUT Signals
    // ========================================================================

    reg          clk;
    reg          rst_n;

    // Internal memory interface
    reg          req;
    reg          we;
    reg  [23:0]  addr;
    reg  [31:0]  wdata;
    wire [31:0]  rdata;
    wire         ack;
    wire         ready;

    // Burst interface
    reg  [7:0]   burst_len;
    reg  [15:0]  burst_wdata_16;
    reg          burst_cancel;
    wire         burst_data_valid;
    wire         burst_wdata_req;
    wire         burst_done;
    wire [15:0]  rdata_16;

    // External SRAM interface
    wire [23:0]  sram_addr;
    wire [15:0]  sram_data;
    wire         sram_we_n;
    wire         sram_oe_n;
    wire         sram_ce_n;

    // ========================================================================
    // SRAM Model - 64K x 16-bit memory
    // ========================================================================

    reg [15:0] sram_mem [0:65535];

    // Drive sram_data from model during reads (CE=0, OE=0, WE=1)
    wire sram_reading = !sram_ce_n && !sram_oe_n && sram_we_n;
    assign sram_data = sram_reading ? sram_mem[sram_addr[15:0]] : 16'bz;

    // Capture writes to model
    always @(posedge clk) begin
        if (!sram_ce_n && !sram_we_n) begin
            sram_mem[sram_addr[15:0]] <= sram_data;
        end
    end

    // ========================================================================
    // DUT Instantiation
    // ========================================================================

    sram_controller dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .req              (req),
        .we               (we),
        .addr             (addr),
        .wdata            (wdata),
        .rdata            (rdata),
        .ack              (ack),
        .ready            (ready),
        .burst_len        (burst_len),
        .burst_wdata_16   (burst_wdata_16),
        .burst_cancel     (burst_cancel),
        .burst_data_valid (burst_data_valid),
        .burst_wdata_req  (burst_wdata_req),
        .burst_done       (burst_done),
        .rdata_16         (rdata_16),
        .sram_addr        (sram_addr),
        .sram_data        (sram_data),
        .sram_we_n        (sram_we_n),
        .sram_oe_n        (sram_oe_n),
        .sram_ce_n        (sram_ce_n)
    );

    // ========================================================================
    // Clock Generation - 100 MHz (10 ns period)
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
            $display("FAIL: %s — expected %0b, got %0b @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask

    task check_val16(input string name, input logic [15:0] actual, input logic [15:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %04h, got %04h @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask

    task check_val32(input string name, input logic [31:0] actual, input logic [31:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %08h, got %08h @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask

    task check_val24(input string name, input logic [23:0] actual, input logic [23:0] expected);
        if (actual === expected) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: %s — expected %06h, got %06h @ %0t", name, expected, actual, $time);
            fail_count = fail_count + 1;
        end
    endtask
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Helper: wait for ack with timeout
    // ========================================================================

    task wait_ack(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!ack && cyc < max_cycles) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= max_cycles) begin
                $display("FAIL: ack timeout after %0d cycles @ %0t", max_cycles, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ========================================================================
    // Helper: reset and initialize
    // ========================================================================

    task do_reset;
        begin
            rst_n          = 1'b0;
            req            = 1'b0;
            we             = 1'b0;
            addr           = 24'b0;
            wdata          = 32'b0;
            burst_len      = 8'b0;
            burst_wdata_16 = 16'b0;
            burst_cancel   = 1'b0;
            #100;
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    // Storage for burst read captures
    reg [15:0] burst_capture [0:255];
    integer    burst_capture_count;
    integer    cycle_count;

    initial begin
        $dumpfile("sram_controller.vcd");
        $dumpvars(0, tb_sram_controller);

        do_reset();

        $display("=== Testing sram_controller Module ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check_bit("ready = 1 after reset", ready, 1'b1);
        check_bit("ack = 0 after reset", ack, 1'b0);
        check_bit("burst_data_valid = 0 after reset", burst_data_valid, 1'b0);
        check_bit("burst_wdata_req = 0 after reset", burst_wdata_req, 1'b0);
        check_bit("burst_done = 0 after reset", burst_done, 1'b0);
        check_bit("sram_ce_n = 1 after reset", sram_ce_n, 1'b1);
        check_bit("sram_we_n = 1 after reset", sram_we_n, 1'b1);
        check_bit("sram_oe_n = 1 after reset", sram_oe_n, 1'b1);

        // ============================================================
        // Test 2: Single-Word Read (burst_len=0)
        // ============================================================
        $display("--- Test 2: Single-Word Read (burst_len=0) ---");

        // Pre-load SRAM: word at address 0x100 = {0xBEEF, 0xCAFE}
        // Low 16 bits at SRAM addr 0x200, high 16 bits at SRAM addr 0x201
        sram_mem[16'h0200] = 16'hCAFE;
        sram_mem[16'h0201] = 16'hBEEF;

        // Issue single-word read: set inputs, then posedge samples them
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h000100;
        burst_len = 8'd0;
        @(posedge clk); #1;
        req = 1'b0;

        // Count cycles to ack (from after req sampled)
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        check_bit("single read ack", ack, 1'b1);
        check_bit("single read burst_done=0", burst_done, 1'b0);
        check_val32("single read rdata", rdata, 32'hBEEFCAFE);
        $display("  Single-word read: %0d cycles after req (READ_LOW + READ_HIGH + DONE)", cycle_count);

        @(posedge clk); #1;
        check_bit("ready after single read", ready, 1'b1);

        // ============================================================
        // Test 3: Single-Word Write (burst_len=0)
        // ============================================================
        $display("--- Test 3: Single-Word Write (burst_len=0) ---");

        // Issue single-word write to address 0x200
        req       = 1'b1;
        we        = 1'b1;
        addr      = 24'h000200;
        wdata     = 32'hDEAD1234;
        burst_len = 8'd0;
        @(posedge clk); #1;
        req = 1'b0;

        // Wait for ack
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        check_bit("single write ack", ack, 1'b1);
        check_bit("single write burst_done=0", burst_done, 1'b0);
        $display("  Single-word write: %0d cycles after req", cycle_count);

        // Wait for SRAM model to capture last write (DONE deasserts signals)
        @(posedge clk); #1;

        // Verify SRAM contents (addr 0x200 → SRAM addr 0x400/0x401)
        check_val16("single write low word in SRAM", sram_mem[16'h0400], 16'h1234);
        check_val16("single write high word in SRAM", sram_mem[16'h0401], 16'hDEAD);

        // ============================================================
        // Test 4: Burst Read (burst_len=4)
        // ============================================================
        $display("--- Test 4: Burst Read (burst_len=4) ---");

        // Pre-load SRAM at base address 0x1000
        sram_mem[16'h1000] = 16'hAAAA;
        sram_mem[16'h1001] = 16'hBBBB;
        sram_mem[16'h1002] = 16'hCCCC;
        sram_mem[16'h1003] = 16'hDDDD;

        // Issue burst read
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h001000;
        burst_len = 8'd4;
        @(posedge clk); #1;
        req = 1'b0;

        // Capture burst data and count cycles
        burst_capture_count = 0;
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (burst_data_valid) begin
                burst_capture[burst_capture_count] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end
        end

        // Expected: SETUP(1) + 4xNEXT + DONE = 6 total; loop sees 5 after req
        $display("  Burst read (4): %0d cycles after req, %0d data words", cycle_count, burst_capture_count);
        check_bit("burst read ack", ack, 1'b1);
        check_bit("burst read burst_done", burst_done, 1'b1);

        // Verify captured data
        check_val16("burst read word 0", burst_capture[0], 16'hAAAA);
        check_val16("burst read word 1", burst_capture[1], 16'hBBBB);
        check_val16("burst read word 2", burst_capture[2], 16'hCCCC);
        check_val16("burst read word 3", burst_capture[3], 16'hDDDD);

        // Verify burst_data_valid count
        if (burst_capture_count == 4) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: burst_data_valid pulses — expected 4, got %0d", burst_capture_count);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;
        check_bit("ready after burst read", ready, 1'b1);

        // ============================================================
        // Test 5: Burst Read (burst_len=16)
        // ============================================================
        $display("--- Test 5: Burst Read (burst_len=16) ---");

        // Pre-load SRAM at base address 0x2000
        for (i = 0; i < 16; i = i + 1) begin
            sram_mem[16'h2000 + i[15:0]] = 16'hF000 + i[15:0];
        end

        // Issue burst read
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h002000;
        burst_len = 8'd16;
        @(posedge clk); #1;
        req = 1'b0;

        // Capture burst data
        burst_capture_count = 0;
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (burst_data_valid) begin
                burst_capture[burst_capture_count] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end
        end

        $display("  Burst read (16): %0d cycles after req, %0d data words", cycle_count, burst_capture_count);

        // Verify all 16 words
        for (i = 0; i < 16; i = i + 1) begin
            check_val16($sformatf("burst16 word %0d", i),
                        burst_capture[i], 16'hF000 + i[15:0]);
        end

        if (burst_capture_count == 16) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: burst16 data_valid pulses — expected 16, got %0d", burst_capture_count);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 6: Burst Write (burst_len=4)
        // ============================================================
        $display("--- Test 6: Burst Write (burst_len=4) ---");

        // Clear target region
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h3000 + i[15:0]] = 16'h0000;
        end

        // Issue burst write — first word provided with request
        req            = 1'b1;
        we             = 1'b1;
        addr           = 24'h003000;
        burst_len      = 8'd4;
        burst_wdata_16 = 16'h1111;
        @(posedge clk); #1;
        req = 1'b0;

        // Respond to burst_wdata_req with sequential data
        cycle_count = 0;
        i = 1;
        while (!ack) begin
            // Provide next word in response to wdata_req
            if (burst_wdata_req) begin
                i = i + 1;
                burst_wdata_16 = 16'h1111 * i[15:0];
            end
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        $display("  Burst write (4): %0d cycles after req", cycle_count);
        check_bit("burst write ack", ack, 1'b1);
        check_bit("burst write burst_done", burst_done, 1'b1);

        // Wait for last write to settle in SRAM model
        @(posedge clk); #1;

        // Verify SRAM contents
        check_val16("burst write word 0", sram_mem[16'h3000], 16'h1111);
        check_val16("burst write word 1", sram_mem[16'h3001], 16'h2222);
        check_val16("burst write word 2", sram_mem[16'h3002], 16'h3333);
        check_val16("burst write word 3", sram_mem[16'h3003], 16'h4444);

        @(posedge clk); #1;

        // ============================================================
        // Test 7: Burst Cancel Mid-Read
        // ============================================================
        $display("--- Test 7: Burst Cancel Mid-Read ---");

        // Pre-load SRAM at base address 0x4000
        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h4000 + i[15:0]] = 16'hA000 + i[15:0];
        end

        // Issue burst read of 8 words
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h004000;
        burst_len = 8'd8;
        @(posedge clk); #1;
        req = 1'b0;

        // Capture data, cancel after 3 words
        burst_capture_count = 0;
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (burst_data_valid) begin
                burst_capture[burst_capture_count] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end

            // Assert cancel after capturing 3rd word
            if (burst_capture_count == 3) begin
                burst_cancel = 1'b1;
            end
        end
        burst_cancel = 1'b0;

        $display("  Burst cancel: captured %0d words before termination", burst_capture_count);
        check_bit("burst cancel ack", ack, 1'b1);
        check_bit("burst cancel burst_done", burst_done, 1'b1);

        // First 3 words should be correct
        check_val16("cancel word 0", burst_capture[0], 16'hA000);
        check_val16("cancel word 1", burst_capture[1], 16'hA001);
        check_val16("cancel word 2", burst_capture[2], 16'hA002);

        @(posedge clk); #1;
        check_bit("ready after cancel", ready, 1'b1);

        // ============================================================
        // Test 8: Burst Cancel Mid-Write
        // ============================================================
        $display("--- Test 8: Burst Cancel Mid-Write ---");

        // Clear target
        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h5000 + i[15:0]] = 16'h0000;
        end

        // Issue burst write of 8 words
        req            = 1'b1;
        we             = 1'b1;
        addr           = 24'h005000;
        burst_len      = 8'd8;
        burst_wdata_16 = 16'hBB00;
        @(posedge clk); #1;
        req = 1'b0;

        // Provide data, cancel after 3 cycles
        cycle_count = 0;
        i = 1;
        while (!ack) begin
            if (burst_wdata_req) begin
                burst_wdata_16 = 16'hBB00 + i[15:0];
                i = i + 1;
            end

            // Cancel after 3 cycles
            if (cycle_count == 2) begin
                burst_cancel = 1'b1;
            end

            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        burst_cancel = 1'b0;

        $display("  Burst write cancel: %0d cycles, wrote %0d words", cycle_count, i);
        check_bit("burst write cancel ack", ack, 1'b1);
        check_bit("burst write cancel burst_done", burst_done, 1'b1);

        // First word should be written (from SETUP)
        @(posedge clk); #1;
        if (sram_mem[16'h5000] != 16'h0000) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: burst write cancel — word 0 not written");
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 9: Back-to-Back Bursts
        // ============================================================
        $display("--- Test 9: Back-to-Back Bursts ---");

        // Pre-load for first burst read
        sram_mem[16'h6000] = 16'h1100;
        sram_mem[16'h6001] = 16'h1101;

        // Pre-load for second burst read
        sram_mem[16'h7000] = 16'h2200;
        sram_mem[16'h7001] = 16'h2201;

        // First burst read (2 words)
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h006000;
        burst_len = 8'd2;
        @(posedge clk); #1;
        req = 1'b0;

        burst_capture_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            if (burst_data_valid) begin
                burst_capture[burst_capture_count] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end
        end

        check_val16("b2b first burst word 0", burst_capture[0], 16'h1100);
        check_val16("b2b first burst word 1", burst_capture[1], 16'h1101);

        // Wait for DONE→IDLE transition
        @(posedge clk); #1;
        check_bit("ready between b2b bursts", ready, 1'b1);

        // Immediately issue second burst
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h007000;
        burst_len = 8'd2;
        @(posedge clk); #1;
        req = 1'b0;

        burst_capture_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            if (burst_data_valid) begin
                burst_capture[burst_capture_count] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end
        end

        check_val16("b2b second burst word 0", burst_capture[0], 16'h2200);
        check_val16("b2b second burst word 1", burst_capture[1], 16'h2201);

        @(posedge clk); #1;

        // ============================================================
        // Test 10: Reset During Burst
        // ============================================================
        $display("--- Test 10: Reset During Burst ---");

        // Pre-load
        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h8000 + i[15:0]] = 16'hCC00 + i[15:0];
        end

        // Start burst read
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h008000;
        burst_len = 8'd8;
        @(posedge clk); #1;
        req = 1'b0;

        // Wait a few cycles into the burst
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;

        // Assert reset mid-burst
        rst_n = 1'b0;
        #50;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // Verify clean recovery to IDLE
        check_bit("ready after reset during burst", ready, 1'b1);
        check_bit("ack = 0 after reset", ack, 1'b0);
        check_bit("sram_ce_n = 1 after reset", sram_ce_n, 1'b1);
        check_bit("sram_we_n = 1 after reset", sram_we_n, 1'b1);
        check_bit("sram_oe_n = 1 after reset", sram_oe_n, 1'b1);
        check_bit("burst_data_valid = 0 after reset", burst_data_valid, 1'b0);
        check_bit("burst_done = 0 after reset", burst_done, 1'b0);

        // Verify controller is functional after reset
        sram_mem[16'h0300] = 16'h9999;
        sram_mem[16'h0301] = 16'h8888;

        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h000180;
        burst_len = 8'd0;
        @(posedge clk); #1;
        req = 1'b0;

        wait_ack(10);
        #1;
        check_val32("read after reset recovery", rdata, 32'h88889999);

        @(posedge clk); #1;

        // ============================================================
        // Test 11: External SRAM Signal Timing (Burst Read)
        // ============================================================
        $display("--- Test 11: SRAM Signal Timing (Burst Read) ---");

        // Pre-load for read verification
        sram_mem[16'h9000] = 16'hEE00;
        sram_mem[16'h9001] = 16'hEE01;
        sram_mem[16'h9002] = 16'hEE02;

        // Issue burst read of 3 words
        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h009000;
        burst_len = 8'd3;
        @(posedge clk); #1;
        // DUT entered BURST_READ_SETUP at this edge
        req = 1'b0;

        // After SETUP: CE=0, OE=0, WE=1 and addr driven
        @(posedge clk); #1;
        // Now in BURST_READ_NEXT (first data cycle)
        check_bit("BURST_READ data_valid=1 (word 0)", burst_data_valid, 1'b1);
        check_val16("BURST_READ rdata_16 word 0", rdata_16, 16'hEE00);
        check_bit("BURST_READ ce_n=0", sram_ce_n, 1'b0);
        check_bit("BURST_READ oe_n=0", sram_oe_n, 1'b0);
        check_bit("BURST_READ we_n=1", sram_we_n, 1'b1);

        @(posedge clk); #1;
        // Second data word
        check_bit("BURST_READ data_valid=1 (word 1)", burst_data_valid, 1'b1);
        check_val16("BURST_READ rdata_16 word 1", rdata_16, 16'hEE01);

        @(posedge clk); #1;
        // Third data word (last)
        check_bit("BURST_READ data_valid=1 (word 2)", burst_data_valid, 1'b1);
        check_val16("BURST_READ rdata_16 word 2", rdata_16, 16'hEE02);

        @(posedge clk); #1;
        // DONE state: ack and burst_done asserted, data_valid deasserted
        check_bit("DONE ack=1", ack, 1'b1);
        check_bit("DONE burst_done=1", burst_done, 1'b1);
        check_bit("DONE data_valid=0", burst_data_valid, 1'b0);

        @(posedge clk); #1;
        // After DONE→IDLE: all SRAM signals deasserted
        check_bit("post-DONE ce_n=1", sram_ce_n, 1'b1);
        check_bit("post-DONE oe_n=1", sram_oe_n, 1'b1);
        check_bit("post-DONE we_n=1", sram_we_n, 1'b1);

        // ============================================================
        // Test 12: Burst Write Signal Timing
        // ============================================================
        $display("--- Test 12: Burst Write Signal Timing ---");

        // Clear target
        for (i = 0; i < 3; i = i + 1) begin
            sram_mem[16'hA000 + i[15:0]] = 16'h0000;
        end

        // Issue burst write of 3 words
        req            = 1'b1;
        we             = 1'b1;
        addr           = 24'h00A000;
        burst_len      = 8'd3;
        burst_wdata_16 = 16'hDD00;
        @(posedge clk); #1;
        // DUT entered BURST_WRITE_SETUP
        req = 1'b0;

        // After SETUP: CE=0, WE=0, OE=1, first word being written
        @(posedge clk); #1;
        // Now in BURST_WRITE_NEXT (or still SETUP effects settling)
        check_bit("BWRITE ce_n=0", sram_ce_n, 1'b0);
        check_bit("BWRITE we_n=0", sram_we_n, 1'b0);
        check_bit("BWRITE oe_n=1", sram_oe_n, 1'b1);

        // Provide second word in response to wdata_req
        if (burst_wdata_req) begin
            burst_wdata_16 = 16'hDD01;
        end

        @(posedge clk); #1;
        // Provide third word
        if (burst_wdata_req) begin
            burst_wdata_16 = 16'hDD02;
        end

        @(posedge clk); #1;
        // Should be at DONE or last NEXT

        // Wait for ack if not already there
        if (!ack) begin
            @(posedge clk); #1;
        end

        check_bit("write DONE ack=1", ack, 1'b1);
        check_bit("write DONE burst_done=1", burst_done, 1'b1);

        // Wait for last write to settle
        @(posedge clk); #1;

        // Verify SRAM contents
        check_val16("write timing word 0", sram_mem[16'hA000], 16'hDD00);
        check_val16("write timing word 1", sram_mem[16'hA001], 16'hDD01);
        check_val16("write timing word 2", sram_mem[16'hA002], 16'hDD02);

        // ============================================================
        // Test 13: Burst Read with burst_len=1 (edge case)
        // ============================================================
        $display("--- Test 13: Burst Read burst_len=1 ---");

        sram_mem[16'hB000] = 16'hFF42;

        req       = 1'b1;
        we        = 1'b0;
        addr      = 24'h00B000;
        burst_len = 8'd1;
        @(posedge clk); #1;
        req = 1'b0;

        burst_capture_count = 0;
        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (burst_data_valid) begin
                burst_capture[0] = rdata_16;
                burst_capture_count = burst_capture_count + 1;
            end
        end

        $display("  Burst read (1): %0d cycles after req", cycle_count);
        check_val16("burst_len=1 read data", burst_capture[0], 16'hFF42);
        check_bit("burst_len=1 burst_done", burst_done, 1'b1);

        if (burst_capture_count == 1) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: burst_len=1 data_valid count — expected 1, got %0d", burst_capture_count);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 14: Burst Write with burst_len=1 (edge case)
        // ============================================================
        $display("--- Test 14: Burst Write burst_len=1 ---");

        sram_mem[16'hC000] = 16'h0000;

        req            = 1'b1;
        we             = 1'b1;
        addr           = 24'h00C000;
        burst_len      = 8'd1;
        burst_wdata_16 = 16'h77AA;
        @(posedge clk); #1;
        req = 1'b0;

        cycle_count = 0;
        while (!ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        $display("  Burst write (1): %0d cycles after req", cycle_count);
        check_bit("burst_len=1 write ack", ack, 1'b1);
        check_bit("burst_len=1 write burst_done", burst_done, 1'b1);

        // Wait for write to settle
        @(posedge clk); #1;
        check_val16("burst_len=1 write data", sram_mem[16'hC000], 16'h77AA);

        @(posedge clk); #1;

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
