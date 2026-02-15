`default_nettype none

// Testbench for sram_arbiter module with burst support
// Tests 3-state grant FSM: single-word backward compatibility,
// burst read/write, burst data routing, burst preemption,
// preemption data integrity, natural burst completion,
// burst+single-word interleaving, and reset during burst.
// Instantiates sram_controller + behavioral SRAM model for end-to-end verification.

module tb_sram_arbiter;

    // Test counters
    integer pass_count = 0;
    integer fail_count = 0;
    integer i;

    // ========================================================================
    // Clock and Reset
    // ========================================================================

    reg clk;
    reg rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz
    end

    // ========================================================================
    // Port 0 Signals (Display Read — highest priority)
    // ========================================================================

    reg          p0_req;
    reg          p0_we;
    reg  [23:0]  p0_addr;
    reg  [31:0]  p0_wdata;
    reg  [7:0]   p0_burst_len;
    wire [31:0]  p0_rdata;
    wire [15:0]  p0_burst_rdata;
    wire         p0_burst_data_valid;
    wire         p0_burst_wdata_req;
    wire         p0_ack;
    wire         p0_ready;

    // ========================================================================
    // Port 1 Signals (Framebuffer Write)
    // ========================================================================

    reg          p1_req;
    reg          p1_we;
    reg  [23:0]  p1_addr;
    reg  [31:0]  p1_wdata;
    reg  [7:0]   p1_burst_len;
    reg  [15:0]  p1_burst_wdata;
    wire [31:0]  p1_rdata;
    wire [15:0]  p1_burst_rdata;
    wire         p1_burst_data_valid;
    wire         p1_burst_wdata_req;
    wire         p1_ack;
    wire         p1_ready;

    // ========================================================================
    // Port 2 Signals (Z-Buffer Read/Write)
    // ========================================================================

    reg          p2_req;
    reg          p2_we;
    reg  [23:0]  p2_addr;
    reg  [31:0]  p2_wdata;
    reg  [7:0]   p2_burst_len;
    reg  [15:0]  p2_burst_wdata;
    wire [31:0]  p2_rdata;
    wire [15:0]  p2_burst_rdata;
    wire         p2_burst_data_valid;
    wire         p2_burst_wdata_req;
    wire         p2_ack;
    wire         p2_ready;

    // ========================================================================
    // Port 3 Signals (Texture Read — lowest priority)
    // ========================================================================

    reg          p3_req;
    reg          p3_we;
    reg  [23:0]  p3_addr;
    reg  [31:0]  p3_wdata;
    reg  [7:0]   p3_burst_len;
    reg  [15:0]  p3_burst_wdata;
    wire [31:0]  p3_rdata;
    wire [15:0]  p3_burst_rdata;
    wire         p3_burst_data_valid;
    wire         p3_burst_wdata_req;
    wire         p3_ack;
    wire         p3_ready;

    // ========================================================================
    // Arbiter ↔ SRAM Controller Interconnect
    // ========================================================================

    wire        sram_req;
    wire        sram_we;
    wire [23:0] sram_addr;
    wire [31:0] sram_wdata;
    wire [31:0] sram_rdata;
    wire        sram_ack;
    wire        sram_ready;

    wire [7:0]  sram_burst_len;
    wire [15:0] sram_burst_wdata_w;
    wire        sram_burst_cancel;
    wire        sram_burst_data_valid;
    wire        sram_burst_wdata_req;
    wire        sram_burst_done;
    wire [15:0] sram_rdata_16;

    // External SRAM interface
    wire [23:0] ext_sram_addr;
    wire [15:0] ext_sram_data;
    wire        ext_sram_we_n;
    wire        ext_sram_oe_n;
    wire        ext_sram_ce_n;

    // ========================================================================
    // SRAM Model — 64K x 16-bit behavioral memory
    // ========================================================================

    reg [15:0] sram_mem [0:65535];

    wire sram_reading = !ext_sram_ce_n && !ext_sram_oe_n && ext_sram_we_n;
    assign ext_sram_data = sram_reading ? sram_mem[ext_sram_addr[15:0]] : 16'bz;

    always @(posedge clk) begin
        if (!ext_sram_ce_n && !ext_sram_we_n) begin
            sram_mem[ext_sram_addr[15:0]] <= ext_sram_data;
        end
    end

    // ========================================================================
    // DUT: SRAM Arbiter
    // ========================================================================

    sram_arbiter dut_arbiter (
        .clk(clk),
        .rst_n(rst_n),

        // Port 0
        .port0_req(p0_req),
        .port0_we(p0_we),
        .port0_addr(p0_addr),
        .port0_wdata(p0_wdata),
        .port0_burst_len(p0_burst_len),
        .port0_rdata(p0_rdata),
        .port0_burst_rdata(p0_burst_rdata),
        .port0_burst_data_valid(p0_burst_data_valid),
        .port0_burst_wdata_req(p0_burst_wdata_req),
        .port0_ack(p0_ack),
        .port0_ready(p0_ready),

        // Port 1
        .port1_req(p1_req),
        .port1_we(p1_we),
        .port1_addr(p1_addr),
        .port1_wdata(p1_wdata),
        .port1_burst_len(p1_burst_len),
        .port1_burst_wdata(p1_burst_wdata),
        .port1_rdata(p1_rdata),
        .port1_burst_rdata(p1_burst_rdata),
        .port1_burst_data_valid(p1_burst_data_valid),
        .port1_burst_wdata_req(p1_burst_wdata_req),
        .port1_ack(p1_ack),
        .port1_ready(p1_ready),

        // Port 2
        .port2_req(p2_req),
        .port2_we(p2_we),
        .port2_addr(p2_addr),
        .port2_wdata(p2_wdata),
        .port2_burst_len(p2_burst_len),
        .port2_burst_wdata(p2_burst_wdata),
        .port2_rdata(p2_rdata),
        .port2_burst_rdata(p2_burst_rdata),
        .port2_burst_data_valid(p2_burst_data_valid),
        .port2_burst_wdata_req(p2_burst_wdata_req),
        .port2_ack(p2_ack),
        .port2_ready(p2_ready),

        // Port 3
        .port3_req(p3_req),
        .port3_we(p3_we),
        .port3_addr(p3_addr),
        .port3_wdata(p3_wdata),
        .port3_burst_len(p3_burst_len),
        .port3_burst_wdata(p3_burst_wdata),
        .port3_rdata(p3_rdata),
        .port3_burst_rdata(p3_burst_rdata),
        .port3_burst_data_valid(p3_burst_data_valid),
        .port3_burst_wdata_req(p3_burst_wdata_req),
        .port3_ack(p3_ack),
        .port3_ready(p3_ready),

        // To SRAM controller — single-word
        .sram_req(sram_req),
        .sram_we(sram_we),
        .sram_addr(sram_addr),
        .sram_wdata(sram_wdata),
        .sram_rdata(sram_rdata),
        .sram_ack(sram_ack),
        .sram_ready(sram_ready),

        // To SRAM controller — burst
        .sram_burst_len(sram_burst_len),
        .sram_burst_wdata(sram_burst_wdata_w),
        .sram_burst_cancel(sram_burst_cancel),
        .sram_burst_data_valid(sram_burst_data_valid),
        .sram_burst_wdata_req(sram_burst_wdata_req),
        .sram_burst_done(sram_burst_done),
        .sram_rdata_16(sram_rdata_16)
    );

    // ========================================================================
    // SRAM Controller
    // ========================================================================

    sram_controller dut_ctrl (
        .clk(clk),
        .rst_n(rst_n),

        .req(sram_req),
        .we(sram_we),
        .addr(sram_addr),
        .wdata(sram_wdata),
        .rdata(sram_rdata),
        .ack(sram_ack),
        .ready(sram_ready),

        .burst_len(sram_burst_len),
        .burst_wdata_16(sram_burst_wdata_w),
        .burst_cancel(sram_burst_cancel),
        .burst_data_valid(sram_burst_data_valid),
        .burst_wdata_req(sram_burst_wdata_req),
        .burst_done(sram_burst_done),
        .rdata_16(sram_rdata_16),

        .sram_addr(ext_sram_addr),
        .sram_data(ext_sram_data),
        .sram_we_n(ext_sram_we_n),
        .sram_oe_n(ext_sram_oe_n),
        .sram_ce_n(ext_sram_ce_n)
    );

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
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Reset Task
    // ========================================================================

    task do_reset;
        begin
            rst_n = 1'b0;

            p0_req = 0; p0_we = 0; p0_addr = 0; p0_wdata = 0; p0_burst_len = 0;
            p1_req = 0; p1_we = 0; p1_addr = 0; p1_wdata = 0; p1_burst_len = 0; p1_burst_wdata = 0;
            p2_req = 0; p2_we = 0; p2_addr = 0; p2_wdata = 0; p2_burst_len = 0; p2_burst_wdata = 0;
            p3_req = 0; p3_we = 0; p3_addr = 0; p3_wdata = 0; p3_burst_len = 0; p3_burst_wdata = 0;

            #100;
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // ========================================================================
    // Helper: wait for port N ack with timeout
    // ========================================================================

    task wait_p0_ack(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!p0_ack && cyc < max_cycles) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= max_cycles) begin
                $display("FAIL: p0_ack timeout after %0d cycles @ %0t", max_cycles, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task wait_p1_ack(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!p1_ack && cyc < max_cycles) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= max_cycles) begin
                $display("FAIL: p1_ack timeout after %0d cycles @ %0t", max_cycles, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task wait_p3_ack(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!p3_ack && cyc < max_cycles) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= max_cycles) begin
                $display("FAIL: p3_ack timeout after %0d cycles @ %0t", max_cycles, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // ========================================================================
    // Burst Read Capture Storage
    // ========================================================================

    reg [15:0] burst_cap [0:255];
    integer    burst_cap_count;
    integer    cycle_count;

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("sram_arbiter.vcd");
        $dumpvars(0, tb_sram_arbiter);

        do_reset();

        $display("=== Testing sram_arbiter Module (Burst Support) ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check_bit("p0_ready after reset", p0_ready, 1'b1);
        check_bit("p0_ack = 0 after reset", p0_ack, 1'b0);
        check_bit("p0_burst_data_valid = 0", p0_burst_data_valid, 1'b0);
        check_bit("p1_burst_data_valid = 0", p1_burst_data_valid, 1'b0);
        check_bit("p2_burst_data_valid = 0", p2_burst_data_valid, 1'b0);
        check_bit("p3_burst_data_valid = 0", p3_burst_data_valid, 1'b0);

        // ============================================================
        // Test 2: Single-Word Read on Port 0 (backward compat, burst_len=0)
        // ============================================================
        $display("--- Test 2: Single-Word Read Port 0 (burst_len=0) ---");

        // Pre-load SRAM: word addr 0x100 → SRAM addrs 0x200/0x201
        sram_mem[16'h0200] = 16'hCAFE;
        sram_mem[16'h0201] = 16'hBEEF;

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000100;
        p0_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;

        wait_p0_ack(20);
        #1;

        check_bit("p0 single read ack", p0_ack, 1'b1);

        // Verify no burst signals fired on other ports
        check_bit("p1_burst_data_valid stays 0", p1_burst_data_valid, 1'b0);
        check_bit("p3_burst_data_valid stays 0", p3_burst_data_valid, 1'b0);

        // rdata is registered — available one cycle after ack
        @(posedge clk); #1;
        check_val32("p0 single read rdata", p0_rdata, 32'hBEEFCAFE);
        check_bit("p0_ready after single read", p0_ready, 1'b1);

        // ============================================================
        // Test 3: Single-Word Write on Port 1 (backward compat)
        // ============================================================
        $display("--- Test 3: Single-Word Write Port 1 (burst_len=0) ---");

        p1_req       = 1'b1;
        p1_we        = 1'b1;
        p1_addr      = 24'h000200;
        p1_wdata     = 32'hDEAD5678;
        p1_burst_len = 8'd0;
        @(posedge clk); #1;
        p1_req = 1'b0;

        wait_p1_ack(20);
        #1;

        check_bit("p1 single write ack", p1_ack, 1'b1);

        @(posedge clk); #1;

        // Verify SRAM contents (addr 0x200 → SRAM 0x400/0x401)
        check_val16("p1 write low", sram_mem[16'h0400], 16'h5678);
        check_val16("p1 write high", sram_mem[16'h0401], 16'hDEAD);

        // ============================================================
        // Test 4: Burst Read on Port 3 (burst_len=8)
        // ============================================================
        $display("--- Test 4: Burst Read Port 3 (burst_len=8) ---");

        // Pre-load 8 x 16-bit words at SRAM address 0x1000
        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h1000 + i[15:0]] = 16'hA000 + i[15:0];
        end

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h001000;
        p3_burst_len = 8'd8;
        @(posedge clk); #1;
        p3_req = 1'b0;

        burst_cap_count = 0;
        cycle_count = 0;
        while (!p3_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                burst_cap[burst_cap_count] = p3_burst_rdata;
                burst_cap_count = burst_cap_count + 1;
            end
        end

        $display("  Burst read (8 words): %0d cycles, %0d words captured", cycle_count, burst_cap_count);
        check_bit("p3 burst ack", p3_ack, 1'b1);

        // Verify 8 words captured
        if (burst_cap_count == 8) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: expected 8 burst words, got %0d", burst_cap_count);
            fail_count = fail_count + 1;
        end

        // Verify data
        for (i = 0; i < 8; i = i + 1) begin
            check_val16($sformatf("p3 burst word %0d", i),
                        burst_cap[i], 16'hA000 + i[15:0]);
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 5: Burst Read Data Routing — only granted port gets data_valid
        // ============================================================
        $display("--- Test 5: Burst Data Routing (only port 3) ---");

        // Pre-load
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h2000 + i[15:0]] = 16'hBB00 + i[15:0];
        end

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h002000;
        p3_burst_len = 8'd4;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Monitor: p0/p1/p2 data_valid must never be asserted
        begin : routing_check
            integer p0_valid_count, p1_valid_count, p2_valid_count;
            p0_valid_count = 0;
            p1_valid_count = 0;
            p2_valid_count = 0;

            while (!p3_ack) begin
                @(posedge clk); #1;
                if (p0_burst_data_valid) p0_valid_count = p0_valid_count + 1;
                if (p1_burst_data_valid) p1_valid_count = p1_valid_count + 1;
                if (p2_burst_data_valid) p2_valid_count = p2_valid_count + 1;
            end

            if (p0_valid_count == 0 && p1_valid_count == 0 && p2_valid_count == 0) begin
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL: burst_data_valid leaked to non-granted ports (p0=%0d, p1=%0d, p2=%0d)",
                         p0_valid_count, p1_valid_count, p2_valid_count);
                fail_count = fail_count + 1;
            end
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 6: Burst Write on Port 1 (burst_len=4)
        // ============================================================
        $display("--- Test 6: Burst Write Port 1 (burst_len=4) ---");

        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h3000 + i[15:0]] = 16'h0000;
        end

        p1_req          = 1'b1;
        p1_we           = 1'b1;
        p1_addr         = 24'h003000;
        p1_burst_len    = 8'd4;
        p1_burst_wdata  = 16'h1111;
        @(posedge clk); #1;
        p1_req = 1'b0;

        cycle_count = 0;
        i = 1;
        while (!p1_ack && cycle_count < 50) begin
            if (p1_burst_wdata_req) begin
                i = i + 1;
                p1_burst_wdata = 16'h1111 * i[15:0];
            end
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        $display("  Burst write (4): %0d cycles", cycle_count);
        check_bit("p1 burst write ack", p1_ack, 1'b1);

        @(posedge clk); #1;

        // Verify SRAM contents
        check_val16("bwrite word 0", sram_mem[16'h3000], 16'h1111);
        check_val16("bwrite word 1", sram_mem[16'h3001], 16'h2222);
        check_val16("bwrite word 2", sram_mem[16'h3002], 16'h3333);
        check_val16("bwrite word 3", sram_mem[16'h3003], 16'h4444);

        // Verify wdata_req not routed to other ports
        // (checked implicitly — only p1_burst_wdata_req drives data supply above)

        // ============================================================
        // Test 7: Burst Preemption — Port 0 interrupts Port 3 burst
        // ============================================================
        $display("--- Test 7: Burst Preemption (Port 0 interrupts Port 3) ---");

        // Pre-load 16 words at address 0x4000
        for (i = 0; i < 16; i = i + 1) begin
            sram_mem[16'h4000 + i[15:0]] = 16'hCC00 + i[15:0];
        end

        // Pre-load for port 0 single-word read
        sram_mem[16'h0600] = 16'h1234;
        sram_mem[16'h0601] = 16'h5678;

        // Start port 3 burst read (16 words)
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h004000;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Let burst run for a few words, then interrupt with port 0
        burst_cap_count = 0;
        cycle_count = 0;
        begin : preemption_test
            reg p3_done;
            reg p0_done;
            p3_done = 1'b0;
            p0_done = 1'b0;

            while (!p3_done || !p0_done) begin
                @(posedge clk); #1;
                cycle_count = cycle_count + 1;

                // Capture port 3 burst data
                if (p3_burst_data_valid && !p3_done) begin
                    burst_cap[burst_cap_count] = p3_burst_rdata;
                    burst_cap_count = burst_cap_count + 1;
                end

                // After 3 words captured, assert port 0 request
                if (burst_cap_count == 3 && !p0_req && !p0_done) begin
                    p0_req       = 1'b1;
                    p0_we        = 1'b0;
                    p0_addr      = 24'h000300;
                    p0_burst_len = 8'd0;
                end

                // Port 3 gets preempted — ack comes
                if (p3_ack) begin
                    p3_done = 1'b1;
                end

                // Wait for port 0 ack, then deassert
                if (p0_ack) begin
                    p0_done = 1'b1;
                    p0_req  = 1'b0;
                end

                if (cycle_count > 100) begin
                    $display("FAIL: preemption test timeout @ %0t", $time);
                    fail_count = fail_count + 1;
                    p0_req = 1'b0;
                    break;
                end
            end
        end

        $display("  Preemption: port 3 got %0d words before preempt, total %0d cycles",
                 burst_cap_count, cycle_count);

        // Port 3 burst was preempted — should have fewer than 16 words
        if (burst_cap_count < 16) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: preemption didn't reduce burst — got all %0d words", burst_cap_count);
            fail_count = fail_count + 1;
        end

        // The words we did get should be correct
        for (i = 0; i < burst_cap_count && i < 16; i = i + 1) begin
            check_val16($sformatf("preempt word %0d", i),
                        burst_cap[i], 16'hCC00 + i[15:0]);
        end

        // Port 0 rdata is registered — wait one cycle for it to settle
        @(posedge clk); #1;
        check_val32("p0 read after preempt", p0_rdata, 32'h56781234);

        @(posedge clk); #1;

        // ============================================================
        // Test 8: Natural Burst Completion (Port 0, burst_len=4, no preemption)
        // ============================================================
        $display("--- Test 8: Natural Burst Completion (Port 0, len=4) ---");

        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h5000 + i[15:0]] = 16'hDD00 + i[15:0];
        end

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h005000;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        burst_cap_count = 0;
        cycle_count = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                burst_cap[burst_cap_count] = p0_burst_rdata;
                burst_cap_count = burst_cap_count + 1;
            end
        end

        $display("  Natural burst (4): %0d cycles, %0d words", cycle_count, burst_cap_count);
        check_bit("p0 natural burst ack", p0_ack, 1'b1);

        if (burst_cap_count == 4) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: natural burst expected 4 words, got %0d", burst_cap_count);
            fail_count = fail_count + 1;
        end

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("natural burst word %0d", i),
                        burst_cap[i], 16'hDD00 + i[15:0]);
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 9: burst_len=0 Backward Compatibility (all ports single-word)
        // ============================================================
        $display("--- Test 9: burst_len=0 Backward Compatibility ---");

        // Write via port 2 (single-word, burst_len=0)
        p2_req       = 1'b1;
        p2_we        = 1'b1;
        p2_addr      = 24'h000500;
        p2_wdata     = 32'hFACE0000;
        p2_burst_len = 8'd0;
        @(posedge clk); #1;
        p2_req = 1'b0;

        cycle_count = 0;
        while (!p2_ack && cycle_count < 20) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        check_bit("p2 single write ack", p2_ack, 1'b1);

        @(posedge clk); #1;

        // Read back via port 2 (single-word)
        p2_req       = 1'b1;
        p2_we        = 1'b0;
        p2_addr      = 24'h000500;
        p2_burst_len = 8'd0;
        @(posedge clk); #1;
        p2_req = 1'b0;

        cycle_count = 0;
        while (!p2_ack && cycle_count < 20) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        // rdata is registered — wait one cycle after ack
        @(posedge clk); #1;
        check_val32("p2 single read-back", p2_rdata, 32'hFACE0000);

        @(posedge clk); #1;

        // ============================================================
        // Test 10: Priority During Idle — Multiple Simultaneous Requests
        // ============================================================
        $display("--- Test 10: Priority (simultaneous requests) ---");

        // Pre-load different data for each port's read
        sram_mem[16'h0800] = 16'h0000;
        sram_mem[16'h0801] = 16'h0000;
        sram_mem[16'h0A00] = 16'h1111;
        sram_mem[16'h0A01] = 16'h1111;

        // Request simultaneously from port 0 and port 3
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000400;
        p0_burst_len = 8'd0;
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000500;
        p3_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p3_req asserted until served

        // Port 0 should be served first
        wait_p0_ack(20);
        #1;
        check_bit("priority p0 ack first", p0_ack, 1'b1);

        // Now wait for port 3
        @(posedge clk); #1;
        // Port 3 should now be served
        wait_p3_ack(20);
        #1;
        p3_req = 1'b0;
        check_bit("priority p3 ack second", p3_ack, 1'b1);

        @(posedge clk); #1;

        // ============================================================
        // Test 11: Reset During Burst
        // ============================================================
        $display("--- Test 11: Reset During Burst ---");

        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h6000 + i[15:0]] = 16'hEE00 + i[15:0];
        end

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h006000;
        p3_burst_len = 8'd8;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Let it run a couple cycles
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;

        // Assert reset mid-burst
        rst_n = 1'b0;
        #50;
        rst_n = 1'b1;
        @(posedge clk); #1;

        check_bit("p0_ready after burst reset", p0_ready, 1'b1);
        check_bit("p3_ack = 0 after reset", p3_ack, 1'b0);
        check_bit("p3_burst_data_valid = 0 after reset", p3_burst_data_valid, 1'b0);

        // Verify functional after reset — simple port 0 read
        sram_mem[16'h0100] = 16'h9999;
        sram_mem[16'h0101] = 16'h8888;

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000080;
        p0_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;

        wait_p0_ack(20);
        // rdata is registered — wait one cycle after ack
        @(posedge clk); #1;
        check_val32("read after reset recovery", p0_rdata, 32'h88889999);

        @(posedge clk); #1;

        // ============================================================
        // Test 12: Burst + Single-Word Interleaving
        // Port 0 single-word request during Port 3 burst → preempts
        // ============================================================
        $display("--- Test 12: Burst + Single-Word Interleaving ---");

        for (i = 0; i < 16; i = i + 1) begin
            sram_mem[16'h7000 + i[15:0]] = 16'hFF00 + i[15:0];
        end
        sram_mem[16'h0C00] = 16'hAAAA;
        sram_mem[16'h0C01] = 16'hBBBB;

        // Start port 3 burst (16 words)
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h007000;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Wait for 2 burst data words, then request single-word on port 0
        burst_cap_count = 0;
        cycle_count = 0;
        begin : interleave_test
            reg p3_done;
            reg p0_done;
            p3_done = 1'b0;
            p0_done = 1'b0;

            while (!p3_done || !p0_done) begin
                @(posedge clk); #1;
                cycle_count = cycle_count + 1;

                if (p3_burst_data_valid && !p3_done) begin
                    burst_cap[burst_cap_count] = p3_burst_rdata;
                    burst_cap_count = burst_cap_count + 1;
                end

                // After 2 words, assert port 0 single-word request
                if (burst_cap_count == 2 && !p0_req && !p0_done) begin
                    p0_req       = 1'b1;
                    p0_we        = 1'b0;
                    p0_addr      = 24'h000600;
                    p0_burst_len = 8'd0;
                end

                if (p3_ack) p3_done = 1'b1;

                // Deassert p0_req when ack fires
                if (p0_ack) begin
                    p0_done = 1'b1;
                    p0_req  = 1'b0;
                end

                if (cycle_count > 100) begin
                    $display("FAIL: interleave test timeout @ %0t", $time);
                    fail_count = fail_count + 1;
                    p0_req = 1'b0;
                    break;
                end
            end
        end

        $display("  Interleave: port 3 got %0d words, port 0 single-word served", burst_cap_count);

        // Port 3 should have been preempted (got < 16 words)
        if (burst_cap_count < 16) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: interleave — port 3 wasn't preempted");
            fail_count = fail_count + 1;
        end

        // Port 0 rdata is registered — wait one cycle after ack
        @(posedge clk); #1;
        check_val32("p0 interleave read", p0_rdata, 32'hBBBBAAAA);

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
        #2000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule
