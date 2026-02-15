`default_nettype none

// Integration Testbench: SDRAM Controller + Arbiter Burst Data Path
// Verifies end-to-end burst transfers across the full memory subsystem:
//   Behavioral SDRAM model ↔ sdram_controller ↔ sram_arbiter ↔ port stubs
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
    // Behavioral SDRAM Model — W9825G6KH-6
    // ========================================================================
    // Reduced memory for simulation: 4 banks x 16 rows x 512 columns x 16 bits
    // Commands decoded from {csn, rasn, casn, wen}

    localparam [3:0] SCMD_NOP          = 4'b0111;
    localparam [3:0] SCMD_ACTIVATE     = 4'b0011;
    localparam [3:0] SCMD_READ         = 4'b0101;
    localparam [3:0] SCMD_WRITE        = 4'b0100;
    localparam [3:0] SCMD_PRECHARGE    = 4'b0010;
    localparam [3:0] SCMD_AUTO_REFRESH = 4'b0001;
    localparam [3:0] SCMD_LOAD_MODE    = 4'b0000;

    reg [15:0] sdram_mem [0:3][0:15][0:511];

    reg        bank_active          [0:3];
    reg [12:0] bank_active_row      [0:3];
    integer    bank_activate_cycle  [0:3];
    integer    bank_precharge_cycle [0:3];
    integer    bank_last_write_cycle[0:3];

    reg        mode_reg_set;
    reg        sdram_initialized;

    localparam PIPE_DEPTH = 8;
    reg [15:0] read_pipe_data  [0:PIPE_DEPTH-1];
    reg        read_pipe_valid [0:PIPE_DEPTH-1];

    reg        sdram_model_dq_oe;
    reg [15:0] sdram_model_dq_out;
    integer    dq_hold_count;

    // External SDRAM interface wires
    wire         sdram_cke;
    wire         sdram_csn;
    wire         sdram_rasn;
    wire         sdram_casn;
    wire         sdram_wen;
    wire [1:0]   sdram_ba;
    wire [12:0]  sdram_a;
    wire [15:0]  sdram_dq;
    wire [1:0]   sdram_dqm;

    assign sdram_dq = sdram_model_dq_oe ? sdram_model_dq_out : 16'bz;

    integer sdram_cycle;
    wire [3:0] sdram_cmd = {sdram_csn, sdram_rasn, sdram_casn, sdram_wen};

    integer bi, ri, ci;
    initial begin
        sdram_initialized    = 0;
        mode_reg_set         = 0;
        sdram_cycle          = 0;
        sdram_model_dq_oe    = 0;
        sdram_model_dq_out   = 16'h0;
        dq_hold_count        = 0;

        for (bi = 0; bi < 4; bi = bi + 1) begin
            bank_active[bi]           = 0;
            bank_active_row[bi]       = 13'd0;
            bank_activate_cycle[bi]   = -100;
            bank_precharge_cycle[bi]  = -100;
            bank_last_write_cycle[bi] = -100;
        end

        for (ri = 0; ri < PIPE_DEPTH; ri = ri + 1) begin
            read_pipe_data[ri]  = 16'h0;
            read_pipe_valid[ri] = 0;
        end

        for (bi = 0; bi < 4; bi = bi + 1) begin
            for (ri = 0; ri < 16; ri = ri + 1) begin
                for (ci = 0; ci < 512; ci = ci + 1) begin
                    sdram_mem[bi][ri][ci] = 16'h0;
                end
            end
        end
    end

    always @(posedge clk) begin
        sdram_cycle <= sdram_cycle + 1;

        if (read_pipe_valid[0]) begin
            sdram_model_dq_oe  <= 1;
            sdram_model_dq_out <= read_pipe_data[0];
            dq_hold_count      <= 2;
        end else if (dq_hold_count > 0) begin
            dq_hold_count <= dq_hold_count - 1;
        end else begin
            sdram_model_dq_oe <= 0;
        end

        for (ri = 0; ri < PIPE_DEPTH - 1; ri = ri + 1) begin
            read_pipe_data[ri]  <= read_pipe_data[ri + 1];
            read_pipe_valid[ri] <= read_pipe_valid[ri + 1];
        end
        read_pipe_data[PIPE_DEPTH-1]  <= 16'h0;
        read_pipe_valid[PIPE_DEPTH-1] <= 0;

        if (!rst_n) begin
            sdram_initialized    <= 0;
            mode_reg_set         <= 0;
            sdram_model_dq_oe    <= 0;
            sdram_model_dq_out   <= 16'h0;
            dq_hold_count        <= 0;
            for (bi = 0; bi < 4; bi = bi + 1) begin
                bank_active[bi]           <= 0;
                bank_activate_cycle[bi]   <= -100;
                bank_precharge_cycle[bi]  <= -100;
                bank_last_write_cycle[bi] <= -100;
            end
            for (ri = 0; ri < PIPE_DEPTH; ri = ri + 1) begin
                read_pipe_data[ri]  <= 16'h0;
                read_pipe_valid[ri] <= 0;
            end
        end else begin
            case (sdram_cmd)
                SCMD_NOP: begin
                end

                SCMD_ACTIVATE: begin
                    bank_active[sdram_ba]         <= 1;
                    bank_active_row[sdram_ba]     <= sdram_a;
                    bank_activate_cycle[sdram_ba] <= sdram_cycle;
                end

                SCMD_READ: begin
                    begin
                        /* verilator lint_off WIDTHEXPAND */
                        automatic logic [12:0] active_row = bank_active_row[sdram_ba];
                        /* verilator lint_on WIDTHEXPAND */
                        automatic logic [8:0]  col = sdram_a[8:0];
                        automatic logic [3:0]  row_idx = active_row[3:0];
                        read_pipe_data[0]  <= sdram_mem[sdram_ba][row_idx][col];
                        read_pipe_valid[0] <= 1;
                    end
                end

                SCMD_WRITE: begin
                    begin
                        /* verilator lint_off WIDTHEXPAND */
                        automatic logic [12:0] active_row = bank_active_row[sdram_ba];
                        /* verilator lint_on WIDTHEXPAND */
                        automatic logic [8:0]  col = sdram_a[8:0];
                        automatic logic [3:0]  row_idx = active_row[3:0];
                        sdram_mem[sdram_ba][row_idx][col] <= sdram_dq;
                    end
                    bank_last_write_cycle[sdram_ba] <= sdram_cycle;
                end

                SCMD_PRECHARGE: begin
                    if (sdram_a[10]) begin
                        for (bi = 0; bi < 4; bi = bi + 1) begin
                            bank_active[bi]          <= 0;
                            bank_precharge_cycle[bi] <= sdram_cycle;
                        end
                    end else begin
                        bank_active[sdram_ba]          <= 0;
                        bank_precharge_cycle[sdram_ba] <= sdram_cycle;
                    end
                end

                SCMD_AUTO_REFRESH: begin
                    // Model accepts auto-refresh; no data action
                end

                SCMD_LOAD_MODE: begin
                    mode_reg_set      <= 1;
                    sdram_initialized <= 1;
                end

                default: begin
                end
            endcase
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
    // DUT: SDRAM Controller
    // ========================================================================

    sdram_controller u_ctrl (
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
        .sdram_cke        (sdram_cke),
        .sdram_csn        (sdram_csn),
        .sdram_rasn       (sdram_rasn),
        .sdram_casn       (sdram_casn),
        .sdram_wen        (sdram_wen),
        .sdram_ba         (sdram_ba),
        .sdram_a          (sdram_a),
        .sdram_dq         (sdram_dq),
        .sdram_dqm        (sdram_dqm)
    );

    // ========================================================================
    // DUT: SRAM Arbiter (connects to SDRAM controller via mem_* interface)
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

        // SDRAM Controller Interface — Single-Word
        .mem_req               (ctrl_req),
        .mem_we                (ctrl_we),
        .mem_addr              (ctrl_addr),
        .mem_wdata             (ctrl_wdata),
        .mem_rdata             (ctrl_rdata),
        .mem_ack               (ctrl_ack),
        .mem_ready             (ctrl_ready),

        // SDRAM Controller Interface — Burst
        .mem_burst_len         (ctrl_burst_len),
        .mem_burst_wdata       (ctrl_burst_wdata),
        .mem_burst_cancel      (ctrl_burst_cancel),
        .mem_burst_data_valid  (ctrl_burst_data_valid),
        .mem_burst_wdata_req   (ctrl_burst_wdata_req),
        .mem_burst_done        (ctrl_burst_done),
        .mem_rdata_16          (ctrl_rdata_16)
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
    // Helper: wait for SDRAM initialization to complete
    // ========================================================================

    task wait_init_complete(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!ctrl_ready && cyc < max_cycles) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
            end
            if (cyc >= max_cycles) begin
                $display("FAIL: SDRAM init timeout after %0d cycles @ %0t", max_cycles, $time);
                fail_count = fail_count + 1;
            end else begin
                $display("  SDRAM initialization complete after %0d cycles", cyc);
            end
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

        // Wait for SDRAM initialization to complete (~20000 cycles)
        $display("=== Waiting for SDRAM initialization ===");
        wait_init_complete(25000);

        $display("=== Integration Testbench: Burst Data Path (SDRAM Backend) ===\n");

        // ============================================================
        // Test 1: Display burst read only (port 0, burst_len=8)
        // ============================================================
        $display("--- Scenario 1: Display burst read only ---");

        // Pre-load SDRAM with sequential pixel data
        // addr = 24'h000020 -> bank=0, row=0, col={addr[8:1],0}={16,0}=32
        for (i = 0; i < 8; i = i + 1) begin
            sdram_mem[0][0][32 + i] = 16'hD000 + i[15:0];
        end

        // Issue burst read on port 0
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000020;
        p0_burst_len = 8'd8;
        @(posedge clk); #1;
        p0_req = 1'b0;

        // Capture burst data from port 0
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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

        // Pre-load BC1 block data
        // addr = 24'h000040 -> col={32,0}=64
        sdram_mem[0][0][64] = 16'hF800;  // color0 = red
        sdram_mem[0][0][65] = 16'h07E0;  // color1 = green
        sdram_mem[0][0][66] = 16'h5555;  // indices low
        sdram_mem[0][0][67] = 16'hAAAA;  // indices high

        // Issue BC1 burst read on port 3
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000040;
        p3_burst_len = 8'd4;
        @(posedge clk); #1;
        p3_req = 1'b0;

        cap_p3_count = 0;
        cycle_count  = 0;
        while (!p3_ack && cycle_count < 200) begin
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

        // addr = 24'h000060 -> col={48,0}=96
        for (i = 0; i < 16; i = i + 1) begin
            sdram_mem[0][0][96 + i] = 16'hA000 + i[15:0];
        end

        @(posedge clk); #1;

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000060;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        cap_p3_count = 0;
        cycle_count  = 0;
        while (!p3_ack && cycle_count < 200) begin
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

        // Pre-load display data at col 128-131
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][128 + i] = 16'hDD00 + i[15:0];
        end
        // Pre-load texture data at col 160-163
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][160 + i] = 16'h5000 + i[15:0];
        end

        // Both ports request simultaneously
        // addr = 24'h000080 -> col=128, addr = 24'h0000A0 -> col=160
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000080;
        p0_burst_len = 8'd4;

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h0000A0;
        p3_burst_len = 8'd4;
        @(posedge clk); #1;
        // Deassert port 0 req after one cycle (arbiter latches it)
        p0_req = 1'b0;
        // Keep port 3 req asserted until it gets served

        // Capture port 0 burst data first (higher priority)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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
        while (!p3_ack && cycle_count < 200) begin
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

        // Pre-load texture region (port 3 will read this) at col 192-207
        for (i = 0; i < 16; i = i + 1) begin
            sdram_mem[0][0][192 + i] = 16'hEE00 + i[15:0];
        end
        // Pre-load display region (port 0 will preempt with this) at col 224-227
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][224 + i] = 16'hFF00 + i[15:0];
        end

        // Start texture burst (port 3, burst_len=16)
        // addr = 24'h0000C0 -> col={96,0}=192
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h0000C0;
        p3_burst_len = 8'd16;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Wait for a few data words, then preempt with display port
        cap_p3_count = 0;
        cycle_count  = 0;
        while (cap_p3_count < 5 && cycle_count < 200) begin
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
        // addr = 24'h0000E0 -> col={112,0}=224
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h0000E0;
        p0_burst_len = 8'd4;

        // Wait for port 3 ack (preempted burst completion)
        while (!p3_ack && cycle_count < 400) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
            if (p3_burst_data_valid) begin
                capture_p3[cap_p3_count] = p3_burst_rdata;
                cap_p3_count = cap_p3_count + 1;
            end
        end

        check_bit("S4: port3 preempted (ack)", p3_ack, 1'b1);
        $display("  Port 3 preempted after %0d total words", cap_p3_count);

        // Now port 0 should be served (keep p0_req=1 until burst completes)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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

        // Pre-load display read data at col 256-259
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][256 + i] = 16'hAA00 + i[15:0];
        end

        // Clear framebuffer write region at col 288-291
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][288 + i] = 16'h0000;
        end

        // Issue display burst read (port 0, highest priority)
        // addr = 24'h000100 -> col={128,0}=256
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000100;
        p0_burst_len = 8'd4;

        // Issue framebuffer burst write (port 1) simultaneously
        // addr = 24'h000120 -> col={144,0}=288
        p1_req          = 1'b1;
        p1_we           = 1'b1;
        p1_addr         = 24'h000120;
        p1_burst_len    = 8'd4;
        p1_burst_wdata  = 16'hBB00;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p1_req asserted until served

        // Port 0 should be served first (higher priority)
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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
        while (!p1_ack && cycle_count < 200) begin
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

        // Wait for write to settle, then verify SDRAM contents
        @(posedge clk); #1;
        @(posedge clk); #1;

        check_val16("S5: p1 write word 0", sdram_mem[0][0][288], 16'hBB00);
        check_val16("S5: p1 write word 1", sdram_mem[0][0][289], 16'hBB01);
        check_val16("S5: p1 write word 2", sdram_mem[0][0][290], 16'hBB02);
        check_val16("S5: p1 write word 3", sdram_mem[0][0][291], 16'hBB03);

        @(posedge clk); #1;

        // ============================================================
        // Test 6: Mixed burst and single-word operations
        // ============================================================
        $display("--- Scenario 6: Mixed burst and single-word ---");

        // Pre-load display burst data at col 320-323
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][320 + i] = 16'hCC00 + i[15:0];
        end

        // Pre-load Z-buffer single-word data at col 4/5
        sdram_mem[0][0][4] = 16'h1234;
        sdram_mem[0][0][5] = 16'h5678;

        // Issue display burst read (port 0)
        // addr = 24'h000140 -> col={160,0}=320
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000140;
        p0_burst_len = 8'd4;

        // Simultaneously issue Z-buffer single-word read (port 2, burst_len=0)
        // addr = 24'h000004 -> col=4/5
        p2_req       = 1'b1;
        p2_we        = 1'b0;
        p2_addr      = 24'h000004;
        p2_burst_len = 8'd0;
        p2_wdata     = 32'b0;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p2_req until served

        // Port 0 burst served first
        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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
        while (!p2_ack && cycle_count < 200) begin
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

        // Pre-load first burst data at col 352-355
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][352 + i] = 16'h1100 + i[15:0];
        end
        // Pre-load second burst data at col 384-387
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][384 + i] = 16'h2200 + i[15:0];
        end

        // First burst read (port 0)
        // addr = 24'h000160 -> col={176,0}=352
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000160;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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
        // addr = 24'h000180 -> col={192,0}=384
        p0_req       = 1'b1;
        p0_addr      = 24'h000180;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cap_p0_count = 0;
        cycle_count  = 0;
        while (!p0_ack && cycle_count < 200) begin
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

        // Burst read with SDRAM: ACTIVATE(tRCD=2) + pipelined READs(N+CL) + PRECHARGE(tRP=2) + DONE
        // For burst_len=4: expected ~12-18 cycles from req to ack
        // (SDRAM has higher latency than async SRAM)
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][416 + i] = 16'h0000 + i[15:0];
        end

        // addr = 24'h0001A0 -> col={208,0}=416
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h0001A0;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        cycle_count = 0;
        while (!p0_ack) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        // With SDRAM: ACTIVATE(2+1 cmd) + READ pipelining(4+CL=7) + PRECHARGE(2) + DONE(1)
        // Plus arbiter grant overhead (~1 cycle). Total ~ 12-18 cycles.
        $display("  Burst read (len=4) cycle count: %0d (expected ~12-18 for SDRAM)", cycle_count);

        // Verify cycle count is reasonable for SDRAM timing
        if (cycle_count <= 25 && cycle_count >= 8) begin
            pass_count = pass_count + 1;
            $display("  Cycle count within expected range for SDRAM");
        end else begin
            $display("FAIL: burst read cycle count %0d outside expected range 8-25", cycle_count);
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

    // Timeout watchdog (increased for SDRAM init + re-init)
    initial begin
        #10000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule

`default_nettype wire
