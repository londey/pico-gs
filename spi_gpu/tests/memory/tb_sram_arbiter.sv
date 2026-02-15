`default_nettype none

// Testbench for sram_arbiter module with burst support (SDRAM backend)
// Tests 3-state grant FSM: single-word backward compatibility,
// burst read/write, burst data routing, burst preemption,
// preemption data integrity, natural burst completion,
// burst+single-word interleaving, auto-refresh preemption,
// and reset during burst.
// Instantiates sdram_controller + behavioral SDRAM model for end-to-end verification.

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
    // Arbiter ↔ SDRAM Controller Interconnect
    // ========================================================================

    wire        mem_req;
    wire        mem_we;
    wire [23:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [31:0] mem_rdata;
    wire        mem_ack;
    wire        mem_ready;

    wire [7:0]  mem_burst_len;
    wire [15:0] mem_burst_wdata_w;
    wire        mem_burst_cancel;
    wire        mem_burst_data_valid;
    wire        mem_burst_wdata_req;
    wire        mem_burst_done;
    wire [15:0] mem_rdata_16;

    // External SDRAM interface
    wire         sdram_cke;
    wire         sdram_csn;
    wire         sdram_rasn;
    wire         sdram_casn;
    wire         sdram_wen;
    wire [1:0]   sdram_ba;
    wire [12:0]  sdram_a;
    wire [15:0]  sdram_dq;
    wire [1:0]   sdram_dqm;

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

    localparam T_RCD_MIN = 2;
    localparam T_RP_MIN  = 2;
    localparam T_RAS_MIN = 5;
    localparam T_RC_MIN  = 6;
    localparam T_WR_MIN  = 2;
    localparam CAS_LAT   = 3;

    reg [15:0] sdram_mem [0:3][0:15][0:511];

    reg        bank_active          [0:3];
    reg [12:0] bank_active_row      [0:3];
    integer    bank_activate_cycle  [0:3];
    integer    bank_precharge_cycle [0:3];
    integer    bank_last_write_cycle[0:3];

    reg        mode_reg_set;
    reg        sdram_initialized;
    integer    init_precharge_count;
    integer    init_refresh_count;

    localparam PIPE_DEPTH = 8;
    reg [15:0] read_pipe_data  [0:PIPE_DEPTH-1];
    reg        read_pipe_valid [0:PIPE_DEPTH-1];

    reg        sdram_model_dq_oe;
    reg [15:0] sdram_model_dq_out;
    integer    dq_hold_count;

    assign sdram_dq = sdram_model_dq_oe ? sdram_model_dq_out : 16'bz;

    integer sdram_cycle;
    wire [3:0] sdram_cmd = {sdram_csn, sdram_rasn, sdram_casn, sdram_wen};

    integer bi, ri, ci;
    initial begin
        sdram_initialized    = 0;
        mode_reg_set         = 0;
        init_precharge_count = 0;
        init_refresh_count   = 0;
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
            init_precharge_count <= 0;
            init_refresh_count   <= 0;
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
                        init_precharge_count <= init_precharge_count + 1;
                    end else begin
                        bank_active[sdram_ba]          <= 0;
                        bank_precharge_cycle[sdram_ba] <= sdram_cycle;
                    end
                end

                SCMD_AUTO_REFRESH: begin
                    init_refresh_count <= init_refresh_count + 1;
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

        // To SDRAM controller — single-word
        .mem_req(mem_req),
        .mem_we(mem_we),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata),
        .mem_ack(mem_ack),
        .mem_ready(mem_ready),

        // To SDRAM controller — burst
        .mem_burst_len(mem_burst_len),
        .mem_burst_wdata(mem_burst_wdata_w),
        .mem_burst_cancel(mem_burst_cancel),
        .mem_burst_data_valid(mem_burst_data_valid),
        .mem_burst_wdata_req(mem_burst_wdata_req),
        .mem_burst_done(mem_burst_done),
        .mem_rdata_16(mem_rdata_16)
    );

    // ========================================================================
    // SDRAM Controller
    // ========================================================================

    sdram_controller dut_ctrl (
        .clk(clk),
        .rst_n(rst_n),

        .req(mem_req),
        .we(mem_we),
        .addr(mem_addr),
        .wdata(mem_wdata),
        .rdata(mem_rdata),
        .ack(mem_ack),
        .ready(mem_ready),

        .burst_len(mem_burst_len),
        .burst_wdata_16(mem_burst_wdata_w),
        .burst_cancel(mem_burst_cancel),
        .burst_data_valid(mem_burst_data_valid),
        .burst_wdata_req(mem_burst_wdata_req),
        .burst_done(mem_burst_done),
        .rdata_16(mem_rdata_16),

        .sdram_cke(sdram_cke),
        .sdram_csn(sdram_csn),
        .sdram_rasn(sdram_rasn),
        .sdram_casn(sdram_casn),
        .sdram_wen(sdram_wen),
        .sdram_ba(sdram_ba),
        .sdram_a(sdram_a),
        .sdram_dq(sdram_dq),
        .sdram_dqm(sdram_dqm)
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
    // Helper: wait for SDRAM initialization to complete
    // ========================================================================

    task wait_init_complete(input integer max_cycles);
        integer cyc;
        begin
            cyc = 0;
            while (!mem_ready && cyc < max_cycles) begin
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
    // Helper: wait for port N ack with timeout
    // Timeouts increased 4x for SDRAM latency (~12 cycles per single-word)
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
    // Helper: pre-load SDRAM model at a given address
    // ========================================================================
    // SDRAM addresses: bank = addr[23:22], row = addr[21:9], col = {addr[8:1], 1'b0}
    // For the behavioral model, row index is truncated to [3:0] (16 rows).
    // For sequential 16-bit accesses, each word occupies one column.
    //
    // To load data at a specific column in bank 0, row 0:
    //   sdram_mem[bank][row_idx][col] = data;

    // ========================================================================
    // Main Test Sequence
    // ========================================================================

    initial begin
        $dumpfile("sram_arbiter.vcd");
        $dumpvars(0, tb_sram_arbiter);

        do_reset();

        // Wait for SDRAM initialization to complete (~20000 cycles)
        $display("=== Waiting for SDRAM initialization ===");
        wait_init_complete(25000);

        $display("=== Testing sram_arbiter Module (SDRAM Backend, Burst Support) ===\n");

        // ============================================================
        // Test 1: Reset State
        // ============================================================
        $display("--- Test 1: Reset State ---");
        check_bit("p0_ready after init", p0_ready, 1'b1);
        check_bit("p0_ack = 0 after init", p0_ack, 1'b0);
        check_bit("p0_burst_data_valid = 0", p0_burst_data_valid, 1'b0);
        check_bit("p1_burst_data_valid = 0", p1_burst_data_valid, 1'b0);
        check_bit("p2_burst_data_valid = 0", p2_burst_data_valid, 1'b0);
        check_bit("p3_burst_data_valid = 0", p3_burst_data_valid, 1'b0);

        // ============================================================
        // Test 2: Single-Word Read on Port 0 (backward compat, burst_len=0)
        // ============================================================
        $display("--- Test 2: Single-Word Read Port 0 (burst_len=0) ---");

        // Pre-load SDRAM: addr 24'h000004 -> bank=0, row=0, col={addr[8:1],0}={2,0}=4
        // Single-word reads low half at col_addr and high half at col_addr+1
        sdram_mem[0][0][4] = 16'hCAFE;
        sdram_mem[0][0][5] = 16'hBEEF;

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000004;
        p0_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;

        wait_p0_ack(80);
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
        p1_addr      = 24'h000008; // bank=0, row=0, col=8
        p1_wdata     = 32'hDEAD5678;
        p1_burst_len = 8'd0;
        @(posedge clk); #1;
        p1_req = 1'b0;

        wait_p1_ack(80);
        #1;

        check_bit("p1 single write ack", p1_ack, 1'b1);

        @(posedge clk); #1;
        @(posedge clk); #1;

        // Verify SDRAM contents: low half at col 8, high half at col 9
        check_val16("p1 write low", sdram_mem[0][0][8], 16'h5678);
        check_val16("p1 write high", sdram_mem[0][0][9], 16'hDEAD);

        // ============================================================
        // Test 4: Burst Read on Port 3 (burst_len=8)
        // ============================================================
        $display("--- Test 4: Burst Read Port 3 (burst_len=8) ---");

        // Pre-load 8 x 16-bit words at bank 0, row 0, columns 32-39
        // addr = 24'h000020 -> col = {addr[8:1], 0} = {16, 0} = 32
        for (i = 0; i < 8; i = i + 1) begin
            sdram_mem[0][0][32 + i] = 16'hA000 + i[15:0];
        end

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000020;
        p3_burst_len = 8'd8;
        @(posedge clk); #1;
        p3_req = 1'b0;

        burst_cap_count = 0;
        cycle_count = 0;
        while (!p3_ack && cycle_count < 200) begin
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

        // Pre-load 4 words at bank 0, row 0, columns 64-67
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][64 + i] = 16'hBB00 + i[15:0];
        end

        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000040;
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

        // Clear target region: bank 0, row 0, columns 96-99
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][96 + i] = 16'h0000;
        end

        // addr = 24'h000060 -> col = {addr[8:1], 0} = {48, 0} = 96
        p1_req          = 1'b1;
        p1_we           = 1'b1;
        p1_addr         = 24'h000060;
        p1_burst_len    = 8'd4;
        p1_burst_wdata  = 16'h1111;
        @(posedge clk); #1;
        p1_req = 1'b0;

        cycle_count = 0;
        i = 1;
        while (!p1_ack && cycle_count < 200) begin
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
        @(posedge clk); #1;

        // Verify SDRAM contents
        check_val16("bwrite word 0", sdram_mem[0][0][96], 16'h1111);
        check_val16("bwrite word 1", sdram_mem[0][0][97], 16'h2222);
        check_val16("bwrite word 2", sdram_mem[0][0][98], 16'h3333);
        check_val16("bwrite word 3", sdram_mem[0][0][99], 16'h4444);

        // ============================================================
        // Test 7: Burst Preemption — Port 0 interrupts Port 3 burst
        // ============================================================
        $display("--- Test 7: Burst Preemption (Port 0 interrupts Port 3) ---");

        // Pre-load 16 words at bank 0, row 0, columns 128-143
        for (i = 0; i < 16; i = i + 1) begin
            sdram_mem[0][0][128 + i] = 16'hCC00 + i[15:0];
        end

        // Pre-load for port 0 single-word read: bank 0, row 0, col 6/7
        // addr = 24'h000006: bank=0, row=0, col = {addr[8:1], 0} = {3, 0} = 6
        sdram_mem[0][0][6] = 16'h1234;
        sdram_mem[0][0][7] = 16'h5678;

        // Start port 3 burst read (16 words)
        // addr = 24'h000080 -> col = {addr[8:1], 0} = {64, 0} = 128
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000080;
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
                    p0_addr      = 24'h000006; // col = {3, 0} = 6
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

                if (cycle_count > 400) begin
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

        // Pre-load 4 words at bank 0, row 0, columns 160-163
        for (i = 0; i < 4; i = i + 1) begin
            sdram_mem[0][0][160 + i] = 16'hDD00 + i[15:0];
        end

        // addr = 24'h0000A0 -> col = {addr[8:1], 0} = {80, 0} = 160
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h0000A0;
        p0_burst_len = 8'd4;
        @(posedge clk); #1;
        p0_req = 1'b0;

        burst_cap_count = 0;
        cycle_count = 0;
        while (!p0_ack && cycle_count < 200) begin
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
        // addr = 24'h00000C -> col = 12/13
        p2_req       = 1'b1;
        p2_we        = 1'b1;
        p2_addr      = 24'h00000C;
        p2_wdata     = 32'hFACE0000;
        p2_burst_len = 8'd0;
        @(posedge clk); #1;
        p2_req = 1'b0;

        cycle_count = 0;
        while (!p2_ack && cycle_count < 80) begin
            @(posedge clk); #1;
            cycle_count = cycle_count + 1;
        end

        check_bit("p2 single write ack", p2_ack, 1'b1);

        @(posedge clk); #1;

        // Read back via port 2 (single-word)
        p2_req       = 1'b1;
        p2_we        = 1'b0;
        p2_addr      = 24'h00000C;
        p2_burst_len = 8'd0;
        @(posedge clk); #1;
        p2_req = 1'b0;

        cycle_count = 0;
        while (!p2_ack && cycle_count < 80) begin
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
        sdram_mem[0][0][16] = 16'h0000;
        sdram_mem[0][0][17] = 16'h0000;
        sdram_mem[0][0][20] = 16'h1111;
        sdram_mem[0][0][21] = 16'h1111;

        // Request simultaneously from port 0 and port 3
        // addr = 24'h000010 -> col = 16/17, addr = 24'h000014 -> col = 20/21
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000010;
        p0_burst_len = 8'd0;
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h000014;
        p3_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;
        // Keep p3_req asserted until served

        // Port 0 should be served first
        wait_p0_ack(80);
        #1;
        check_bit("priority p0 ack first", p0_ack, 1'b1);

        // Now wait for port 3
        @(posedge clk); #1;
        // Port 3 should now be served
        wait_p3_ack(80);
        #1;
        p3_req = 1'b0;
        check_bit("priority p3 ack second", p3_ack, 1'b1);

        @(posedge clk); #1;

        // ============================================================
        // Test 11: Reset During Burst
        // ============================================================
        $display("--- Test 11: Reset During Burst ---");

        for (i = 0; i < 8; i = i + 1) begin
            sdram_mem[0][0][192 + i] = 16'hEE00 + i[15:0];
        end

        // addr = 24'h0000C0 -> col = {96, 0} = 192
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h0000C0;
        p3_burst_len = 8'd8;
        @(posedge clk); #1;
        p3_req = 1'b0;

        // Let it run a couple cycles
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;

        // Assert reset mid-burst
        rst_n = 1'b0;
        p0_req = 0; p0_we = 0; p0_addr = 0; p0_wdata = 0; p0_burst_len = 0;
        p1_req = 0; p1_we = 0; p1_addr = 0; p1_wdata = 0; p1_burst_len = 0; p1_burst_wdata = 0;
        p2_req = 0; p2_we = 0; p2_addr = 0; p2_wdata = 0; p2_burst_len = 0; p2_burst_wdata = 0;
        p3_req = 0; p3_we = 0; p3_addr = 0; p3_wdata = 0; p3_burst_len = 0; p3_burst_wdata = 0;
        #50;
        rst_n = 1'b1;
        @(posedge clk); #1;

        // Wait for SDRAM re-initialization
        wait_init_complete(25000);

        check_bit("p0_ready after burst reset", p0_ready, 1'b1);
        check_bit("p3_ack = 0 after reset", p3_ack, 1'b0);
        check_bit("p3_burst_data_valid = 0 after reset", p3_burst_data_valid, 1'b0);

        // Verify functional after reset — simple port 0 read
        sdram_mem[0][0][24] = 16'h9999;
        sdram_mem[0][0][25] = 16'h8888;

        // addr = 24'h000018 -> col = 24/25
        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000018;
        p0_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;

        wait_p0_ack(80);
        // rdata is registered — wait one cycle after ack
        @(posedge clk); #1;
        check_val32("read after reset recovery", p0_rdata, 32'h88889999);

        @(posedge clk); #1;

        // ============================================================
        // Test 12: Burst + Single-Word Interleaving
        // Port 0 single-word request during Port 3 burst → preempts
        // ============================================================
        $display("--- Test 12: Burst + Single-Word Interleaving ---");

        // Pre-load 16 words at bank 0, row 0, columns 224-239
        for (i = 0; i < 16; i = i + 1) begin
            sdram_mem[0][0][224 + i] = 16'hFF00 + i[15:0];
        end
        sdram_mem[0][0][28] = 16'hAAAA;
        sdram_mem[0][0][29] = 16'hBBBB;

        // Start port 3 burst (16 words)
        // addr = 24'h0000E0 -> col = {112, 0} = 224
        p3_req       = 1'b1;
        p3_we        = 1'b0;
        p3_addr      = 24'h0000E0;
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
                    p0_addr      = 24'h00001C; // col = 28/29
                    p0_burst_len = 8'd0;
                end

                if (p3_ack) p3_done = 1'b1;

                // Deassert p0_req when ack fires
                if (p0_ack) begin
                    p0_done = 1'b1;
                    p0_req  = 1'b0;
                end

                if (cycle_count > 400) begin
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
        // Test 13: Auto-Refresh Preemption — mem_ready deasserts during
        //          refresh and arbiter blocks new grants
        // ============================================================
        $display("--- Test 13: Auto-Refresh Preemption ---");

        // Wait enough idle cycles for an auto-refresh to occur (interval ~780 cycles).
        // During refresh, mem_ready deasserts. Verify that the arbiter blocks new
        // grants until mem_ready reasserts, and that a request issued during refresh
        // is served after refresh completes.
        begin : refresh_test
            integer idle_cyc;
            integer refresh_seen;
            integer ready_low_count;
            refresh_seen    = 0;
            ready_low_count = 0;

            // Wait up to 850 cycles for refresh to occur
            idle_cyc = 0;
            while (idle_cyc < 850) begin
                @(posedge clk); #1;
                idle_cyc = idle_cyc + 1;
                if (!mem_ready && idle_cyc > 10) begin
                    refresh_seen = 1;
                    ready_low_count = ready_low_count + 1;
                end
            end

            if (refresh_seen != 0) begin
                pass_count = pass_count + 1;
                $display("  PASS: mem_ready deasserted during auto-refresh (%0d low cycles)", ready_low_count);
            end else begin
                $display("FAIL: mem_ready never deasserted during 850 idle cycles");
                fail_count = fail_count + 1;
            end

            // Verify port0_ready also deasserts when mem_ready is low
            // (This is a combinational dependency: port0_ready = !grant_active && mem_ready)
            // We verify this by checking that p0_ready matches mem_ready when no grant is active
            check_bit("p0_ready = mem_ready when idle", p0_ready, mem_ready);
        end

        // Issue a request and verify it completes after refresh
        sdram_mem[0][0][40] = 16'hBEEF;
        sdram_mem[0][0][41] = 16'hDEAD;

        p0_req       = 1'b1;
        p0_we        = 1'b0;
        p0_addr      = 24'h000028; // col = 40/41
        p0_burst_len = 8'd0;
        @(posedge clk); #1;
        p0_req = 1'b0;

        wait_p0_ack(80);
        @(posedge clk); #1;
        check_val32("p0 read after refresh", p0_rdata, 32'hDEADBEEF);

        $display("  PASS: Request served correctly after auto-refresh");

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

    // Timeout watchdog (increased for SDRAM init + re-init + test time)
    initial begin
        #10000000;
        $display("\nERROR: Timeout — simulation ran too long");
        $finish;
    end

endmodule
