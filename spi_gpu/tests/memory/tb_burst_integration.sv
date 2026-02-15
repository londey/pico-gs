`default_nettype none

// Integration Testbench: SRAM Controller + Arbiter Burst Data Path
// Verifies end-to-end burst transfers across the full memory subsystem:
//   Behavioral SRAM model ↔ sram_controller ↔ sram_arbiter ↔ port stubs
//
// Test scenarios:
//   1. Single-port burst read (display, port 0)
//   2. Single-port burst read (texture, port 3)
//   3. Concurrent burst requests — priority ordering
//   4. Burst preemption by higher-priority port
//   5. Burst write + burst read interleaving
//   6. Mixed burst and single-word operations
//   7. Back-to-back burst operations
//
// Uses 100 MHz clk_core (10 ns period) matching the unified GPU clock domain

module tb_burst_integration;

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
        forever #5 clk = ~clk;
    end

    // ========================================================================
    // Behavioral SRAM Model — 64K x 16-bit
    // ========================================================================

    reg [15:0] sram_mem [0:65535];

    /* verilator lint_off UNUSEDSIGNAL */
    wire [23:0] sram_addr;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] sram_data;
    wire        sram_we_n;
    wire        sram_oe_n;
    wire        sram_ce_n;

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
    // Controller ↔ Arbiter Interconnect Wires
    // ========================================================================

    // Arbiter → Controller
    wire        ctrl_req;
    wire        ctrl_we;
    wire [23:0] ctrl_addr;
    wire [31:0] ctrl_wdata;
    wire [7:0]  ctrl_burst_len;
    wire [15:0] ctrl_burst_wdata;
    wire        ctrl_burst_cancel;

    // Controller → Arbiter
    wire [31:0] ctrl_rdata;
    wire        ctrl_ack;
    wire        ctrl_ready;
    wire        ctrl_burst_data_valid;
    wire        ctrl_burst_wdata_req;
    wire        ctrl_burst_done;
    wire [15:0] ctrl_rdata_16;

    // ========================================================================
    // Port 0 Signals (Display — highest priority, burst read)
    // ========================================================================

    reg         p0_req;
    reg         p0_we;
    reg  [23:0] p0_addr;
    reg  [31:0] p0_wdata;
    reg  [7:0]  p0_burst_len;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] p0_rdata;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] p0_burst_rdata;
    wire        p0_burst_data_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        p0_burst_wdata_req;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        p0_ack;
    wire        p0_ready;

    // ========================================================================
    // Port 1 Signals (Framebuffer write)
    // ========================================================================

    reg         p1_req;
    reg         p1_we;
    reg  [23:0] p1_addr;
    reg  [31:0] p1_wdata;
    reg  [7:0]  p1_burst_len;
    reg  [15:0] p1_burst_wdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] p1_rdata;
    wire [15:0] p1_burst_rdata;
    wire        p1_burst_data_valid;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        p1_burst_wdata_req;
    wire        p1_ack;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        p1_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Port 2 Signals (Z-buffer — single-word or short burst)
    // ========================================================================

    reg         p2_req;
    reg         p2_we;
    reg  [23:0] p2_addr;
    reg  [31:0] p2_wdata;
    reg  [7:0]  p2_burst_len;
    reg  [15:0] p2_burst_wdata;
    wire [31:0] p2_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] p2_burst_rdata;
    wire        p2_burst_data_valid;
    wire        p2_burst_wdata_req;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        p2_ack;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        p2_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // Port 3 Signals (Texture — lowest priority, burst read)
    // ========================================================================

    reg         p3_req;
    reg         p3_we;
    reg  [23:0] p3_addr;
    reg  [31:0] p3_wdata;
    reg  [7:0]  p3_burst_len;
    reg  [15:0] p3_burst_wdata;
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] p3_rdata;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] p3_burst_rdata;
    wire        p3_burst_data_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        p3_burst_wdata_req;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        p3_ack;
    /* verilator lint_off UNUSEDSIGNAL */
    wire        p3_ready;
    /* verilator lint_on UNUSEDSIGNAL */

    // ========================================================================
    // DUT: SRAM Controller
    // ========================================================================

    sram_controller u_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .req              (ctrl_req),
        .we               (ctrl_we),
        .addr             (ctrl_addr),
        .wdata            (ctrl_wdata),
        .rdata            (ctrl_rdata),
        .ack              (ctrl_ack),
        .ready            (ctrl_ready),
        .burst_len        (ctrl_burst_len),
        .burst_wdata_16   (ctrl_burst_wdata),
        .burst_cancel     (ctrl_burst_cancel),
        .burst_data_valid (ctrl_burst_data_valid),
        .burst_wdata_req  (ctrl_burst_wdata_req),
        .burst_done       (ctrl_burst_done),
        .rdata_16         (ctrl_rdata_16),
        .sram_addr        (sram_addr),
        .sram_data        (sram_data),
        .sram_we_n        (sram_we_n),
        .sram_oe_n        (sram_oe_n),
        .sram_ce_n        (sram_ce_n)
    );

    // ========================================================================
    // DUT: SRAM Arbiter
    // ========================================================================

    sram_arbiter u_arb (
        .clk                    (clk),
        .rst_n                  (rst_n),

        // Port 0 — Display
        .port0_req              (p0_req),
        .port0_we               (p0_we),
        .port0_addr             (p0_addr),
        .port0_wdata            (p0_wdata),
        .port0_burst_len        (p0_burst_len),
        .port0_rdata            (p0_rdata),
        .port0_burst_rdata      (p0_burst_rdata),
        .port0_burst_data_valid (p0_burst_data_valid),
        .port0_burst_wdata_req  (p0_burst_wdata_req),
        .port0_ack              (p0_ack),
        .port0_ready            (p0_ready),

        // Port 1 — Framebuffer
        .port1_req              (p1_req),
        .port1_we               (p1_we),
        .port1_addr             (p1_addr),
        .port1_wdata            (p1_wdata),
        .port1_burst_len        (p1_burst_len),
        .port1_burst_wdata      (p1_burst_wdata),
        .port1_rdata            (p1_rdata),
        .port1_burst_rdata      (p1_burst_rdata),
        .port1_burst_data_valid (p1_burst_data_valid),
        .port1_burst_wdata_req  (p1_burst_wdata_req),
        .port1_ack              (p1_ack),
        .port1_ready            (p1_ready),

        // Port 2 — Z-buffer
        .port2_req              (p2_req),
        .port2_we               (p2_we),
        .port2_addr             (p2_addr),
        .port2_wdata            (p2_wdata),
        .port2_burst_len        (p2_burst_len),
        .port2_burst_wdata      (p2_burst_wdata),
        .port2_rdata            (p2_rdata),
        .port2_burst_rdata      (p2_burst_rdata),
        .port2_burst_data_valid (p2_burst_data_valid),
        .port2_burst_wdata_req  (p2_burst_wdata_req),
        .port2_ack              (p2_ack),
        .port2_ready            (p2_ready),

        // Port 3 — Texture
        .port3_req              (p3_req),
        .port3_we               (p3_we),
        .port3_addr             (p3_addr),
        .port3_wdata            (p3_wdata),
        .port3_burst_len        (p3_burst_len),
        .port3_burst_wdata      (p3_burst_wdata),
        .port3_rdata            (p3_rdata),
        .port3_burst_rdata      (p3_burst_rdata),
        .port3_burst_data_valid (p3_burst_data_valid),
        .port3_burst_wdata_req  (p3_burst_wdata_req),
        .port3_ack              (p3_ack),
        .port3_ready            (p3_ready),

        // SRAM Controller Interface — Single-Word
        .sram_req               (ctrl_req),
        .sram_we                (ctrl_we),
        .sram_addr              (ctrl_addr),
        .sram_wdata             (ctrl_wdata),
        .sram_rdata             (ctrl_rdata),
        .sram_ack               (ctrl_ack),
        .sram_ready             (ctrl_ready),

        // SRAM Controller Interface — Burst
        .sram_burst_len         (ctrl_burst_len),
        .sram_burst_wdata       (ctrl_burst_wdata),
        .sram_burst_cancel      (ctrl_burst_cancel),
        .sram_burst_data_valid  (ctrl_burst_data_valid),
        .sram_burst_wdata_req   (ctrl_burst_wdata_req),
        .sram_burst_done        (ctrl_burst_done),
        .sram_rdata_16          (ctrl_rdata_16)
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
    // Reset and Port Initialization
    // ========================================================================

    task do_reset;
        begin
            rst_n = 1'b0;

            // Port 0 defaults
            p0_req       = 1'b0;
            p0_we        = 1'b0;
            p0_addr      = 24'b0;
            p0_wdata     = 32'b0;
            p0_burst_len = 8'b0;

            // Port 1 defaults
            p1_req          = 1'b0;
            p1_we           = 1'b0;
            p1_addr         = 24'b0;
            p1_wdata        = 32'b0;
            p1_burst_len    = 8'b0;
            p1_burst_wdata  = 16'b0;

            // Port 2 defaults
            p2_req          = 1'b0;
            p2_we           = 1'b0;
            p2_addr         = 24'b0;
            p2_wdata        = 32'b0;
            p2_burst_len    = 8'b0;
            p2_burst_wdata  = 16'b0;

            // Port 3 defaults
            p3_req          = 1'b0;
            p3_we           = 1'b0;
            p3_addr         = 24'b0;
            p3_wdata        = 32'b0;
            p3_burst_len    = 8'b0;
            p3_burst_wdata  = 16'b0;

            #100;
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // ========================================================================
    // Storage for burst read captures
    // ========================================================================

    reg [15:0] capture_p0 [0:255];
    reg [15:0] capture_p3 [0:255];
    integer    cap_p0_count;
    integer    cap_p3_count;
    integer    cycle_count;

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("burst_integration.vcd");
        $dumpvars(0, tb_burst_integration);

        do_reset();

        $display("=== Integration Testbench: Burst Data Path ===\n");

        // ============================================================
        // Test 1: Display burst read only (port 0, burst_len=8)
        // ============================================================
        $display("--- Scenario 1: Display burst read only ---");

        // Pre-load SRAM with sequential pixel data at address 0x1000
        for (i = 0; i < 8; i = i + 1) begin
            sram_mem[16'h1000 + i[15:0]] = 16'hD000 + i[15:0];
        end

        // Issue burst read on port 0
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h001000;
        p0_burst_len = 8'd8;
        @(posedge clk); #1;
        p0_req = 1'b0;

        // Capture burst data from port 0
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S1: port0 ack", p0_ack, 1'b1);
        $display("  Display burst read: %0d cycles, %0d words captured", cycle_count, cap_p0_count);

        // Verify all 8 words
        for (i = 0; i < 8; i = i + 1) begin
            check_val16($sformatf("S1: p0 word %0d", i),
                        capture_p0[i], 16'hD000 + i[15:0]);
        end

        if (cap_p0_count == 8) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: S1 p0 word count — expected 8, got %0d", cap_p0_count);
            fail_count = fail_count + 1;
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 2: Texture burst read only (port 3, BC1 burst_len=4)
        // ============================================================
        $display("--- Scenario 2: Texture burst read only ---");

        // Pre-load BC1 block data at address 0x2000
        sram_mem[16'h2000] = 16'hF800;  // color0 = red
        sram_mem[16'h2001] = 16'h07E0;  // color1 = green
        sram_mem[16'h2002] = 16'h5555;  // indices low
        sram_mem[16'h2003] = 16'hAAAA;  // indices high

        // Issue BC1 burst read on port 3
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h002000;
        p3_burst_len = 8'd4;
        @(posedge clk); #1;
        p3_req = 1'b0;

        cap_p3_count = 0;
        cycle_count  = 0;
        while (!p3_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end

        check_bit("S2: port3 ack", p3_ack, 1'b1);
        $display("  Texture burst read: %0d cycles, %0d words captured", cycle_count, cap_p3_count);

        check_val16("S2: p3 word 0 (color0)", capture_p3[0], 16'hF800);
        check_val16("S2: p3 word 1 (color1)", capture_p3[1], 16'h07E0);
        check_val16("S2: p3 word 2 (idx lo)", capture_p3[2], 16'h5555);
        check_val16("S2: p3 word 3 (idx hi)", capture_p3[3], 16'hAAAA);

        if (cap_p3_count == 4) begin
            pass_count = pass_count + 1;
        end else begin
            $display("FAIL: S2 p3 word count — expected 4, got %0d", cap_p3_count);
            fail_count = fail_count + 1;
        end

        // Now test RGBA4444 burst (burst_len=16)
        $display("  Testing RGBA4444 burst (16 words)...");

        for (i = 0; i < 16; i = i + 1) begin
            sram_mem[16'h3000 + i[15:0]] = 16'hA000 + i[15:0];
        end

        @(posedge clk); #1;

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h003000;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        cap_p3_count = 0;
        cycle_count  = 0;
        while (!p3_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end

        check_bit("S2b: port3 ack (RGBA4444)", p3_ack, 1'b1);
        $display("  RGBA4444 burst: %0d cycles, %0d words captured", cycle_count, cap_p3_count);

        for (i = 0; i < 16; i = i + 1) begin
            check_val16($sformatf("S2b: p3 word %0d", i),
                        capture_p3[i], 16'hA000 + i[15:0]);
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 3: Concurrent display + texture — priority ordering
        // ============================================================
        $display("--- Scenario 3: Concurrent burst requests — priority ---");

        // Pre-load display data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h4000 + i[15:0]] = 16'hDD00 + i[15:0];
        end
        // Pre-load texture data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h5000 + i[15:0]] = 16'h5000 + i[15:0];
        end

        // Both ports request simultaneously
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h004000;
        p0_burst_len = 8'd4;

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h005000;
        p3_burst_len = 8'd4;
        @(posedge clk); #1;
        // Deassert port 0 req after one cycle (arbiter latches it)
        p0_req = 1'b0;
        // Keep port 3 req asserted until it gets served

        // Capture port 0 burst data first (higher priority)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S3: port0 served first (ack)", p0_ack, 1'b1);
        $display("  Port 0 (display) served first: %0d cycles, %0d words", cycle_count, cap_p0_count);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S3: p0 word %0d", i),
                        capture_p0[i], 16'hDD00 + i[15:0]);
        end

        // Now port 3 should be served (its req is still asserted)
        @(posedge clk); #1;  // DONE→IDLE transition

        cap_p3_count = 0;
        cycle_count  = 0;
        while (!p3_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end
        p3_req = 1'b0;

        check_bit("S3: port3 served second (ack)", p3_ack, 1'b1);
        $display("  Port 3 (texture) served second: %0d cycles, %0d words", cycle_count, cap_p3_count);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S3: p3 word %0d", i),
                        capture_p3[i], 16'h5000 + i[15:0]);
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 4: Burst preemption
        // ============================================================
        $display("--- Scenario 4: Burst preemption ---");

        // Pre-load texture region (port 3 will read this)
        for (i = 0; i < 16; i = i + 1) begin
            sram_mem[16'h6000 + i[15:0]] = 16'hEE00 + i[15:0];
        end
        // Pre-load display region (port 0 will preempt with this)
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h7000 + i[15:0]] = 16'hFF00 + i[15:0];
        end

        // Start texture burst (port 3, burst_len=16)
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h006000;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Wait for a few data words, then preempt with display port
        cap_p3_count = 0;
        cycle_count  = 0;
        while (cap_p3_count < 5 && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end

        $display("  Texture received %0d words before preemption", cap_p3_count);

        // Verify partial data is correct
        for (i = 0; i < cap_p3_count && i < 5; i = i + 1) begin
            check_val16($sformatf("S4: p3 partial word %0d", i),
                        capture_p3[i], 16'hEE00 + i[15:0]);
        end

        // Assert display port request to trigger preemption
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h007000;
        p0_burst_len = 8'd4;

        // Wait for port 3 ack (preempted burst completion)
        while (!p3_ack && cycle_count < 100) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end

        check_bit("S4: port3 preempted (ack)", p3_ack, 1'b1);
        $display("  Port 3 preempted after %0d total words", cap_p3_count);

        // Keep p0_req asserted — arbiter needs 2 cycles to re-grant:
        //   Cycle 1: arbiter clears grant_active (processes sram_ack)
        //   Cycle 2: arbiter sees p0_req=1 in IDLE → grants port 0

        // Now port 0 should be served (keep p0_req=1 until burst completes)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end
        p0_req = 1'b0;  // Deassert after burst completes

        check_bit("S4: port0 served after preemption (ack)", p0_ack, 1'b1);
        $display("  Port 0 (display) served: %0d words", cap_p0_count);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S4: p0 word %0d", i),
                        capture_p0[i], 16'hFF00 + i[15:0]);
        end

        @(posedge clk); #1;

        // ============================================================
        // Test 5: Burst write + burst read interleaving
        // ============================================================
        $display("--- Scenario 5: Burst write + burst read interleaving ---");

        // Pre-load display read data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h8000 + i[15:0]] = 16'hAA00 + i[15:0];
        end

        // Clear framebuffer write region
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'h9000 + i[15:0]] = 16'h0000;
        end

        // Issue display burst read (port 0, highest priority)
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h008000;
        p0_burst_len = 8'd4;

        // Issue framebuffer burst write (port 1) simultaneously
        p1_req          = 1'b1;
        p1_we           = 1'b1;
        p1_addr         = 24'h009000;
        p1_burst_len    = 8'd4;
        p1_burst_wdata  = 16'hBB00;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p1_req asserted until served

        // Port 0 should be served first (higher priority)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S5: port0 read ack", p0_ack, 1'b1);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S5: p0 read word %0d", i),
                        capture_p0[i], 16'hAA00 + i[15:0]);
        end

        // Now port 1 burst write should proceed
        @(posedge clk); #1;  // DONE→IDLE

        cycle_count = 0;
        i = 1;
        while (!p1_ack && cycle_count < 50) begin
            if (p1_burst_wdata_req) begin
                p1_burst_wdata = 16'hBB00 + i[15:0];
                i = i + 1;
            end
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        p1_req = 1'b0;

        check_bit("S5: port1 write ack", p1_ack, 1'b1);
        $display("  Port 1 burst write completed: %0d cycles", cycle_count);

        // Wait for write to settle, then verify SRAM contents
        @(posedge clk); #1;

        check_val16("S5: p1 write word 0", sram_mem[16'h9000], 16'hBB00);
        check_val16("S5: p1 write word 1", sram_mem[16'h9001], 16'hBB01);
        check_val16("S5: p1 write word 2", sram_mem[16'h9002], 16'hBB02);
        check_val16("S5: p1 write word 3", sram_mem[16'h9003], 16'hBB03);

        @(posedge clk); #1;

        // ============================================================
        // Test 6: Mixed burst and single-word operations
        // ============================================================
        $display("--- Scenario 6: Mixed burst and single-word ---");

        // Pre-load display burst data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'hA000 + i[15:0]] = 16'hCC00 + i[15:0];
        end

        // Pre-load Z-buffer single-word data (32-bit word at address 0x500)
        // Low 16 bits at SRAM addr 0xA00, high at 0xA01
        sram_mem[16'h0A00] = 16'h1234;
        sram_mem[16'h0A01] = 16'h5678;

        // Issue display burst read (port 0)
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h00A000;
        p0_burst_len = 8'd4;

        // Simultaneously issue Z-buffer single-word read (port 2, burst_len=0)
        p2_req       = 1'b1;
        p2_we        = 1'b0;
        p2_addr      = 24'h000500;
        p2_burst_len = 8'd0;
        p2_wdata     = 32'b0;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p2_req until served

        // Port 0 burst served first
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S6: port0 burst ack", p0_ack, 1'b1);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S6: p0 word %0d", i),
                        capture_p0[i], 16'hCC00 + i[15:0]);
        end

        // Now port 2 single-word read should complete
        @(posedge clk); #1;  // DONE→IDLE

        cycle_count = 0;
        while (!p2_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end
        p2_req = 1'b0;

        check_bit("S6: port2 single-word ack", p2_ack, 1'b1);
        // p2_rdata is updated one cycle after ack
        @(posedge clk); #1;
        check_val32("S6: port2 single-word rdata", p2_rdata, 32'h56781234);
        $display("  Mixed burst/single-word: both completed correctly");

        @(posedge clk); #1;

        // ============================================================
        // Test 7: Back-to-back burst operations on same port
        // ============================================================
        $display("--- Scenario 7: Back-to-back bursts ---");

        // Pre-load first burst data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'hB000 + i[15:0]] = 16'h1100 + i[15:0];
        end
        // Pre-load second burst data
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'hC000 + i[15:0]] = 16'h2200 + i[15:0];
        end

        // First burst read (port 0)
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h00B000;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S7: first burst ack", p0_ack, 1'b1);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S7: first burst word %0d", i),
                        capture_p0[i], 16'h1100 + i[15:0]);
        end

        // Wait for DONE→IDLE and immediately issue next burst
        @(posedge clk); #1;
        check_bit("S7: ready between bursts", p0_ready, 1'b1);

        // Second burst — immediately after ready
        p0_req       = 1'b1;
        p0_addr      = 24'h00C000;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 50) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p0_burst_data_valid) begin
                capture_p0[cap_p0_count] = p0_burst_rdata;
                cap_p0_count = cap_p0_count + 1;
            end
        end

        check_bit("S7: second burst ack", p0_ack, 1'b1);

        for (i = 0; i < 4; i = i + 1) begin
            check_val16($sformatf("S7: second burst word %0d", i),
                        capture_p0[i], 16'h2200 + i[15:0]);
        end

        $display("  Back-to-back bursts: both completed with correct data");

        @(posedge clk); #1;

        // ============================================================
        // Cycle Count Verification
        // ============================================================
        $display("\n--- Cycle Count Verification ---");

        // Burst read: N+2 cycles (IDLE→SETUP + N*NEXT + DONE)
        // Test with burst_len=4: expected 4+2 = 6 cycles from req to after ack
        for (i = 0; i < 4; i = i + 1) begin
            sram_mem[16'hD000 + i[15:0]] = 16'h0000 + i[15:0];
        end

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h00D000;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cycle_count = 0;
        while (!p0_ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        // Cycles from req deassert to ack: SETUP(1) + 4*NEXT(4) + DONE(1) = 6
        // But the arbiter adds 1 cycle for grant latching, total = 6 after req deassert
        $display("  Burst read (len=4) cycle count: %0d (expected ~6)", cycle_count);

        // Verify cycle count is reasonable (INT-011: N+2 for controller,
        // arbiter adds 1 cycle for grant = N+3 total)
        if (cycle_count <= 8 && cycle_count >= 5) begin
            pass_count = pass_count + 1;
            $display("  Cycle count within expected range");
        end else begin
            $display("FAIL: burst read cycle count %0d outside expected range 5-8", cycle_count);
            fail_count = fail_count + 1;
        end

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

`default_nettype wire
